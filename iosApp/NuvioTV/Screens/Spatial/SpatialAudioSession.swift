import CoreMedia
import Foundation
import SpatialAudioBridge

// The spatial audio of one native playback: the Matroska reader, the engine of every spatial rendition,
// and what `LocalHLSServer` needs to serve them. Created by `NativePlaybackCoordinator` once the remux
// has inspected the source (`RemuxSession.segmentMap`, `timelineOriginSec`, `audioTracks`).
//
// Reading the source twice. The remux demuxes the file with FFmpeg and hands AVPlayer the video and
// the audio it can copy or transcode; the TrueHD / DTS packets of a spatial rendition are read by
// SpatialAudioBridge's own Matroska reader over HTTP range requests instead, on their own connection
// and on demand (a run starts at the segment AVPlayer asks for, after any seek). Tapping the remux's
// packets would tie the conversion to the remux's single worker thread and its video-driven pacing,
// and a seek in the audio would have to wait for the video's. The price is that the video bytes of
// the clusters are transferred a second time while a spatial track plays (about the file's bitrate;
// SpatialAudioBridge docs, "Seeking reads a lot of data"). Sources the reader cannot open (not
// Matroska, no range support) simply keep the standard audio.

/// What the loopback server answers for a request to a spatial rendition.
nonisolated enum SpatialServeResult: Sendable {
    case data(Data)
    case notFound
    /// Not ready within the server's window, or superseded by a newer request: AVPlayer asks again.
    case retry
    case gone
    case failed(String)
}

/// The first of two racing outcomes.
nonisolated enum SpatialRaced: Sendable {
    case finished(Result<Data, any Error>)
    case timedOut
}

nonisolated enum SpatialDeadline {
    /// Runs `work` and gives up on it after `seconds`: CoreMedia kills a variant that gets no answer
    /// to a media request within about six seconds, so the server must answer inside that window
    /// whatever the conversion is doing. The abandoned request is cancelled; the conversion goes on.
    static func race(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> Data) async -> SpatialRaced {
        await withTaskGroup(of: SpatialRaced.self) { group in
            group.addTask {
                do { return .finished(.success(try await work())) } catch { return .finished(.failure(error)) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}

/// One source track served as an APAC audio rendition (`aud-<stream>.m3u8`): its playlist and its
/// converted segments. Created by the session.
nonisolated final class SpatialRendition: Sendable {
    let streamIndex: Int
    let kind: SpatialAudioKind
    private let engine: SpatialAudioSegmentEngine
    private let totalFrames: Int64
    /// Where playback is, in playlist seconds, for a rendition that has not converted anything yet.
    private let playhead: @Sendable () -> Double

    fileprivate init(streamIndex: Int, kind: SpatialAudioKind, engine: SpatialAudioSegmentEngine,
                     totalFrames: Int64, playhead: @escaping @Sendable () -> Double) {
        self.streamIndex = streamIndex
        self.kind = kind
        self.engine = engine
        self.totalFrames = totalFrames
        self.playhead = playhead
    }

    func mediaPlaylist(startOffsetSec: Double?) -> String {
        SpatialGrid.mediaPlaylist(stream: streamIndex, totalFrames: totalFrames, startOffsetSec: startOffsetSec)
    }

    /// Converts and returns the initialization segment (`segment` nil) or the segment with this
    /// one-based number, within `deadline` seconds.
    func serve(segment: Int?, deadline: TimeInterval) async -> SpatialServeResult {
        let engine = self.engine
        let playhead = self.playhead
        let raced = await SpatialDeadline.race(seconds: deadline) { () async throws -> Data in
            guard let segment else {
                // The first request of a rendition nobody has played yet: convert where playback is,
                // not at the start of the file.
                await engine.prime(index: engine.index(atSeconds: playhead()))
                return try await engine.initialization()
            }
            return try await engine.segment(segment - 1)
        }
        switch raced {
        case .timedOut:
            return .retry
        case .finished(.success(let data)):
            return .data(data)
        case .finished(.failure(let error)):
            return Self.result(for: error)
        }
    }

    /// Converts the segment at `startSec` and the initialization segment, so an unsupported track
    /// fails here, before playback, as `APACStream.start` does: the converter only knows whether a
    /// TrueHD track carries Atmos or a DTS track DTS:X once it decodes it.
    func validate(startSec: Double) async throws {
        await engine.prime(index: engine.index(atSeconds: startSec))
        _ = try await engine.segment(engine.index(atSeconds: startSec))
        _ = try await engine.initialization()
    }

    func stop() async { await engine.stop() }

    static func result(for error: any Error) -> SpatialServeResult {
        if let stream = error as? SpatialStreamError {
            switch stream {
            case .outOfRange: return .notFound
            case .superseded, .timedOut: return .retry
            case .stopped: return .gone
            }
        }
        // A transport error (the source dropped, a timeout, a server error) is not the converter's
        // verdict: answer 503 so AVPlayer asks again, as a 500 on a media segment can fail the item.
        // The engine ends the stream when they keep coming.
        if error is CancellationError || error is URLError || error is POSIXError { return .retry }
        return .failed(String(describing: error))
    }
}

nonisolated final class SpatialAudioSession: @unchecked Sendable {
    private let urlSession: URLSession
    private let file: MatroskaFile
    private let origin: CMTime
    private let totalFrames: Int64
    private let priming: Int64
    /// Playlist start of every video segment, to turn the segment AVPlayer asks for into a playhead.
    private let videoSegmentStarts: [Double]
    private let lock = NSLock()
    private var renditions: [Int: SpatialRendition] = [:]
    private var failureHandler: (@Sendable (Int, String) -> Void)?
    private var playheadSec = 0.0
    /// The playback position has been reported (`notePosition`): it is a better playhead than the
    /// newest video segment request, which AVPlayer's forward buffer puts up to 24 s ahead.
    private var positionDriven = false
    private var stopped = false

    private init(urlSession: URLSession, file: MatroskaFile, origin: CMTime, totalFrames: Int64, priming: Int64,
                 videoSegmentStarts: [Double], startSec: Double) {
        self.urlSession = urlSession
        self.file = file
        self.origin = origin
        self.totalFrames = totalFrames
        self.priming = priming
        self.videoSegmentStarts = videoSegmentStarts
        self.playheadSec = startSec
    }

    deinit { urlSession.invalidateAndCancel() }

    // MARK: Start

    /// Opens the source, pairs the remux's audio tracks with the Matroska tracks the converter reads,
    /// and converts the first segment of the track the viewer starts on. Throws when the source cannot
    /// be read or the track cannot be converted (plain TrueHD or DTS-HD MA, unsupported metadata):
    /// the caller then keeps the standard audio. The other announced tracks (Atmos / DTS:X in the
    /// profile or the title) get a rendition that is converted the first time AVPlayer asks for it.
    static func start(url: URL, headers: [String: String], tracks: [RemuxAudioTrack], initialStream: Int,
                      map: SegmentMap, originSec: Double, startSec: Double) async throws -> SpatialAudioSession {
        let totalFrames = SpatialGrid.totalFrames(durationSec: map.totalDurationSec)
        guard totalFrames > 0, originSec.isFinite else {
            throw SpatialAudioError.source("The video has no usable timeline")
        }
        guard let initial = tracks.first(where: { $0.streamIndex == initialStream }),
              let initialKind = SpatialAudioPolicy.probeKind(codec: initial.codec, profile: initial.profile) else {
            throw SpatialAudioError.source("The selected audio is not TrueHD or DTS")
        }
        // The reader's own session: the app's other traffic (artwork, add-on calls) must not queue in
        // front of the dozens of sequential range requests a start or a seek makes, and its
        // connections must not outlive the playback.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let urlSession = URLSession(configuration: configuration)
        do {
            let source: any MediaByteSource = url.isFileURL
                ? FileByteSource(url: url)
                : HTTPByteSource(url: url, headers: headers, session: urlSession)
            let file = try await MatroskaFile.open(source)
            let priming = try APACConfiguration(liveEncoding: true).encoderPrimingDuration().value
            var starts: [Double] = []
            var elapsed = 0.0
            for segment in map.segments {
                starts.append(elapsed)
                elapsed += segment.durationSec
            }
            let session = SpatialAudioSession(
                urlSession: urlSession, file: file,
                origin: CMTime(seconds: originSec, preferredTimescale: 1_000_000_000),
                totalFrames: totalFrames, priming: priming, videoSegmentStarts: starts, startSec: startSec)
            let matches = matchTracks(streams: tracks.map {
                (streamIndex: $0.streamIndex, codec: $0.codec, language: $0.language)
            }, fileTracks: file.audioTracks)
            guard let match = matches[initialStream], let first = session.makeRendition(
                streamIndex: initialStream, track: match, kind: initialKind, startSec: startSec) else {
                throw SpatialAudioError.source("The converter cannot read this audio track")
            }
            do {
                try await first.validate(startSec: startSec)
            } catch {
                await session.stop()
                throw error
            }
            var extras = 0
            for track in tracks where track.streamIndex != initialStream && extras < SpatialAudioPolicy.maxExtraRenditions {
                guard let kind = SpatialAudioPolicy.announcedKind(codec: track.codec, profile: track.profile, title: track.title),
                      let match = matches[track.streamIndex],
                      session.makeRendition(streamIndex: track.streamIndex, track: match, kind: kind, startSec: startSec) != nil
                else { continue }
                extras += 1
            }
            return session
        } catch {
            urlSession.invalidateAndCancel()
            throw error
        }
    }

    /// Pairs avformat audio streams with Matroska audio tracks, by codec family and order. FFmpeg and
    /// the converter both list a file's tracks in track order, so the n-th TrueHD stream is the n-th
    /// `A_TRUEHD` track, and likewise for DTS. A family whose counts differ is left out entirely
    /// (one of the readers skipped a track and the pairing would be a guess), and so is a pair whose
    /// languages disagree.
    static func matchTracks(streams: [(streamIndex: Int, codec: String, language: String?)],
                            fileTracks: [MatroskaAudioTrack]) -> [Int: MatroskaAudioTrack] {
        var matches: [Int: MatroskaAudioTrack] = [:]
        for family in [(codec: "truehd", codecID: "A_TRUEHD"), (codec: "dts", codecID: "A_DTS")] {
            let ours = streams.filter { $0.codec == family.codec }
            let theirs = fileTracks.filter { $0.codecID == family.codecID }
            guard ours.count == theirs.count else { continue }
            for (stream, track) in zip(ours, theirs) {
                if let a = primaryLanguage(stream.language), let b = primaryLanguage(track.language), a != b { continue }
                matches[stream.streamIndex] = track
            }
        }
        return matches
    }

    private static func primaryLanguage(_ code: String?) -> String? {
        guard let tag = TrackLabelFormatter.normalizedTag(code) else { return nil }
        return tag.split(separator: "-").first.map { String($0).lowercased() }
    }

    /// Creates the engine of a spatial rendition. Nothing converts until the first request.
    fileprivate func makeRendition(streamIndex: Int, track: MatroskaAudioTrack, kind: SpatialAudioKind,
                                   startSec: Double) -> SpatialRendition? {
        guard let codec = track.codec else { return nil }
        let engine = SpatialAudioSegmentEngine(
            streamIndex: streamIndex, file: file, track: track, codec: codec, origin: origin,
            totalFrames: totalFrames, priming: priming,
            onFailure: { [weak self] stream, error in self?.report(stream: stream, error: error) })
        let rendition = SpatialRendition(
            streamIndex: streamIndex, kind: kind, engine: engine, totalFrames: totalFrames,
            playhead: { [weak self] in self?.currentPlayhead ?? startSec })
        lock.withLock { renditions[streamIndex] = rendition }
        return rendition
    }

    // MARK: Access

    /// Every spatial rendition of the session, by avformat stream index.
    var allRenditions: [Int: SpatialRendition] { lock.withLock { renditions } }

    func rendition(forStream stream: Int) -> SpatialRendition? { lock.withLock { renditions[stream] } }

    /// Called with the stream index and a description when a rendition's conversion fails for good:
    /// the coordinator then serves that track the standard way.
    func setFailureHandler(_ handler: (@Sendable (Int, String) -> Void)?) {
        lock.withLock { failureHandler = handler }
    }

    private func report(stream: Int, error: any Error) {
        let handler = lock.withLock { failureHandler }
        handler?(stream, String(describing: error))
    }

    /// AVPlayer asked for video segment `number` (one-based): the playhead is about there.
    func noteVideoSegment(_ number: Int) {
        guard number >= 1, number <= videoSegmentStarts.count else { return }
        lock.withLock { if !positionDriven { playheadSec = videoSegmentStarts[number - 1] } }
    }

    /// The player's position, in playlist seconds (the coordinator's 3 s tick).
    func notePosition(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lock.withLock { playheadSec = seconds; positionDriven = true }
    }

    private var currentPlayhead: Double { lock.withLock { playheadSec } }

    /// Stops one rendition's conversion and removes it (the track plays the standard way from now on).
    func remove(stream: Int) async {
        let removed: SpatialRendition? = lock.withLock { renditions.removeValue(forKey: stream) }
        await removed?.stop()
    }

    func stop() async {
        let current: [SpatialRendition] = lock.withLock {
            stopped = true
            let all = Array(renditions.values)
            renditions.removeAll()
            return all
        }
        for rendition in current { await rendition.stop() }
        urlSession.invalidateAndCancel()
    }
}
