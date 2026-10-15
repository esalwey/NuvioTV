import CoreMedia
import Foundation
import SpatialAudioBridge

// On-demand APAC conversion for the native player's own HLS.
//
// WHY THIS IS NOT `APACStream`. SpatialAudioBridge offers three integration paths: `APACStream` (a
// ready-made loopback HLS audio rendition that rewrites a server's video master), `SpatialAudioRenderer`
// (sample buffers, for players that render themselves) and `SpatialAudioTranscoder` / `APACHLSOutput`
// (conversion building blocks for players that build their own HLS). NuvioTV builds its own HLS: the
// master playlist is synthesized by `LocalHLSServer` from the remux's `SegmentMap`, with one audio
// rendition per source track (the Audio menu, track memory and the Audio tab all depend on that), the
// subtitle renditions and the Dolby Vision signaling. `APACStream` would replace all of it with a single
// APAC rendition, so it is not an option; `APACHLSOutput` writes an EVENT playlist as one linear pass,
// which tvOS 27 rejects (see SegmentMap) and which cannot seek. What is left is the conversion block
// `SpatialAudioTranscoder` with a `.segments` destination, driven the way `APACStream` drives it: this
// file is a port of its segment engine (`StreamEngine`, Apache-2.0, same restart / helper-run / cache
// rules, which are device-validated on Apple TV 4K), with these changes:
//   - the audio timeline is the VIDEO PLAYLIST timeline. The remux maps video to playlist time by
//     subtracting the first keyframe's pts (`RemuxSession.timelineOriginSec`); the engine subtracts the
//     same origin from every packet time and adds it back when it asks the Matroska reader for packets,
//     so APAC lands where the video and the other audio renditions are, whatever the file's first pts.
//   - packets come from `MatroskaFile.packets(of:from:)` (public API only), so there is no track-end
//     shortcut and no `pad(to:)`: a track that ends before the video is padded with silence in one
//     `finish(paddingTo:)`.
//   - failures are reported to the session (the coordinator then serves the track the standard way).
//
// Segments are 2 APAC sync periods (75 packets x 1024 frames each, 153,600 frames = 3.2 s) on a fixed
// grid anchored at playlist time zero: segment N always covers N x 3.2 s to (N + 1) x 3.2 s whichever
// conversion run produced it, which is what lets AVPlayer mix segments of different runs after a seek
// and lets every run share one initialization segment. A run's first fragment starts at the grid line
// and carries 42.7 ms of encoder priming instead of audio (SpatialAudioBridge docs, architecture.md).
//
// Threading and memory: the engine is an actor; every conversion run is a detached task, so nothing
// here touches the main thread. Converted segments live in a bounded window (`keptBehind` segments
// behind the newest request, the lookahead ahead of it: about 42 MB at 7.1.4), runs are paced to the
// lookahead, and a run converts at about 4.5 to 6 times real time on an Apple TV 4K (library figures).

// MARK: - Grid

nonisolated enum SpatialGrid {
    static let sampleRate = 48_000
    /// APAC sync periods per segment; the library default and the one its device tests used.
    static let periods = 2
    /// APAC packets between sync packets (`APACConfiguration.syncPacketFrequency`'s default).
    static let syncPacketFrequency = 75
    /// 2 x 75 x 1024 = 153,600 frames: 3.2 seconds at 48 kHz.
    static let segmentFrames: Int64 = Int64(periods * syncPacketFrequency * 1024)
    static var segmentSeconds: Double { Double(segmentFrames) / Double(sampleRate) }

    static func totalFrames(durationSec: Double) -> Int64 {
        guard durationSec.isFinite, durationSec > 0, durationSec < 1e9 else { return 0 }
        return Int64((durationSec * Double(sampleRate)).rounded(.up))
    }

    static func segmentCount(totalFrames: Int64) -> Int {
        guard totalFrames > 0 else { return 0 }
        return Int((totalFrames + segmentFrames - 1) / segmentFrames)
    }

    /// The zero-based grid index of the segment holding playlist time `seconds` (clamped to the stream).
    static func index(atSeconds seconds: Double, totalFrames: Int64) -> Int {
        guard totalFrames > 0 else { return 0 }
        let clamped = min(max(seconds.isFinite ? seconds : 0, 0), Double(totalFrames) / Double(sampleRate))
        let frame = Int64((clamped * Double(sampleRate)).rounded(.down))
        return Int(min(frame, totalFrames - 1) / segmentFrames)
    }

    /// `aud-<stream>-init.mp4`, the names `RemuxAudioTrack.parseFileName` reads back.
    static func initName(stream: Int) -> String { "aud-\(stream)-init.mp4" }

    /// `aud-<stream>-NNNNN.m4s`; `number` is one-based like the remux's own audio segments, so grid
    /// index 0 is `aud-<stream>-00001.m4s`.
    static func segmentName(stream: Int, number: Int) -> String { String(format: "aud-%d-%05d.m4s", stream, number) }

    /// The rendition's complete VOD media playlist, published up front like every playlist of this
    /// server (tvOS 27 only plays VOD playlists carrying EXT-X-ENDLIST from the first fetch). Every
    /// segment is 3.2 s but the last. APAC segments start with a sync packet, so they are independent.
    static func mediaPlaylist(stream: Int, totalFrames: Int64, startOffsetSec: Double?) -> String {
        let count = segmentCount(totalFrames: totalFrames)
        let target = Int(segmentSeconds.rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:1",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if let start = SegmentMap.startTag(startOffsetSec) { lines.append(start) }
        lines.append("#EXT-X-MAP:URI=\"\(initName(stream: stream))\"")
        for index in 0..<count {
            let frames = min(segmentFrames, totalFrames - Int64(index) * segmentFrames)
            lines.append(String(format: "#EXTINF:%.6f,", Double(frames) / Double(sampleRate)))
            lines.append(segmentName(stream: stream, number: index + 1))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Errors and run bookkeeping

nonisolated enum SpatialStreamError: LocalizedError {
    case outOfRange
    /// Conversion restarted elsewhere for a later request, so this segment will not arrive soon.
    case superseded
    case timedOut
    case stopped

    var errorDescription: String? {
        switch self {
        case .outOfRange: return "The segment is outside the stream"
        case .superseded: return "A later request moved conversion elsewhere"
        case .timedOut: return "Conversion did not reach the segment in time"
        case .stopped: return "The stream has stopped"
        }
    }
}

nonisolated struct SpatialRun: Sendable {
    let id: UUID
    /// The first segment the run delivers.
    let start: Int
    let task: Task<Void, Never>
}

// MARK: - Engine

/// Converts one source track's segments on demand and caches a window of them, restarting conversion
/// where playback needs it. See the header of this file.
actor SpatialAudioSegmentEngine {
    /// How far ahead of a restart the helper run starts. After a seek AVPlayer requested about 12
    /// segments in order before resuming (library measurement); this splits them between two runs.
    nonisolated static let helperOffset = 5

    nonisolated let streamIndex: Int
    nonisolated let totalFrames: Int64
    private let file: MatroskaFile
    private let track: MatroskaAudioTrack
    private let codec: SpatialAudioCodec
    private let configuration: APACConfiguration
    /// Container time of playlist time zero (the video's first keyframe).
    private let origin: CMTime
    private let segmentFrames = SpatialGrid.segmentFrames
    private let priming: Int64
    private let lookahead: Int
    private let keptBehind: Int
    private let timeout: Duration
    private let store = SpatialSegmentStore()
    private let onFailure: (@Sendable (Int, any Error) -> Void)?
    /// Converts from the segment that started it, and on through playback.
    private var run: SpatialRun?
    /// After a restart, converts from a few segments ahead in parallel, until `run` reaches it and
    /// hands over. One APAC encoder runs on one thread, so two runs fill a seek's gap sooner.
    private var helper: SpatialRun?
    /// Where the helper will start, once `run` has delivered its first segment: started together,
    /// the two runs delayed that segment past the 3 s AVPlayer allows a seek on Apple TV.
    private var plannedHelper: Int?
    private var requested = 0
    /// Segments that requests are waiting for, one entry per request.
    private var waiting: [Int] = []
    /// A decoding or encoding failure that repeats on every run, which ends the stream.
    private var failure: (any Error)?
    private var stopped = false

    /// The furthest segment playback wants: the latest request, or a waiting one further ahead.
    private var demand: Int { max(requested, waiting.max() ?? requested) }
    /// Where conversion runs ahead from: what playback wants, or the helper's start, which playback
    /// will want soon after a seek.
    private var frontier: Int { max(demand, helper?.start ?? plannedHelper ?? 0) }

    /// `priming` is `APACConfiguration.encoderPrimingDuration().value` (2048 frames on tested
    /// systems), queried once by the session; `origin` is the container time of playlist time zero.
    init(streamIndex: Int, file: MatroskaFile, track: MatroskaAudioTrack, codec: SpatialAudioCodec,
         origin: CMTime, totalFrames: Int64, priming: Int64,
         lookahead: Int = 6, keptBehind: Int = 20, timeout: Duration = .seconds(30),
         onFailure: (@Sendable (Int, any Error) -> Void)? = nil) {
        var configuration = APACConfiguration()
        // The offline profile would delay every segment by about 20 s of audio.
        configuration.liveEncoding = true
        self.streamIndex = streamIndex
        self.file = file
        self.track = track
        self.codec = codec
        self.configuration = configuration
        self.origin = origin
        self.totalFrames = totalFrames
        self.priming = priming
        self.lookahead = max(1, lookahead)
        self.keptBehind = max(2, keptBehind)
        self.timeout = timeout
        self.onFailure = onFailure
    }

    var segmentCount: Int { SpatialGrid.segmentCount(totalFrames: totalFrames) }

    nonisolated func index(atSeconds seconds: Double) -> Int {
        SpatialGrid.index(atSeconds: seconds, totalFrames: totalFrames)
    }

    /// Tells an engine that has not converted anything yet where playback is, so the run its first
    /// request starts begins there rather than at the start of the file.
    func prime(index: Int) {
        guard run == nil, !stopped else { return }
        requested = min(max(index, 0), max(segmentCount - 1, 0))
    }

    func initialization() async throws -> Data {
        guard !stopped else { throw SpatialStreamError.stopped }
        try checkFailure()
        if let data = store.initialization { return data }
        if run == nil { restart(at: requested) }
        return try await wait(until: { $0.initialization })
    }

    func segment(_ index: Int) async throws -> Data {
        guard (0..<segmentCount).contains(index) else { throw SpatialStreamError.outOfRange }
        guard !stopped else { throw SpatialStreamError.stopped }
        try checkFailure()
        requested = index
        keepSegments(around: index)
        if let data = store.segment(index) { return data }
        if !waitsForRun(index) {
            spatialLog("seg\(index) restarts conversion; run started at \(run?.start ?? -1), converted \(converted)")
            restart(at: index)
            keepSegments(around: index)
        }
        waiting.append(index)
        defer { if let entry = waiting.firstIndex(of: index) { waiting.remove(at: entry) } }
        let data = try await wait(until: { $0.segment(index) }, while: { waitsForRun(index) })
        publishSpeed()
        return data
    }

    /// Ends conversion for good; requests already on their way are refused.
    func stop() {
        stopped = true
        for run in [run, helper].compactMap({ $0 }) {
            run.task.cancel()
            store.retire(run: run.id)
        }
        (run, helper) = (nil, nil)
    }

    /// Audio converted per second spent converting since the latest start or seek, as a multiple of
    /// real time, excluding time held at the lookahead; nil before the first segment.
    var conversionSpeed: Double? {
        guard let run else { return nil }
        return store.speed(run: run.id, segmentFrames: segmentFrames)
    }

    /// Bytes of converted audio held right now.
    var cachedBytes: Int { store.cachedBytes }

    /// The highest segment the current run has produced.
    var converted: Int { run.map { store.highest(run: $0.id) } ?? -1 }

    private func publishSpeed() {
        guard let run, let speed = store.speed(run: run.id, segmentFrames: segmentFrames) else { return }
        NativePlaybackMetrics.shared.recordSpatialSpeed(
            speed, segmentsInRun: store.produced(run: run.id), cachedBytes: store.cachedBytes)
    }

    /// Keeps the played segments behind `index` and everything conversion may run ahead to.
    private func keepSegments(around index: Int) {
        store.keep(around: index, behind: keptBehind, ahead: frontier - index + lookahead)
    }

    /// Whether a running conversion will deliver segment `index` sooner than a new run would.
    private func waitsForRun(_ index: Int) -> Bool {
        [run, helper].contains { run in
            guard let run else { return false }
            return Self.waits(for: index, runStart: run.start, converted: store.highest(run: run.id),
                              ended: store.ended(run: run.id))
        }
    }

    /// A new run delivers its first segment in about two segments' conversion time, while each
    /// segment after the converted one costs one more. AVPlayer abandons a seek whose first segment
    /// takes longer than about 3 s, so wait only up to two segments past the converted point;
    /// restart behind the run, past that, or at a segment the run passed but no longer holds.
    nonisolated static func waits(for index: Int, runStart: Int, converted: Int, ended: Bool) -> Bool {
        !ended && index >= runStart && index > converted && index <= max(runStart + 1, converted + 2)
    }

    /// Throws a failure that ends the stream, recording one the current run has just reported.
    /// Transport failures, such as a dropped connection or a server error, may succeed on a new run.
    /// A `SpatialAudioError`, including malformed container data, would repeat with every restart,
    /// so it ends the stream.
    private func checkFailure() throws {
        for run in [run, helper] where failure == nil {
            if let run, let error = store.failure(run: run.id) as? SpatialAudioError { record(error) }
        }
        if let failure { throw failure }
    }

    private func record(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        NativePlaybackMetrics.shared.noteSpatialFailure(String(describing: error))
        onFailure?(streamIndex, error)
    }

    private func wait(until value: (SpatialSegmentStore) -> Data?,
                      while wanted: () -> Bool = { true }) async throws -> Data {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let data = value(store) { return data }
            guard !stopped else { throw SpatialStreamError.stopped }
            try checkFailure()
            if let run, let failure = store.failure(run: run.id) { throw failure }
            // A later request restarted conversion elsewhere; the player has moved on.
            guard wanted() else { throw SpatialStreamError.superseded }
            guard ContinuousClock.now < deadline else { throw SpatialStreamError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Restarts conversion at segment `index`, with a helper converting from a few segments ahead.
    private func restart(at index: Int) {
        for run in [run, helper].compactMap({ $0 }) {
            run.task.cancel()
            store.retire(run: run.id)
        }
        run = launch(from: index, early: false)
        helper = nil
        // The helper stays within the segments the store keeps for the request.
        let offset = min(Self.helperOffset, lookahead)
        plannedHelper = offset >= 2 && index + offset < segmentCount ? index + offset : nil
        NativePlaybackMetrics.shared.noteSpatialRestart()
    }

    /// Converts from segment `index`: decoding starts at the last sync before its first presented
    /// sample, which follows the encoder priming so the fragment begins exactly on the grid.
    ///
    /// A run's first fragment carries the encoder priming in place of its first 42.7 ms of audio.
    /// That is expected right after a seek, but a helper's first segment plays on from the run
    /// before it, so a helper starts one segment `early` and discards that fragment.
    private func launch(from index: Int, early: Bool) -> SpatialRun {
        // Playlist time of the first output sample; the Matroska reader works in container time.
        let startFrames = Int64(index - (early ? 1 : 0)) * segmentFrames + priming
        let start = CMTime(value: startFrames, timescale: 48_000)
        // The playlist follows the video, which may outlast the track, so a run that reaches the
        // track's end pads with silence to the playlist's. A run in a last segment shorter than the
        // priming still needs one frame to write its fragment.
        let end = max(totalFrames, startFrames + 1)
        let (file, track, codec, configuration, store, segmentFrames, origin) =
            (self.file, self.track, self.codec, self.configuration, self.store, self.segmentFrames, self.origin)
        let id = UUID()
        store.begin(run: id, first: index)
        let task = Task.detached { [weak self] in
            do {
                func transcoder(from inputStart: CMTime?) throws -> SpatialAudioTranscoder {
                    var settings = configuration
                    settings.startTime = start
                    settings.inputStartTime = inputStart
                    return try SpatialAudioTranscoder(codec: codec, destination: .segments(
                        syncPeriodsPerSegment: SpatialGrid.periods,
                        onSegment: { store.deliver($0, run: id, segmentFrames: segmentFrames) }),
                        configuration: settings)
                }
                // Whether the run carries on, holding it at the lookahead. It stops once its stream
                // is released, which ends the engine, or a helper takes over.
                func proceeds() async -> Bool {
                    guard let self, await !self.handOver(from: id) else { return false }
                    await self.paceRun(id)
                    return true
                }
                var session: SpatialAudioTranscoder?
                var reachesEnd = true
                for try await packet in file.packets(of: track, from: CMTimeAdd(start, origin)) {
                    try Task.checkCancellation()
                    // Playlist time: the same origin the video and the other renditions were mapped with.
                    let time = CMTimeSubtract(packet.time, origin)
                    if session == nil { session = try transcoder(from: time) }
                    // A gap or reset in the timestamps fails the run; every run reaching it would fail
                    // again, so the stream ends and the coordinator serves the track the standard way.
                    try await session?.append(packet.data, time: time)
                    guard await proceeds() else { reachesEnd = false; break }
                }
                if reachesEnd {
                    let session = try session ?? transcoder(from: nil)
                    _ = try await session.finish(paddingTo: CMTime(value: end, timescale: 48_000))
                } else {
                    // Finishing a run that handed over would flush a partial fragment where the
                    // helper's full one belongs.
                    await session?.cancel()
                }
                store.end(run: id, failure: nil)
            } catch is CancellationError {
                store.end(run: id, failure: nil)
            } catch {
                store.end(run: id, failure: error)
                await self?.runFailed(id, error: error)
            }
        }
        return SpatialRun(id: id, start: index, task: task)
    }

    /// A run ended on an error: count it, and end the stream when it repeats on every run. Only the
    /// current runs count; a retired run may fail while its writer is cancelled.
    private func runFailed(_ id: UUID, error: any Error) {
        guard !stopped, [run?.id, helper?.id].contains(id) else { return }
        let failed = [run, helper].compactMap { $0 }.first { $0.id == id }
        spatialLog("run from seg\(failed?.start ?? -1) failed: \(error)")
        if error is SpatialAudioError {
            record(error)
        } else {
            NativePlaybackMetrics.shared.noteSpatialFailure(String(describing: error))
        }
    }

    /// Starts the planned helper once run `id` has delivered its first segment. Ends the run once it
    /// has delivered everything before the helper's first segment and the helper is ahead of it,
    /// and makes the helper the run. A helper whose transport failed is dropped and the run carries
    /// on; any other failure would repeat in the run, so it ends the stream.
    private func handOver(from id: UUID) -> Bool {
        guard let run, run.id == id else { return false }
        let converted = store.highest(run: id)
        if let planned = plannedHelper, converted >= run.start {
            plannedHelper = nil
            // A run already close to the planned start no longer needs the help.
            if converted < planned - 1 { helper = launch(from: planned, early: true) }
        }
        guard let helper else { return false }
        if let error = store.failure(run: helper.id) {
            spatialLog("the helper from seg\(helper.start) failed: \(error)")
            if failure == nil, let error = error as? SpatialAudioError { record(error) }
            self.helper = nil
            return false
        }
        let helped = store.highest(run: helper.id)
        // A helper that is not ahead once the run reaches its start would only slow the run's next
        // segment, so the run carries on alone.
        if converted >= helper.start, helped <= converted {
            helper.task.cancel()
            store.retire(run: helper.id)
            self.helper = nil
            return false
        }
        guard converted >= helper.start - 1, helped > converted else { return false }
        store.retire(run: id)
        (self.run, self.helper) = (helper, nil)
        return true
    }

    /// Holds a run while it is `lookahead` segments past the frontier.
    private func paceRun(_ id: UUID) async {
        guard [run?.id, helper?.id].contains(id), store.highest(run: id) >= frontier + lookahead else { return }
        store.holding(true, run: id)
        while [run?.id, helper?.id].contains(id), !Task.isCancelled, store.highest(run: id) >= frontier + lookahead {
            try? await Task.sleep(for: .milliseconds(50))
        }
        store.holding(false, run: id)
    }
}

// MARK: - Segment store

/// Segments shared between conversion callbacks and requests.
nonisolated final class SpatialSegmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var initData: Data?
    private var segments: [Int: Data] = [:]
    private var window = 0..<Int.max
    /// Runs whose fragments are accepted, with their progress.
    private var runs: [UUID: Progress] = [:]
    private var ends: [UUID: (any Error)?] = [:]

    private nonisolated struct Progress {
        /// The first segment the run contributes; earlier fragments are discarded.
        let first: Int
        var produced = -1
        let started = ContinuousClock.now
        var held = Duration.zero
        var holdStarted: ContinuousClock.Instant?
    }

    var initialization: Data? { lock.withLock { initData } }

    func segment(_ index: Int) -> Data? { lock.withLock { segments[index] } }

    /// Bytes of converted audio held right now.
    var cachedBytes: Int { lock.withLock { segments.values.reduce(0) { $0 + $1.count } } }

    /// Accepts fragments of `run` from segment `first` on.
    func begin(run: UUID, first: Int) { lock.withLock { runs[run] = Progress(first: first) } }

    /// Ignores further fragments of `run`, such as those a cancelled writer still emits.
    func retire(run: UUID) { lock.withLock { _ = runs.removeValue(forKey: run) } }

    /// The highest segment `run` has produced, or -1.
    func highest(run: UUID) -> Int { lock.withLock { runs[run]?.produced ?? -1 } }

    /// How many segments `run` has produced.
    func produced(run: UUID) -> Int {
        lock.withLock {
            guard let progress = runs[run], progress.produced >= progress.first else { return 0 }
            return progress.produced - progress.first + 1
        }
    }

    /// Stores a fragment under the grid index of its start time; repeated fragments replace nothing.
    func deliver(_ segment: APACSegment, run: UUID, segmentFrames: Int64) {
        lock.withLock {
            guard var progress = runs[run] else { return }
            switch segment.kind {
            case .initialization:
                // Every run writes the same initialization apart from creation times.
                if initData == nil { initData = segment.data }
            case .media:
                guard let start = segment.startTime else { return }
                let index = Int((start.seconds * 48_000 / Double(segmentFrames)).rounded())
                guard index >= progress.first else { return }
                if window.contains(index), segments[index] == nil { segments[index] = segment.data }
                progress.produced = max(progress.produced, index)
                runs[run] = progress
            }
        }
    }

    /// Marks the run as waiting for playback, or as converting again.
    func holding(_ waiting: Bool, run: UUID) {
        lock.withLock {
            guard var progress = runs[run] else { return }
            if waiting {
                progress.holdStarted = .now
            } else if let holdStarted = progress.holdStarted {
                progress.held += .now - holdStarted
                progress.holdStarted = nil
            }
            runs[run] = progress
        }
    }

    /// Seconds of audio `run` produced per second of conversion since it began.
    func speed(run: UUID, segmentFrames: Int64) -> Double? {
        lock.withLock {
            guard let progress = runs[run], progress.produced >= progress.first else { return nil }
            let audio = Double(Int64(progress.produced - progress.first + 1) * segmentFrames) / 48_000
            let now = ContinuousClock.now
            let busy = now - progress.started - progress.held - (progress.holdStarted.map { now - $0 } ?? .zero)
            let seconds = Double(busy.components.seconds) + Double(busy.components.attoseconds) / 1e18
            return seconds > 0 ? audio / seconds : nil
        }
    }

    func end(run: UUID, failure: (any Error)?) {
        // Subscript assignment of nil would remove the entry; a clean end must be recorded too.
        lock.withLock { _ = ends.updateValue(failure, forKey: run) }
    }

    func ended(run: UUID) -> Bool { lock.withLock { ends[run] != nil } }

    func failure(run: UUID) -> (any Error)? { lock.withLock { ends[run] ?? nil } }

    /// Keeps segments near the playback position and drops the rest.
    func keep(around index: Int, behind: Int, ahead: Int) {
        lock.withLock {
            window = max(0, index - behind)..<(index + ahead + 3)
            segments = segments.filter { window.contains($0.key) }
        }
    }
}

// MARK: - Logging

/// Restarts, helper hand-overs and failures of the conversion. Per-segment chatter stays out: a
/// 2-hour film is 2,250 segments.
nonisolated func spatialLog(_ message: @autoclosure () -> String) {
    print("[Spatial] \(message())")
}
