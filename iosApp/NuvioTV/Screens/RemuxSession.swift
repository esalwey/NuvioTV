import Foundation
import Libavformat
import Libavcodec
import Libavutil

// Phase 2/4 of the hybrid player: on-device MKV→fMP4 remux with an OWNED segmenter (plan decision D3).
// Stream-copies (no re-encode) the compatible video and audio tracks of a source into fragmented-MP4
// segments, preserving Dolby Vision (RPU NALs ride along in the copied bitstream; the `dvvC` box is
// written by movenc from the DOVI side data). Audio with no copyable track falls back to a TrueHD/DTS
// → AAC transcode (`AudioTranscoder`, Phase 4 v2). Runs on a background worker; the emitted directory
// — one init segment plus `seg-NNNNN.m4s` files — is served to AVPlayer by `LocalHLSServer`.
//
// WHY WE OWN THE SEGMENTER (not the `dash` muxer): tvOS 27 rejects EVENT/growing playlists and only
// plays a VOD playlist (EXT-X-ENDLIST) published complete up front — but the segment files must still
// be produced just-in-time (remux ≈ realtime for debrid sources). A complete up-front playlist and a
// third-party muxer's autonomous cut decisions can silently disagree (MKV Cues are often a sparse
// subset of real keyframes), and one mismatched boundary desyncs the whole tail unrecoverably. So we
// cut the fMP4 ourselves at the `SegmentMap`'s keyframe boundaries via the mov/mp4 muxer with
// `movflags frag_custom+empty_moov+default_base_moof` and a custom AVIO sink (`SegmentWriter`) that
// routes each fragment into its own atomically-renamed file. Published == produced by construction;
// sparse Cues just yield longer-but-valid segments. See docs/tvos-hybrid-player-plan.md.
//
// SEEK-ANYWHERE: production happens in repositionable RUNS. A request for a segment outside the
// current producing window makes the JIT server call `reposition(toSegment:)`: the worker abandons
// its partial fragment, seeks the (Range-capable HTTP) demuxer to that segment's boundary keyframe,
// and continues linearly from there with a fresh muxer context (`frag_discont` keeps tfdt absolute so
// every fragment lands at its published playlist time regardless of which run produced it). Unproduced
// holes are legal — a request into one triggers another reposition — and the worker parks at EOF
// instead of exiting so late back-seeks still work.

/// HLS master-playlist signaling for the remuxed video, per Apple's HLS authoring spec: a full
/// RFC 6381 CODECS token (bare "hvc1" is non-compliant and stricter tvOS builds reject it), plus
/// Dolby Vision SUPPLEMENTAL-CODECS and VIDEO-RANGE for HDR. VIDEO-RANGE is REQUIRED on tvOS 27:
/// PQ media behind a master that doesn't declare it is rejected at media admission (-12927) —
/// confirmed by device A/B (identical media plays with the declaration, fails without).
nonisolated struct VideoSignaling: Sendable {
    var codecs: String                 // e.g. "hvc1.2.4.L153.B0" or "dvh1.05.06"
    var supplementalCodecs: String?    // e.g. "dvh1.08.06/db1p" (DV P8.1 over HDR10)
    var videoRange: String?            // "PQ" / "HLG"
    var width: Int32 = 0               // RESOLUTION=WxH when known (part of the validated master shape)
    var height: Int32 = 0
    var frameRate: Double = 0          // FRAME-RATE when known
}

/// One audio stream of the source, as the remux worker inspected it (D4 audio track switching).
/// `playable` means this session type can serve it — stream-copyable or TrueHD/DTS-transcodable;
/// `selected` marks the track this session actually muxes. `streamIndex` is the avformat stream
/// index, stable across sessions on the same URL, so the player UI can hand it to a rebuilt
/// session's `Config.audioStreamIndex`.
nonisolated struct RemuxAudioTrack: Equatable, Sendable {
    let streamIndex: Int
    let codec: String        // canonical FFmpeg name: "aac", "eac3", "truehd", "dts", ...
    let channels: Int
    let language: String?    // ISO 639 tag from container metadata, when tagged
    let title: String?       // container track title ("Commentary", "Surround 5.1", ...), when tagged
    let playable: Bool
    /// RFC 6381 token of what the rendition CARRIES: the source codec when stream-copied, "mp4a.40.2"
    /// when transcoded (TrueHD/DTS → AAC). nil for unplayable tracks.
    let codecToken: String?
    /// True when serving this track means transcoding (not stream copy).
    let transcodes: Bool
    /// The track whose audio the worker is currently producing (info-panel W3: the master lists every
    /// playable track as its own rendition; only the active one's segments are being written).
    var selected: Bool

    /// HLS rendition file names for this track's audio-only fMP4 (`aud-<streamIndex>-…`).
    var playlistName: String { "aud-\(streamIndex).m3u8" }
    var initName: String { "aud-\(streamIndex)-init.mp4" }
    func segmentName(_ number: Int) -> String { String(format: "aud-%d-%05d.m4s", streamIndex, number) }
    /// Parse `aud-<T>-init.mp4` / `aud-<T>-NNNNN.m4s` → (track, segment | nil for init).
    static func parseFileName(_ name: String) -> (track: Int, segment: Int?)? {
        guard name.hasPrefix("aud-") else { return nil }
        let core = name.dropFirst(4)
        if core.hasSuffix("-init.mp4"), let t = Int(core.dropLast(9)) { return (t, nil) }
        guard core.hasSuffix(".m4s") else { return nil }
        let parts = core.dropLast(4).split(separator: "-")
        guard parts.count == 2, let t = Int(parts[0]), let n = Int(parts[1]) else { return nil }
        return (t, n)
    }
}

/// One subtitle stream of the source, as the remux worker inspected it. Text tracks (SRT/ASS/SSA/
/// mov_text/WebVTT) are candidates for WebVTT renditions (info-panel plan W2); bitmap tracks
/// (PGS/VobSub/DVB) can't be shown by the native player and are only counted, so the Info tab can
/// explain their absence.
nonisolated struct RemuxSubtitleTrack: Equatable, Sendable {
    let streamIndex: Int
    let codec: String        // canonical FFmpeg name: "subrip", "ass", "hdmv_pgs_subtitle", ...
    let language: String?
    let title: String?
    let isText: Bool
    let forced: Bool
    let hearingImpaired: Bool
}

nonisolated final class RemuxSession: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case idle
        case running
        case ready              // remux finished; complete VOD playlist available
        case failed(String)
    }

    struct Config: Sendable {
        let url: URL
        var segmentDurationSec: Int = 4
        /// avformat stream index of the audio track to start with (nil = automatic: the
        /// `preferredAudioPicker` result, else first stream-copyable, else first transcodable).
        /// Track switching mid-session is `selectAudio(streamIndex:atSegment:)` (info-panel W3) —
        /// no session rebuild.
        var audioStreamIndex: Int? = nil
        /// Automatic-pick hook: given every audio track (with playability), return the stream index
        /// to mux, or nil for the built-in default (first copyable, else first transcodable). The
        /// coordinator uses it to honour Settings → Playback → Preferred Audio Language before the
        /// stream carries a single rendition. Runs on the remux worker thread — keep it pure.
        var preferredAudioPicker: (@Sendable ([RemuxAudioTrack]) -> Int?)? = nil
        /// Addon-declared HTTP request headers for the source (`PlaybackContext.requestHeaders`,
        /// pre-sanitized). Applied to avformat's http open — a header-gated scraper CDN 403s the
        /// remux source read without them (GitHub issue #2). Empty = no `headers` option set.
        var requestHeaders: [String: String] = [:]
        /// Settings → Playback → Strip SDH Subtitles: embedded text-track cues run through the
        /// shared `SubtitleSdhFilter` as their VTT segments are written (SDH stripping, native
        /// path — the mpv path sets `sub-filter-sdh` instead). Sampled at session start.
        var stripSdh: Bool = false
    }

    let config: Config
    let outputDir: URL
    /// Synthesized HLS master playlist name within `outputDir` (what AVPlayer loads). Served by
    /// `LocalHLSServer` from the `SegmentMap`; no file of this name is written to disk.
    let masterPlaylistName = "master.m3u8"

    private let lock = NSLock()
    private var _state: State = .idle
    private var _cancelled = false
    private var _signaling: VideoSignaling?
    private var _segmentMap: SegmentMap?
    private var _hasAudio = false
    private var _audioCodecToken: String?
    private var _audioTracks: [RemuxAudioTrack] = []
    private var _subtitleTracks: [RemuxSubtitleTrack] = []
    private var _subtitleSinkIndices: Set<Int> = []
    private var _estimatedBandwidth = 20_000_000
    private var onStateChange: (@Sendable (State) -> Void)?
    private let queue = DispatchQueue(label: "media.nuvio.remux", qos: .userInitiated)

    var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    // MARK: Seek-anywhere control plane

    /// Reposition mailbox + producing-position publication, guarded by one condition so the worker can
    /// park on it at EOF and `reposition()`/`stop()` can wake it. Single-slot latest-wins: AVPlayer only
    /// ever wants the newest position, so a queue would be wrong.
    private let control = NSCondition()
    private var _pendingTarget: Int?          // reposition target awaiting worker pickup
    private var _producingSeg = 0             // segment the worker is currently producing (0 = none yet)
    /// Audio-track switch mailbox (info-panel W3): the track AVPlayer just requested a rendition
    /// file for, and the segment that request was for (nil = the init segment / keep position).
    private var _pendingAudio: (track: Int, segment: Int?)?
    private var _activeAudio = -1             // stream index whose audio the worker is producing
    /// Interrupt flags shared with FFmpeg's blocking I/O (see `RemuxInterrupts`); set at input open.
    private var _interrupts: RemuxInterrupts?

    /// How far past the current production point a request is still worth waiting for instead of
    /// repositioning (mirrors LocalHLSServer.blockMargin — production reaches it within the JIT budget).
    static let repositionMargin = 6

    /// The segment the worker is producing right now, and any reposition target it hasn't reached yet.
    /// The JIT server uses this window to decide poll-vs-reposition.
    var producingInfo: (producing: Int, pending: Int?) {
        control.lock(); defer { control.unlock() }
        return (_producingSeg, _pendingTarget)
    }

    /// The audio track (avformat stream index) whose rendition segments are being produced right now.
    var activeAudioStream: Int { control.lock(); defer { control.unlock() }; return _activeAudio }

    /// Ask the worker to switch the produced audio rendition to `streamIndex`, restarting production
    /// at `segment` (the segment AVPlayer asked for; nil = the current producing segment). Non-blocking,
    /// latest-wins, safe from any thread. Ignored for the active track or an unplayable one.
    func selectAudio(streamIndex: Int, atSegment segment: Int?) {
        guard audioTracks.contains(where: { $0.streamIndex == streamIndex && $0.playable }) else { return }
        lock.lock(); let interrupts = _interrupts; lock.unlock()
        control.lock()
        if streamIndex == _activeAudio, _pendingAudio == nil { control.unlock(); return }
        if let pending = _pendingAudio, pending.track == streamIndex, pending.segment == segment {
            control.unlock(); return
        }
        _pendingAudio = (streamIndex, segment)
        // A switch that names a segment IS a reposition for the JIT window: publish it as the
        // pending target so the server's poll-vs-503 decision waits for the restart instead of
        // fast-failing a request that sits behind the old producing window.
        if let segment, segment >= 1, segment <= (segmentMap?.count ?? Int.max) { _pendingTarget = segment }
        interrupts?.repositionPending = true     // same read-kick as a reposition
        control.signal()
        control.unlock()
        print("[Remux] audio switch requested → stream \(streamIndex)" + (segment.map { " at segment \($0)" } ?? ""))
    }

    /// Ask the worker to jump production to `target` (1-based segment number). Non-blocking; safe from
    /// any thread. Latest-wins with lock-held admission: a target already inside the producing window
    /// is dropped (the worker will reach it — the caller polls), which absorbs AVPlayer's post-seek
    /// K, K+1, K+2 request burst so only the first miss repositions.
    func reposition(toSegment target: Int) {
        guard target >= 1, target <= (segmentMap?.count ?? Int.max) else { return }
        // The interrupt kick MUST be published atomically with the mailbox (inside the same critical
        // section): set after unlock, the worker can absorb the target and run its flag-clear in the
        // gap, leaving an orphaned flag that turns the next av_read_frame into a phantom fatal error.
        lock.lock(); let interrupts = _interrupts; lock.unlock()
        control.lock()
        let effective = _pendingTarget ?? _producingSeg
        if target >= effective, target <= effective + Self.repositionMargin {
            control.unlock()
            return
        }
        _pendingTarget = target
        // Kick the worker out of a blocked av_read_frame so the seek is responsive even when the
        // source is stalled (the exact moment a user is most likely to scrub).
        interrupts?.repositionPending = true
        control.signal()
        control.unlock()
        print("[Remux] reposition requested → segment \(target)")
    }

    /// Master-playlist signaling for the copied video, set once the video stream is inspected.
    /// `LocalHLSServer` bakes it into the synthesized master playlist (full RFC 6381 CODECS + DV
    /// SUPPLEMENTAL-CODECS; DV won't engage without it).
    var videoSignaling: VideoSignaling? { lock.lock(); defer { lock.unlock() }; return _signaling }

    /// The complete VOD segment map, derived from the source keyframe index at remux start (before any
    /// segment is produced). nil once the source is inspected means the index is unusable → the
    /// coordinator must fall back to mpv. `LocalHLSServer` synthesizes the VOD playlists from this and
    /// the remux cuts its fragments at the map's boundaries, so published == produced.
    var segmentMap: SegmentMap? { lock.lock(); defer { lock.unlock() }; return _segmentMap }

    /// Whether an audio track is muxed alongside video (single A/V representation).
    var hasAudio: Bool { lock.lock(); defer { lock.unlock() }; return _hasAudio }

    /// RFC 6381 audio codec token for the master CODECS list (e.g. "mp4a.40.2", "ac-3", "ec-3"), or nil.
    var audioCodecToken: String? { lock.lock(); defer { lock.unlock() }; return _audioCodecToken }

    /// Every audio stream the source carries, with playability and which one this session muxes —
    /// the data behind the player's Audio menu (D4). Populated with the signaling, before the map.
    var audioTracks: [RemuxAudioTrack] { lock.lock(); defer { lock.unlock() }; return _audioTracks }

    /// Every subtitle stream the source carries (text + bitmap), populated with the signaling.
    var subtitleTracks: [RemuxSubtitleTrack] { lock.lock(); defer { lock.unlock() }; return _subtitleTracks }
    /// Sink indices (position among the text tracks, in stream order) that actually got a decoder —
    /// only these become renditions; a track without a decoder would never get its files written.
    var subtitleSinkIndices: Set<Int> { lock.lock(); defer { lock.unlock() }; return _subtitleSinkIndices }

    /// Rough peak bandwidth for the master EXT-X-STREAM-INF (single variant — advisory, no ABR).
    var estimatedBandwidth: Int { lock.lock(); defer { lock.unlock() }; return _estimatedBandwidth }

    init(config: Config, outputDir: URL? = nil) {
        self.config = config
        self.outputDir = outputDir ?? RemuxSession.makeSessionDir()
        // Shields the directory from the launch orphan sweep. Must precede the worker's mkdir —
        // see RemuxCacheJanitor.registerLive.
        RemuxCacheJanitor.registerLive(self.outputDir)
    }

    /// Begin remuxing on a background queue. `onStateChange` fires on every transition (off-main).
    func start(onStateChange: @Sendable @escaping (State) -> Void) {
        lock.lock(); self.onStateChange = onStateChange; lock.unlock()
        queue.async { [weak self] in self?.runRemux() }
    }

    /// Request cancellation. Stops the copy loop at the next packet boundary, interrupts a blocked
    /// read, wakes a parked worker, and SILENCES the state callback — a post-stop `.failed("cancelled")`
    /// must not reach the coordinator, or it would trigger an mpv fallback after the user already left.
    func stop() {
        lock.lock()
        _cancelled = true
        onStateChange = nil
        let interrupts = _interrupts
        lock.unlock()
        interrupts?.cancelled = true
        control.lock(); control.signal(); control.unlock()
    }

    /// Remove the emitted directory once the worker has fully exited: enqueued on the worker's own
    /// serial queue, so it runs strictly after `runRemux` returns (a direct removal can race a final
    /// in-flight segment write).
    func scheduleCleanup() {
        queue.async { [outputDir] in
            try? FileManager.default.removeItem(at: outputDir)
            RemuxCacheJanitor.unregisterLive(outputDir)
        }
    }

    // MARK: - Remux worker

    private func runRemux() {
        setState(.running)
        // Errors/warnings only — the muxer otherwise logs two "Opening … for writing" info lines per
        // segment, which floods the Xcode console on long content.
        av_log_set_level(AV_LOG_WARNING)

        // --- Open + inspect the source ------------------------------------------------------------
        // +genpts: some sources (sloppy MKV muxes) emit packets with missing PTS/DTS, which poisons
        // the output fMP4 timeline (AVPlayer rejects it with CoreMediaErrorDomain -12927).
        var inOpts: OpaquePointer?
        av_dict_set(&inOpts, "fflags", "+genpts", 0)
        // Addon-declared stream headers (same block MediaProbe sent — the CDN that 403s a bare
        // probe 403s a bare remux read too). Ignored by non-HTTP protocols.
        if !config.requestHeaders.isEmpty {
            av_dict_set(&inOpts, "headers", MediaProbe.ffmpegHeaderBlock(config.requestHeaders), 0)
        }
        defer { av_dict_free(&inOpts) }
        // Interrupt callback on the INPUT: without it, a reposition or stop() arriving while
        // av_read_frame is blocked on a stalled HTTP read waits out the transport timeout (tens of
        // seconds) — exactly when the user is most likely to be scrubbing. The box outlives the input
        // via the `_interrupts` ivar.
        let interrupts = RemuxInterrupts()
        // Seed from the session cancel state in the same critical section: a stop() that ran before
        // this publication would otherwise never reach the box, leaving a stalled avformat_open_input
        // uninterruptible.
        lock.lock(); _interrupts = interrupts; interrupts.cancelled = _cancelled; lock.unlock()
        guard let allocated = avformat_alloc_context() else { return fail("alloc input ctx") }
        allocated.pointee.interrupt_callback = AVIOInterruptCB(
            callback: remuxShouldInterrupt,
            opaque: Unmanaged.passUnretained(interrupts).toOpaque())
        var inCtx: UnsafeMutablePointer<AVFormatContext>? = allocated
        // On failure avformat_open_input frees and nils the context it was given — no manual free.
        guard avformat_open_input(&inCtx, config.url.absoluteString, nil, &inOpts) == 0, let input = inCtx else {
            return fail("avformat_open_input")
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = input; avformat_close_input(&p) }
        guard avformat_find_stream_info(input, nil) >= 0 else { return fail("find_stream_info") }

        var videoIn = -1, audioCopyIn = -1, audioTranscodeIn = -1
        var foundAudio: [RemuxAudioTrack] = []
        var foundSubtitles: [RemuxSubtitleTrack] = []
        for i in 0..<Int(input.pointee.nb_streams) {
            guard let s = input.pointee.streams[i], let par = s.pointee.codecpar else { continue }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO where videoIn < 0: videoIn = i
            case AVMEDIA_TYPE_AUDIO:
                let copyable = isCopyableAudio(par.pointee.codec_id)
                let transcodable = AudioTranscoder.isTranscodable(par.pointee.codec_id)
                foundAudio.append(RemuxAudioTrack(
                    streamIndex: i,
                    codec: avcodec_get_name(par.pointee.codec_id).map { String(cString: $0) } ?? "",
                    channels: Int(par.pointee.ch_layout.nb_channels),
                    language: Self.metadataValue(s.pointee.metadata, "language"),
                    title: Self.metadataValue(s.pointee.metadata, "title"),
                    playable: copyable || transcodable,
                    codecToken: copyable ? Self.audioCodecString(par) : (transcodable ? "mp4a.40.2" : nil),
                    transcodes: !copyable && transcodable,
                    selected: false))
                if audioCopyIn < 0, copyable {
                    audioCopyIn = i
                } else if audioTranscodeIn < 0, transcodable {
                    audioTranscodeIn = i
                }
            case AVMEDIA_TYPE_SUBTITLE:
                let disposition = Int32(s.pointee.disposition)
                foundSubtitles.append(RemuxSubtitleTrack(
                    streamIndex: i,
                    codec: avcodec_get_name(par.pointee.codec_id).map { String(cString: $0) } ?? "",
                    language: Self.metadataValue(s.pointee.metadata, "language"),
                    title: Self.metadataValue(s.pointee.metadata, "title"),
                    isText: Self.isTextSubtitle(par.pointee.codec_id),
                    forced: disposition & AV_DISPOSITION_FORCED != 0,
                    hearingImpaired: disposition & AV_DISPOSITION_HEARING_IMPAIRED != 0))
            default: break
            }
        }
        if !foundSubtitles.isEmpty {
            print("[Remux] subtitle streams (\(foundSubtitles.count)): " + foundSubtitles.map {
                "#\($0.streamIndex) \($0.codec)\($0.isText ? "" : " (bitmap)")\($0.language.map { " [\($0)]" } ?? "")"
            }.joined(separator: ", "))
        }
        // Prefer a stream-copyable track (bit-exact, zero CPU); with none present, transcode a
        // TrueHD/DTS track to AAC (Phase 4 v2 — AVPlayer can't decode them and this FFmpeg build
        // ships no AC3/EAC3 encoder). See AudioTranscoder. An explicit choice from the player's
        // Audio menu (D4 — the rebuilt session's config carries the picked stream index) overrides
        // the automatic pick; a stale/unplayable request falls back to automatic rather than failing
        // the session.
        var audioIn = audioCopyIn >= 0 ? audioCopyIn : audioTranscodeIn
        // Language preference (initial track — an explicit config pick below wins).
        if config.audioStreamIndex == nil, foundAudio.count > 1,
           let preferred = config.preferredAudioPicker?(foundAudio),
           foundAudio.contains(where: { $0.streamIndex == preferred && $0.playable }) {
            audioIn = preferred
            print("[Remux] preferred-language audio pick → stream \(preferred)")
        }
        if let want = config.audioStreamIndex {
            if foundAudio.contains(where: { $0.streamIndex == want && $0.playable }) {
                audioIn = want
            } else {
                print("[Remux] requested audio stream \(want) missing/unplayable — using automatic pick")
            }
        }
        var audioTranscodes = foundAudio.first(where: { $0.streamIndex == audioIn })?.transcodes ?? false
        for i in foundAudio.indices { foundAudio[i].selected = foundAudio[i].streamIndex == audioIn }
        control.lock(); _activeAudio = audioIn; control.unlock()
        print("[Remux] audio streams (\(foundAudio.count)): "
              + foundAudio.map { "#\($0.streamIndex) \($0.codec) \($0.channels)ch"
                  + ($0.language.map { " [\($0)]" } ?? "")
                  + ($0.playable ? "" : " UNPLAYABLE")
                  + ($0.selected ? " *selected" : "") }.joined(separator: ", "))
        guard videoIn >= 0, let videoPar = input.pointee.streams[videoIn]?.pointee.codecpar else {
            return fail("no video stream")
        }
        // Some sources carry the video with EMPTY extradata (parameter sets only inband). The init
        // segment then has no valid hvcC/avcC decoder configuration and AVPlayer rejects the stream
        // with CoreMediaErrorDomain -12927. Recover the parameter sets from the bitstream, then
        // rewind so the copy loop starts from the beginning.
        if videoPar.pointee.extradata_size == 0 {
            print("[Remux] video extradata missing — extracting parameter sets from bitstream")
            guard extractVideoExtradata(input: input, videoIndex: videoIn) else {
                return fail("extract extradata")
            }
            guard av_seek_frame(input, Int32(videoIn), 0, AVSEEK_FLAG_BACKWARD) >= 0 else {
                return fail("rewind after extradata extraction")
            }
        }

        // AVPlayer admission control rejects High-tier HEVC declarations (master stage when declared
        // in CODECS: "unsupported URL"; media stage from the init segment's hvcC: -12927) even though
        // VideoToolbox decodes such streams fine — the declared tier is advisory. Patch the hvcC
        // record to Main tier; the bitstream itself is untouched.
        if videoPar.pointee.codec_id == AV_CODEC_ID_HEVC,
           videoPar.pointee.extradata_size >= 13,
           let ed = videoPar.pointee.extradata, ed[0] == 1, (ed[1] & 0x20) != 0 {
            ed[1] &= 0xDF
            print("[Remux] hvcC declares High tier — patched to Main tier for AVPlayer admission")
        }

        // Dolby Vision Profile 7 (dual-layer BluRay flavor) converts to single-layer 8.1 on the fly
        // (Phase 5): every video packet has its EL NALs dropped and its RPU rewritten by libdovi.
        // The stream's DOVI configuration is retagged FIRST — in place on the input codecpar, before
        // signaling/tagging derive from it and before any run's parameters_copy — so movenc's dvvC
        // box, the hvc1 sample entry and the master's SUPPLEMENTAL-CODECS all describe the converted
        // bitstream (profile 8, no EL, HDR10-compatible base → dvh1.08/db1p), never the source's.
        var doviConverter: DoviRpuConverter?
        if let dovi = Self.doviRecord(videoPar), dovi.dv_profile == 7 {
            guard let conv = DoviRpuConverter(videoPar: videoPar) else {
                return fail("DV P7 converter init (extradata not hvcC)")
            }
            doviConverter = conv
            Self.patchDoviConfToP81(videoPar)
            print("[Remux] DV P7 → 8.1 conversion engaged (EL drop + RPU rewrite)")
        }

        var signaling = Self.videoSignaling(videoPar)
        signaling.width = videoPar.pointee.width
        signaling.height = videoPar.pointee.height
        if let vs = input.pointee.streams[videoIn] {
            let fr = vs.pointee.avg_frame_rate
            if fr.num > 0, fr.den > 0 { signaling.frameRate = Double(fr.num) / Double(fr.den) }
        }
        var audioPar = audioIn >= 0 ? input.pointee.streams[audioIn]?.pointee.codecpar : nil
        // Transcoded audio is always AAC-LC (mp4a.40.2); its bandwidth contribution is the encoder
        // target, not the (much larger) TrueHD/DTS source bitrate. Every playable track is a
        // rendition of the one variant, so price the variant on the heaviest of them.
        let audioToken = foundAudio.first(where: { $0.streamIndex == audioIn })?.codecToken
        let audioBitrate = foundAudio.filter(\.playable).map { track -> Int in
            guard let par = input.pointee.streams[track.streamIndex]?.pointee.codecpar else { return 0 }
            return track.transcodes
                ? AudioTranscoder.targetBitrate(sourceChannels: par.pointee.ch_layout.nb_channels)
                : Int(par.pointee.bit_rate)
        }.max() ?? 0
        // Rough peak bandwidth for the (single, non-ABR) master variant. Generous: undersized
        // declarations draw CoreMedia -12318 "Segment exceeds specified bandwidth" complaints, and a
        // container that omits the VIDEO bitrate (common for MKV) must not be priced off audio alone.
        let declaredBitrate = Int(videoPar.pointee.bit_rate) + audioBitrate
        let bandwidth = videoPar.pointee.bit_rate > 0
            ? Int(Double(declaredBitrate) * 1.5)
            : max(Int(Double(declaredBitrate) * 1.5), 30_000_000)
        lock.lock()
        _signaling = signaling
        _hasAudio = audioIn >= 0
        _audioCodecToken = audioToken
        _audioTracks = foundAudio
        _subtitleTracks = foundSubtitles
        _estimatedBandwidth = bandwidth
        lock.unlock()
        print("[Remux] signaling CODECS=\(signaling.codecs)"
              + (signaling.supplementalCodecs.map { " SUPPLEMENTAL=\($0)" } ?? "")
              + (audioToken.map { " AUDIO=\($0)" } ?? "")
              + (audioTranscodes ? " (transcode)" : ""))
        if foundAudio.count > 1 {
            let listing = foundAudio.map {
                "#\($0.streamIndex)\($0.selected ? "*" : "") \($0.codec) \($0.channels)ch"
                + ($0.language.map { " \($0)" } ?? "") + ($0.playable ? "" : " UNPLAYABLE")
            }.joined(separator: " | ")
            print("[Remux] audio tracks: \(listing)")
        }

        // --- Build the up-front VOD segment map from the source keyframe index --------------------
        // The owned segmenter cuts fragments at exactly these keyframe boundaries, so the synthesized
        // VOD playlist matches the produced files. nil ⇒ unusable index (empty / too sparse) ⇒ mpv.
        guard let map = buildSegmentMap(input: input, videoIndex: videoIn) else {
            return fail("no usable keyframe index")
        }
        lock.lock(); _segmentMap = map; lock.unlock()
        print("[Remux] segment map: \(map.count) segments, \(String(format: "%.1f", map.totalDurationSec))s, target=\(map.targetDurationSec)s")

        // --- Multi-run production with seek-anywhere ------------------------------------------------
        // Segments are produced in RUNS: one mp4 muxer context copying linearly from a start segment
        // until EOF, a reposition request, cancellation, or an error. Seek-anywhere = end the current
        // run and start a new one at the requested segment: the demuxer seeks (Range HTTP) to that
        // segment's boundary keyframe and a FRESH muxer context continues from there. All timestamps
        // are mapped onto the playlist timeline (origin = the first keyframe) and passed ABSOLUTE
        // (avoid_negative_ts=disabled + movflag frag_discont), so every fragment's tfdt equals its
        // playlist position no matter which run produced it — verified empirically: without
        // frag_discont, movenc normalizes a fresh context's start to zero and encodes the offset as an
        // edit list, which HLS ignores. The worker never exits at EOF; it PARKS so late seeks into
        // unproduced holes can still reposition it, until stop().
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // --- Embedded text-subtitle sinks (info-panel W2) ---------------------------------------------
        // One sink per text subtitle stream, keyed by input stream index; sink order = the order the
        // coordinator lists embedded renditions in (RemuxSubtitleTrack text tracks, in stream order).
        // A track libavcodec can't decode is skipped (its rendition is still listed — the server then
        // serves header-only VTTs for it — so the master's sink numbering stays aligned).
        var subSinks: [Int: EmbeddedSubtitleSink] = [:]
        do {
            let vtb = input.pointee.streams[videoIn]!.pointee.time_base
            let videoTBSec = Double(vtb.num) / Double(vtb.den)
            let originSec = Double(map.boundaryTicks[0]) * videoTBSec
            let starts = map.segments.map { Double($0.startTicks) * videoTBSec - originSec }
            var sinkIndex = 0
            for track in foundSubtitles where track.isText {
                defer { sinkIndex += 1 }
                guard let s = input.pointee.streams[track.streamIndex], let par = s.pointee.codecpar else { continue }
                if let sink = EmbeddedSubtitleSink(sinkIndex: sinkIndex, streamIndex: track.streamIndex,
                                                   codecpar: par, timeBase: s.pointee.time_base,
                                                   originSec: originSec, segmentStartsSec: starts,
                                                   totalDurationSec: map.totalDurationSec, outputDir: outputDir,
                                                   stripSdh: config.stripSdh) {
                    subSinks[track.streamIndex] = sink
                } else {
                    print("[Remux] subtitle stream #\(track.streamIndex) (\(track.codec)): no decoder — not extracted")
                }
            }
            if !subSinks.isEmpty {
                print("[Remux] embedded subtitle sinks: \(subSinks.count) (\(subSinks.values.map { "#\($0.streamIndex)→esub-\($0.sinkIndex)" }.sorted().joined(separator: ", ")))")
            }
        }
        lock.lock(); _subtitleSinkIndices = Set(subSinks.values.map(\.sinkIndex)); lock.unlock()

        guard let pkt = av_packet_alloc() else { return fail("packet_alloc") }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        let noTS = Int64.min                                     // AV_NOPTS_VALUE
        let reorderSlack: Int64 = 6                              // frames of pts>=dts headroom
        let boundaries = map.boundaryTicks
        let originTicks = boundaries[0]                          // playlist time zero, video time_base
        let videoTag = videoOutputTag(videoPar)
        guard let videoStream = input.pointee.streams[videoIn] else { return fail("video stream") }
        let videoTB = videoStream.pointee.time_base

        var vDur: Int64 = 0             // learned frame duration — a stream constant, kept across runs
        var isFirstRun = true
        var everRepositioned = false
        var consecutiveErrorParks = 0
        var startSeg = 1                // segment the next run begins at
        var pendingBoundaryPacket = false   // pkt already holds the new run's boundary keyframe
        /// Audio tracks whose `aud-<T>-init.mp4` is on disk — a later run for the same track re-emits
        /// ftyp+moov, which is parsed and discarded like the video init.
        var audioInitWritten = Set<Int>()
        var videoInitWritten = false

        // One muxer per representation per run (info-panel W3): the VIDEO-ONLY variant and the ACTIVE
        // audio track's audio-only rendition, each with its own mp4 context, AVIO sink and file names,
        // both cut at the video keyframe boundaries so the two playlists share one segment grid.
        // Streams are added in the same order every run (same track IDs and timescales as the init
        // segments AVPlayer holds). `originOut` = the playlist origin in that context's stream time_base.
        struct Mux {
            let ctx: UnsafeMutablePointer<AVFormatContext>
            let writer: SegmentWriter
            let opaque: UnsafeMutableRawPointer
            let outStream: UnsafeMutablePointer<AVStream>
            let originOut: Int64
        }
        typealias Run = (video: Mux, audio: Mux?)
        func makeMux(inIdx: Int, tag: UInt32, transcoder: AudioTranscoder?, initName: String, discardInit: Bool) -> Mux? {
            var outCtx: UnsafeMutablePointer<AVFormatContext>?
            guard avformat_alloc_output_context2(&outCtx, nil, "mp4", nil) >= 0, let output = outCtx else { return nil }
            output.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL   // allow the DV (dvvC) box
            // We own the timeline: timestamps arrive pre-mapped onto the playlist origin, absolute.
            // Core-level shifting would desync tfdt from the published playlist. (-1 = DISABLED.)
            output.pointee.avoid_negative_ts = -1

            guard let inS = input.pointee.streams[inIdx], let inPar = inS.pointee.codecpar,
                  let outS = avformat_new_stream(output, nil), let outPar = outS.pointee.codecpar else {
                avformat_free_context(output); return nil
            }
            if let tx = transcoder {
                // Transcode mode: the audio stream's codecpar comes from the AAC ENCODER (including the
                // AudioSpecificConfig extradata movenc needs for the esds box), not the source track.
                guard avcodec_parameters_from_context(outPar, tx.encoderCtx) >= 0 else { avformat_free_context(output); return nil }
                outS.pointee.time_base = AVRational(num: 1, den: tx.outputSampleRate)
            } else {
                guard avcodec_parameters_copy(outPar, inPar) >= 0 else { avformat_free_context(output); return nil }
                if tag != 0 { outPar.pointee.codec_tag = tag }   // hvc1/dvh1/avc1; movenc picks for audio
                outS.pointee.time_base = inS.pointee.time_base
            }

            // Segment-splitting AVIO sink (append-only; box-router). Retained by the AVIO context —
            // released in destroyMux after no callback can fire. A non-first run's duplicate ftyp+moov
            // is parsed and DISCARDED (the init is already on disk; rewriting it mid-session would
            // risk serving a moov different from the one AVPlayer admitted).
            let writer = SegmentWriter(outputDir: outputDir, initName: initName, discardInit: discardInit)
            let ioBufSize = 1 << 16
            guard let ioBuf = av_malloc(ioBufSize) else { avformat_free_context(output); return nil }
            let opaque = Unmanaged.passRetained(writer).toOpaque()
            guard let avio = avio_alloc_context(ioBuf.assumingMemoryBound(to: UInt8.self), Int32(ioBufSize),
                                                1, opaque, nil, segmentWriterWrite, nil) else {
                av_free(ioBuf)
                Unmanaged<SegmentWriter>.fromOpaque(opaque).release()
                avformat_free_context(output)
                return nil
            }
            output.pointee.pb = avio

            // frag_custom: WE cut fragments. delay_moov: EAC3's dec3 sample entry needs a parsed
            // frame, so the moov comes at the first fragment flush. skip_trailer: no mfra.
            // frag_discont: do NOT normalize this context's first fragment — timestamps are absolute.
            var opts: OpaquePointer?
            av_dict_set(&opts, "movflags",
                        "frag_custom+empty_moov+default_base_moof+delay_moov+skip_trailer+frag_discont", 0)
            defer { av_dict_free(&opts) }
            guard avformat_write_header(output, &opts) >= 0 else {
                if let pb = output.pointee.pb {
                    av_free(pb.pointee.buffer)
                    var pp: UnsafeMutablePointer<AVIOContext>? = pb
                    avio_context_free(&pp)
                    output.pointee.pb = nil
                }
                Unmanaged<SegmentWriter>.fromOpaque(opaque).release()
                avformat_free_context(output)
                return nil
            }
            avio_flush(output.pointee.pb)
            // TIMESCALE TRAP: avformat_write_header lets movenc REWRITE each stream's time_base
            // (video 1/1000 → 1/16000, audio → 1/samplerate). Packets are rescaled into the
            // POST-header time_base, so every constant we subtract from or compare against them —
            // the playlist origin here, the grid anchor at the call site — must be rescaled into the
            // post-header time_base too, never the input's. (Found the hard way: a reposition's grid
            // anchor in source scale produced ~28s composition offsets.)
            let originOut = av_rescale_q(originTicks, videoTB, outS.pointee.time_base)
            return Mux(ctx: output, writer: writer, opaque: opaque, outStream: outS, originOut: originOut)
        }

        // Tear a muxer down: buffered fragment bytes drain into the discard sink via the trailer, then
        // the AVIO context is freed (before the format ctx) and the sink retain released.
        func destroyMux(_ mux: Mux) {
            mux.writer.beginDiscard()
            _ = av_write_trailer(mux.ctx)
            if let pb = mux.ctx.pointee.pb {
                av_free(pb.pointee.buffer)
                var p: UnsafeMutablePointer<AVIOContext>? = pb
                avio_context_free(&p)
                mux.ctx.pointee.pb = nil
            }
            Unmanaged<SegmentWriter>.fromOpaque(mux.opaque).release()
            avformat_free_context(mux.ctx)
        }
        func destroyRun(_ run: Run) {
            // Record which inits actually reached disk BEFORE tearing down: delay_moov emits the moov
            // at the first fragment flush, so a run interrupted before its first boundary never wrote
            // its init — the next run for that representation must emit (not discard) it.
            if run.video.writer.initFinalized { videoInitWritten = true }
            if let a = run.audio, a.writer.initFinalized { audioInitWritten.insert(audioIn) }
            destroyMux(run.video)
            if let a = run.audio { destroyMux(a) }
        }

        // Mailbox helpers. Producing is published and the mailbox cleared in the SAME critical
        // section, so the JIT window (pending ?? producing) never has a gap for AVPlayer's post-seek
        // K+1/K+2 burst to slip a spurious reposition through.
        func takeReposition() -> Int? {
            control.lock(); defer { control.unlock() }
            return _pendingTarget
        }
        func takeAudioSwitch() -> (track: Int, segment: Int?)? {
            control.lock(); defer { control.unlock() }
            return _pendingAudio
        }
        func publishProducing(_ seg: Int) {
            control.lock()
            _producingSeg = seg
            if _pendingTarget == seg { _pendingTarget = nil }
            control.unlock()
        }
        // Park until a reposition / audio-switch request or stop(). nil ⇒ cancelled. Timed waits are
        // lost-wakeup insurance; reposition(), selectAudio() and stop() all signal.
        func parkForRequest() -> Bool {
            control.lock()
            while _pendingTarget == nil, _pendingAudio == nil, !isCancelled() {
                control.wait(until: Date().addingTimeInterval(0.25))
            }
            control.unlock()
            return !isCancelled()
        }
        /// Consume a pending audio switch: becomes the active track; returns the segment to restart at.
        func applyAudioSwitch(currentSeg: Int) -> Int? {
            control.lock(); defer { control.unlock() }
            guard let pending = _pendingAudio else { return nil }
            _pendingAudio = nil
            _activeAudio = pending.track
            return pending.segment ?? currentSeg
        }

        // After av_seek_frame, read until the boundary keyframe — it becomes the new run's first
        // packet (left in pkt; the caller sets pendingBoundaryPacket). Audio before the boundary is
        // dropped (sub-second gap at worst; the absolute timeline re-aligns). Returns false on cancel,
        // read failure, a newer reposition (the interrupt kicks the read out), or landing on the wrong
        // keyframe — one mis-timed segment would poison the published VOD timeline, so verify + abort.
        func scanToBoundary(_ targetTicks: Int64) -> Bool {
            let tolerance = max(vDur, 2)
            while true {
                if isCancelled() { return false }
                let r = av_read_frame(input, pkt)
                if r < 0 {
                    if r == avErrorExit, interrupts.repositionPending, takeReposition() == nil, takeAudioSwitch() == nil {
                        interrupts.repositionPending = false   // spurious kick — keep scanning
                        continue
                    }
                    print("[Remux] reposition scan ended (\(r))")
                    return false
                }
                // Subtitle pre-roll: cues read between the seek point and the boundary keyframe may
                // still be active inside the target segment — feed them, don't drop them.
                if let sink = subSinks[Int(pkt.pointee.stream_index)] { sink.ingest(pkt) }
                if Int(pkt.pointee.stream_index) == videoIn,
                   (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0,
                   pkt.pointee.pts != noTS, pkt.pointee.pts + tolerance > targetTicks {
                    if abs(pkt.pointee.pts - targetTicks) >= tolerance {
                        print("[Remux] reposition landed at pts=\(pkt.pointee.pts) wanted \(targetTicks) — aborting")
                        av_packet_unref(pkt)
                        return false
                    }
                    return true
                }
                av_packet_unref(pkt)
            }
        }

        runLoop: while !isCancelled() {
            // Take a pending audio switch first: it defines this run's audio track (and, when it came
            // with a segment, where the run starts). Runs are the switch granularity — the audio muxer
            // and its transcoder are per run, so a switch is just "next run, other track".
            if let seg = applyAudioSwitch(currentSeg: startSeg) {
                startSeg = seg
                everRepositioned = true
                if isFirstRun { isFirstRun = false }   // a switch before the first run still seeks
            }
            control.lock(); let runAudioIn = _activeAudio; control.unlock()
            if runAudioIn != audioIn {
                audioIn = runAudioIn
                audioPar = audioIn >= 0 ? input.pointee.streams[audioIn]?.pointee.codecpar : nil
                audioTranscodes = foundAudio.first(where: { $0.streamIndex == audioIn })?.transcodes ?? false
                lock.lock()
                for i in _audioTracks.indices { _audioTracks[i].selected = _audioTracks[i].streamIndex == audioIn }
                _audioCodecToken = _audioTracks.first(where: \.selected)?.codecToken
                lock.unlock()
                print("[Remux] audio track → stream \(audioIn)\(audioTranscodes ? " (transcode)" : "") from segment \(startSeg)")
            }

            // Position the demuxer for a non-initial run.
            if !isFirstRun {
                interrupts.repositionPending = false        // must not abort our own seek/scan
                avformat_flush(input)                        // clear sticky EOF/queued packets
                for sink in subSinks.values { sink.resetForReposition() }   // before the scan feeds them
                let target = map.segments[startSeg - 1].startTicks
                print("[Remux] seeking to segment \(startSeg) (pts \(target))")
                if av_seek_frame(input, Int32(videoIn), target, AVSEEK_FLAG_BACKWARD) < 0 || !scanToBoundary(target) {
                    if isCancelled() { break runLoop }
                    if let newer = takeReposition(), newer != startSeg {
                        startSeg = newer                     // a newer target interrupted the scan
                        continue runLoop
                    }
                    if takeAudioSwitch() != nil { continue runLoop }   // a switch interrupted the scan
                    consecutiveErrorParks += 1
                    guard consecutiveErrorParks < 4 else { return fail("reposition failed repeatedly") }
                    guard parkForRequest() else { break runLoop }
                    if let next = takeReposition() { startSeg = next }
                    continue runLoop
                }
                pendingBoundaryPacket = true
            }

            // Fresh transcoder per run: decoder/resampler/fifo state must not leak across a seek,
            // and the run's muxer header takes its audio codecpar from the new encoder.
            var audioTx: AudioTranscoder?
            if audioTranscodes, let par = audioPar, let audioStream = input.pointee.streams[audioIn] {
                guard let tx = AudioTranscoder(sourcePar: par, sourceTimeBase: audioStream.pointee.time_base) else {
                    return fail("audio transcoder init")
                }
                audioTx = tx
            }
            guard let videoMux = makeMux(inIdx: videoIn, tag: videoTag, transcoder: nil,
                                         initName: "init.mp4", discardInit: videoInitWritten) else {
                return fail("output context")
            }
            var audioMux: Mux?
            if audioIn >= 0 {
                let track = foundAudio.first(where: { $0.streamIndex == audioIn })
                    ?? RemuxAudioTrack(streamIndex: audioIn, codec: "", channels: 0, language: nil, title: nil,
                                       playable: true, codecToken: nil, transcodes: false, selected: true)
                guard let a = makeMux(inIdx: audioIn, tag: 0, transcoder: audioTx,
                                      initName: track.initName, discardInit: audioInitWritten.contains(audioIn)) else {
                    destroyMux(videoMux); return fail("audio output context")
                }
                audioMux = a
            }
            let run: Run = (videoMux, audioMux)
            isFirstRun = false
            publishProducing(startSeg)

            // Per-run timeline state. The video grid re-anchors at the run's start boundary on the
            // playlist timeline; the audio floor keeps a timestamp-less packet from landing at t=0.
            // anchorSrcTicks is in the SOURCE video time_base; every per-stream constant is rescaled
            // into that stream's POST-header time_base (see the timescale-trap note in makeMux).
            let anchorSrcTicks = map.segments[startSeg - 1].startTicks - originTicks
            let vAnchorOut = av_rescale_q(anchorSrcTicks, videoTB, run.video.outStream.pointee.time_base)
            var vIndex: Int64 = 0
            var vPrevDTS: Int64? = nil
            var aNextDTS: Int64 = noTS
            let aFloor: Int64 = run.audio.map { av_rescale_q(anchorSrcTicks, videoTB, $0.outStream.pointee.time_base) } ?? 0
            var currentSeg = startSeg
            var nextBoundary = startSeg     // boundaries[startSeg] opens segment startSeg+1
            let activeTrack = foundAudio.first(where: { $0.streamIndex == audioIn })
            func beginSegmentFiles(_ seg: Int) {
                run.video.writer.beginFile(named: Self.segmentName(seg))
                if let track = activeTrack { run.audio?.writer.beginFile(named: track.segmentName(seg)) }
            }
            beginSegmentFiles(currentSeg)

            // Bind the transcoder to this run's audio output (post-header time_base — timescale trap)
            // and define its emit path: encoded packets arrive already on the playlist timeline.
            if let tx = audioTx, let a = run.audio {
                tx.beginRun(outStreamIndex: 0, outTimeBase: a.outStream.pointee.time_base,
                            originOut: a.originOut, fallbackAnchorOut: aFloor)
            }
            func writeTranscodedAudio(_ p: UnsafeMutablePointer<AVPacket>) -> Bool {
                guard let a = run.audio else { return false }
                return av_write_frame(a.ctx, p) >= 0
            }

            // Flush the pending fragment of one muxer. Under delay_moov the FIRST flush of a context
            // emits only the moov (samples stay buffered for the next flush) — detect via the sink and
            // force one extra flush so every boundary yields exactly one fragment in its own file.
            func flushFragment(_ mux: Mux) -> Bool {
                if av_write_frame(mux.ctx, nil) < 0 { return false }
                avio_flush(mux.ctx.pointee.pb)
                if mux.writer.awaitingFirstFragment {
                    if av_write_frame(mux.ctx, nil) < 0 { return false }
                    avio_flush(mux.ctx.pointee.pb)
                }
                return true
            }
            /// Cut both representations at the current boundary: flush + finalize the video segment
            /// and the audio segment. Neither may be empty mid-stream — a video-aligned window with
            /// no audio packet means a source this pipeline can't represent (audio interleaved more
            /// than a segment late, or starting late), so the session fails and the coordinator
            /// falls back to mpv rather than publishing an invalid rendition segment. Only the FINAL
            /// segment tolerates an empty audio window (audio ending a little before the video).
            func finalizeSegmentFiles(isFinal: Bool = false) -> Bool {
                guard flushFragment(run.video), run.video.writer.finalizeCurrent() else { return false }
                if let a = run.audio {
                    guard flushFragment(a) else { return false }
                    if !a.writer.finalizeCurrent(allowEmpty: isFinal), !isFinal {
                        print("[Remux] audio window empty at segment \(currentSeg) — source not representable as aligned renditions")
                        return false
                    }
                }
                for sink in subSinks.values { sink.finalizeSegment(currentSeg) }
                return true
            }

            enum RunEnd { case eof, error, repositioned(Int), audioSwitch, cancelled }
            var runEnd: RunEnd?

            while runEnd == nil {
                if isCancelled() { runEnd = .cancelled; break }
                if takeAudioSwitch() != nil {
                    // Consumed at the top of runLoop (becomes the next run's track/start).
                    av_packet_unref(pkt)
                    runEnd = .audioSwitch
                    break
                }
                if let target = takeReposition() {
                    if target >= currentSeg, target <= currentSeg + Self.repositionMargin {
                        // Production will reach it shortly — absorb. Mailbox and interrupt kick are
                        // cleared in ONE critical section, and only when the mailbox actually clears:
                        // an unconditional clear could eat a newer concurrent target's read-kick.
                        publishProducing(currentSeg)
                        control.lock()
                        if _pendingTarget == target {
                            _pendingTarget = nil
                            interrupts.repositionPending = false
                        }
                        control.unlock()
                    } else {
                        everRepositioned = true
                        av_packet_unref(pkt)
                        runEnd = .repositioned(target)
                        break
                    }
                }
                if pendingBoundaryPacket {
                    pendingBoundaryPacket = false           // pkt already holds the boundary keyframe
                } else {
                    let r = av_read_frame(input, pkt)
                    if r < 0 {
                        if isCancelled() { runEnd = .cancelled }
                        else if takeAudioSwitch() != nil { everRepositioned = true; runEnd = .audioSwitch }
                        else if let target = takeReposition() { everRepositioned = true; runEnd = .repositioned(target) }
                        else if r == avErrorEOF { runEnd = .eof }
                        else if r == avErrorExit, interrupts.repositionPending {
                            // Defense-in-depth: a stray interrupt kick with an already-consumed
                            // mailbox is a spurious wakeup, not a read failure — clear and retry.
                            interrupts.repositionPending = false
                            continue
                        }
                        else { print("[Remux] read error \(r) at segment \(currentSeg)"); runEnd = .error }
                        break
                    }
                }
                let inIdx = Int(pkt.pointee.stream_index)
                if let sink = subSinks[inIdx] {          // embedded text subtitle → VTT sink
                    sink.ingest(pkt)
                    av_packet_unref(pkt)
                    continue
                }
                let isVideo = inIdx == videoIn
                let isAudio = inIdx == audioIn && run.audio != nil
                guard isVideo || isAudio, let inS = input.pointee.streams[inIdx] else {
                    av_packet_unref(pkt)
                    continue
                }
                let mux = isVideo ? run.video : run.audio!
                let outS = mux.outStream

                // Transcode mode consumes the SOURCE packet (source time_base) — decode → resample →
                // AAC packets emitted on the playlist timeline. Cuts stay video-driven; encoded audio
                // lands in whatever segment window is open when it emerges, same as copied audio.
                if isAudio, let tx = audioTx {
                    let ok = tx.process(pkt, write: writeTranscodedAudio)
                    av_packet_unref(pkt)
                    if !ok { runEnd = .error }
                    continue
                }

                // DV P7 → 8.1: rewrite the packet (drop EL NALs, convert the RPU) before anything
                // downstream — cut decisions, DTS grid, muxer — sees it. Timestamps and flags are
                // untouched, so the boundary logic behaves exactly as for a native 8.1 source.
                if isVideo, let conv = doviConverter, !conv.filterPacket(pkt) {
                    print("[Remux] DV P7 conversion aborted — \(conv.abortReason ?? "unknown")")
                    av_packet_unref(pkt)
                    runEnd = .error
                    break
                }

                // Cut BEFORE writing the keyframe that opens the next segment, so the boundary
                // keyframe becomes the first sample of the new fragment. Compared in the SOURCE pts
                // domain — the same domain the keyframe index gave us.
                if isVideo, nextBoundary < boundaries.count,
                   pkt.pointee.pts != noTS, pkt.pointee.pts >= boundaries[nextBoundary],
                   (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                    guard finalizeSegmentFiles() else {
                        print("[Remux] fragment flush/finalize failed at segment \(currentSeg) boundary")
                        av_packet_unref(pkt); runEnd = .error; break
                    }
                    currentSeg += 1
                    nextBoundary += 1
                    publishProducing(currentSeg)
                    if (currentSeg - 1) % 15 == 0 || currentSeg == startSeg + 1 {
                        print("[Remux] seg \(currentSeg - 1) done footprint=\(processFootprintMB())MB")
                    }
                    consecutiveErrorParks = 0   // a finalized segment = real progress; the error cap
                                                // counts genuinely consecutive non-productive failures
                    beginSegmentFiles(currentSeg)
                }

                av_packet_rescale_ts(pkt, inS.pointee.time_base, outS.pointee.time_base)
                pkt.pointee.stream_index = 0
                pkt.pointee.pos = -1
                // Map onto the playlist timeline: all runs share one absolute origin.
                if pkt.pointee.pts != noTS { pkt.pointee.pts -= mux.originOut }
                if pkt.pointee.dts != noTS { pkt.pointee.dts -= mux.originOut }

                // Pre-origin pre-roll: when the source's first INDEXED keyframe sits after earlier
                // frames (matroskadec occasionally fails to index the very first Cue; open-GOP RASL
                // frames then follow the origin CRA with earlier pts), packets from before playlist
                // time zero arrive in the first run. They can't be presented — the published
                // timeline starts at the origin — and their negative pts make movenc reject the
                // write with EINVAL (pts < dts). Drop them before they reach the DTS grid.
                if isVideo, pkt.pointee.pts != noTS, pkt.pointee.pts < 0 {
                    av_packet_unref(pkt)
                    continue
                }

                if isVideo {
                    // Video DTS regenerated on a uniform grid (sloppy sources carry missing or
                    // non-monotonic DTS; AVPlayer rejects such timelines with -12927). Anchored at
                    // the run's start boundary, offset back for B-frame reorder, clamped at zero.
                    if pkt.pointee.duration > 0 {
                        vDur = pkt.pointee.duration
                    } else if vDur == 0, pkt.pointee.pts != noTS, pkt.pointee.pts > vAnchorOut {
                        vDur = pkt.pointee.pts - vAnchorOut
                    }
                    var dts = vAnchorOut + (vIndex - reorderSlack) * max(vDur, 1)
                    if dts < 0 { dts = 0 }
                    if pkt.pointee.pts != noTS, dts > pkt.pointee.pts { dts = pkt.pointee.pts }
                    if let prev = vPrevDTS, dts <= prev { dts = prev + 1 }
                    vPrevDTS = dts
                    pkt.pointee.dts = dts
                    if pkt.pointee.pts == noTS { pkt.pointee.pts = vAnchorOut + vIndex * max(vDur, 1) }
                    vIndex += 1
                } else {
                    // Audio keeps source timestamps; gap-fill only when absent, floored at the run
                    // start so a timestamp-less packet can't land at t=0 in a fragment at t=T_K.
                    if pkt.pointee.dts == noTS {
                        pkt.pointee.dts = pkt.pointee.pts != noTS ? pkt.pointee.pts
                            : (aNextDTS != noTS ? aNextDTS : aFloor)
                    }
                    if aNextDTS != noTS, pkt.pointee.dts < aNextDTS { pkt.pointee.dts = aNextDTS }
                    if pkt.pointee.dts < 0 { pkt.pointee.dts = 0 }
                    if pkt.pointee.pts == noTS || pkt.pointee.pts < pkt.pointee.dts { pkt.pointee.pts = pkt.pointee.dts }
                    aNextDTS = pkt.pointee.dts + max(pkt.pointee.duration, 1)
                }

                let wr = av_write_frame(mux.ctx, pkt)
                if wr < 0 {
                    print("[Remux] write error \(wr) at segment \(currentSeg) "
                          + "(\(isVideo ? "video" : "audio") dts=\(pkt.pointee.dts) pts=\(pkt.pointee.pts) size=\(pkt.pointee.size))")
                    av_packet_unref(pkt); runEnd = .error; break
                }
                av_packet_unref(pkt)
            }

            switch runEnd ?? .cancelled {
            case .cancelled:
                destroyRun(run)
                break runLoop

            case .repositioned(let target):
                print("[Remux] repositioning: abandoning segment \(currentSeg), jumping to \(target)")
                destroyRun(run)                              // partial segment dropped, never finalized
                startSeg = target
                consecutiveErrorParks = 0
                continue runLoop

            case .audioSwitch:
                print("[Remux] audio switch: abandoning segment \(currentSeg)")
                destroyRun(run)                              // partial segment dropped, never finalized
                startSeg = currentSeg                        // default restart; the mailbox may carry a segment
                consecutiveErrorParks = 0
                continue runLoop

            case .error:
                destroyRun(run)
                if !everRepositioned { return fail("read/write error at segment \(currentSeg)") }
                // Repositioned sessions self-heal: park; the JIT re-request repositions us again.
                consecutiveErrorParks += 1
                guard consecutiveErrorParks < 4 else { return fail("repeated run errors") }
                guard parkForRequest() else { break runLoop }
                if let next = takeReposition() { startSeg = next }
                continue runLoop

            case .eof:
                // Natural EOF. Completeness gate: a NEVER-repositioned run short of the map means a
                // truncated source — fail so the coordinator uses mpv (serving .ready would strand
                // AVPlayer waiting forever). A repositioned run's EOF means the TAIL is complete;
                // holes below are legal and self-heal via reposition on demand.
                var tailOK = true
                if currentSeg == map.count, nextBoundary == boundaries.count {
                    // Drain the transcode pipeline (decoder + resampler tail + encoder) into the
                    // final segment before its fragment is flushed.
                    if let tx = audioTx { tailOK = tx.drain(write: writeTranscodedAudio) }
                    tailOK = tailOK && finalizeSegmentFiles(isFinal: true)
                }
                let shortLinear = currentSeg != map.count && !everRepositioned
                destroyRun(run)
                if !tailOK { return fail("final segment flush") }
                if shortLinear { return fail("truncated remux (\(currentSeg)/\(map.count) segments)") }
                if currentSeg != map.count {
                    print("[Remux] repositioned run EOF at \(currentSeg)/\(map.count) — partial dropped")
                }
                if state != .ready { setState(.ready) }
                consecutiveErrorParks = 0
                if let conv = doviConverter { print("[Remux] DV P7→8.1: \(conv.statsDescription)") }
                print("[Remux] parked at EOF — repositions still serviced")
                guard parkForRequest() else { break runLoop }
                everRepositioned = true
                if let next = takeReposition() { startSeg = next } else { startSeg = currentSeg }
                continue runLoop
            }
        }
        // Only cancellation exits the loop; stop() already silenced the state callback.
        fail("cancelled")
    }

    // MARK: - Segment map / naming

    /// Build the complete VOD segment map from the video stream's keyframe index. mov's `stss` index
    /// is complete at open, but matroskadec only exposes Cues as index entries once a seek forces it to
    /// parse them — so when the index looks empty we PRIME it with a seek to the end (which loads the
    /// full Cues), then rewind to the start so the copy loop reads from the beginning. Returns nil when
    /// the index is still empty or too sparse — the caller then falls back to mpv.
    private func buildSegmentMap(input: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int) -> SegmentMap? {
        guard let vs = input.pointee.streams[videoIndex] else { return nil }

        let tb = vs.pointee.time_base
        // Prefer the video stream's own duration; fall back to the container's (µs).
        let durationSec: Double = vs.pointee.duration > 0
            ? Double(vs.pointee.duration) * Double(tb.num) / Double(tb.den)
            : (input.pointee.duration > 0 ? Double(input.pointee.duration) / 1_000_000.0 : 0)

        var ticks = keyframeTicks(vs)
        // Prime whenever the index is too sparse to yield a usable map, not just when it's empty:
        // find_stream_info's probing deposits a FEW keyframe entries (device truth: 3-6 on
        // high-bitrate remuxes), which must not defeat priming — tail-loaded Cues (mkvmerge default)
        // only parse once a seek forces them, while front-loaded Cues are indexed at open. The
        // threshold mirrors SegmentMap.build's own sparsity gate (avg segment ≤ 30s), so any index
        // that would be rejected below triggers one priming attempt first.
        let minUsable = durationSec > 0 ? Int(durationSec / 30) + 1 : 2
        if ticks.count < max(2, minUsable), input.pointee.duration > 0 {
            // stream_index -1 ⇒ timestamp is in AV_TIME_BASE (µs), matching input.duration.
            av_seek_frame(input, -1, input.pointee.duration, AVSEEK_FLAG_BACKWARD)
            let primed = keyframeTicks(vs)
            if primed.count > ticks.count { ticks = primed }
            av_seek_frame(input, -1, 0, AVSEEK_FLAG_BACKWARD)     // rewind for the copy loop
        }
        print("[Remux] keyframe index: \(ticks.count) keyframes tb=\(tb.num)/\(tb.den) dur=\(String(format: "%.1f", durationSec))s")
        return SegmentMap.build(keyframeTicks: ticks, timeBaseNum: tb.num, timeBaseDen: tb.den,
                                totalDurationSec: durationSec, segDurSec: config.segmentDurationSec)
    }

    /// Snapshot the video stream's current keyframe index entries as PTS in the stream time_base.
    private func keyframeTicks(_ vs: UnsafeMutablePointer<AVStream>) -> [Int64] {
        let count = avformat_index_get_entries_count(vs)
        var ticks: [Int64] = []
        ticks.reserveCapacity(Int(max(count, 0)))
        for i in 0..<count {
            guard let e = avformat_index_get_entry(vs, i) else { continue }
            let entry = e.pointee
            guard entry.timestamp != Int64.min else { continue }
            if (entry.flags & AVINDEX_KEYFRAME) != 0 { ticks.append(entry.timestamp) }
        }
        return ticks
    }

    static func segmentName(_ number: Int) -> String { String(format: "seg-%05d.m4s", number) }

    /// RFC 6381 audio token for the master CODECS list, for the audio codecs `isCopyableAudio` accepts.
    private static func audioCodecString(_ par: UnsafeMutablePointer<AVCodecParameters>) -> String? {
        switch par.pointee.codec_id {
        case AV_CODEC_ID_AAC:
            // mp4a.40.<AOT>; AAC-LC (profile FF_PROFILE_AAC_LOW == 1) → AOT 2.
            let aot = par.pointee.profile >= 0 ? Int(par.pointee.profile) + 1 : 2
            return "mp4a.40.\(aot)"
        case AV_CODEC_ID_AC3:  return "ac-3"
        case AV_CODEC_ID_EAC3: return "ec-3"
        case AV_CODEC_ID_ALAC: return "alac"
        case AV_CODEC_ID_FLAC: return "fLaC"
        case AV_CODEC_ID_MP3:  return "mp4a.40.34"
        default: return nil
        }
    }

    /// Run the video stream's first packets through FFmpeg's `extract_extradata` bitstream filter
    /// and install the recovered parameter sets on the stream's codecpar. Returns false if none were
    /// found within a bounded scan.
    private func extractVideoExtradata(input: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int) -> Bool {
        guard let stream = input.pointee.streams[videoIndex], let par = stream.pointee.codecpar,
              let filter = av_bsf_get_by_name("extract_extradata") else { return false }
        var bsfOpt: UnsafeMutablePointer<AVBSFContext>?
        guard av_bsf_alloc(filter, &bsfOpt) >= 0, let bsf = bsfOpt else { return false }
        defer { var b: UnsafeMutablePointer<AVBSFContext>? = bsf; av_bsf_free(&b) }
        guard avcodec_parameters_copy(bsf.pointee.par_in, par) >= 0 else { return false }
        bsf.pointee.time_base_in = stream.pointee.time_base
        guard av_bsf_init(bsf) >= 0 else { return false }

        guard let pkt = av_packet_alloc() else { return false }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        for _ in 0..<200 {                                   // bounded scan of the leading packets
            guard av_read_frame(input, pkt) >= 0 else { return false }
            if Int(pkt.pointee.stream_index) != videoIndex { av_packet_unref(pkt); continue }
            guard av_bsf_send_packet(bsf, pkt) >= 0 else { av_packet_unref(pkt); return false }
            while av_bsf_receive_packet(bsf, pkt) >= 0 {
                var size = 0
                if let data = av_packet_get_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA, &size), size > 0,
                   let buf = av_mallocz(size + Int(AV_INPUT_BUFFER_PADDING_SIZE)) {
                    memcpy(buf, data, size)
                    par.pointee.extradata = buf.assumingMemoryBound(to: UInt8.self)
                    par.pointee.extradata_size = Int32(size)
                    print("[Remux] recovered \(size)b of video extradata")
                    av_packet_unref(pkt)
                    return true
                }
                av_packet_unref(pkt)
            }
        }
        return false
    }

    // MARK: - Stream selection / tagging

    /// Non-empty value of a stream-metadata key ("language", "title"), or nil.
    private static func metadataValue(_ dict: OpaquePointer?, _ key: String) -> String? {
        guard let entry = av_dict_get(dict, key, nil, 0), let value = entry.pointee.value else { return nil }
        let s = String(cString: value)
        return s.isEmpty ? nil : s
    }

    private func isCopyableAudio(_ id: AVCodecID) -> Bool {
        switch id {
        case AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC, AV_CODEC_ID_MP3:
            return true
        default:
            return false
        }
    }

    /// Text-based subtitle codecs the native path can turn into WebVTT (W2) — everything
    /// avcodec decodes to an ASS/text `AVSubtitle`; the rest (PGS, VobSub, DVB, XSUB, ARIB,
    /// EIA-608 …) is bitmap/caption data the native player can't show.
    static func isTextSubtitle(_ id: AVCodecID) -> Bool {
        switch id {
        case AV_CODEC_ID_SUBRIP, AV_CODEC_ID_ASS, AV_CODEC_ID_SSA, AV_CODEC_ID_MOV_TEXT,
             AV_CODEC_ID_WEBVTT, AV_CODEC_ID_TEXT, AV_CODEC_ID_SRT, AV_CODEC_ID_TTML,
             AV_CODEC_ID_MICRODVD, AV_CODEC_ID_SAMI, AV_CODEC_ID_SUBVIEWER, AV_CODEC_ID_SUBVIEWER1,
             AV_CODEC_ID_MPL2, AV_CODEC_ID_HDMV_TEXT_SUBTITLE, AV_CODEC_ID_REALTEXT, AV_CODEC_ID_STL,
             AV_CODEC_ID_VPLAYER, AV_CODEC_ID_JACOSUB, AV_CODEC_ID_PJS:
            return true
        default:
            return false
        }
    }

    /// Sample-entry fourcc for the copied video. HEVC → `hvc1` (or `dvh1` for Dolby Vision Profile 5,
    /// which has no HDR10 base layer); H.264 → `avc1`; otherwise keep the muxer default.
    private func videoOutputTag(_ par: UnsafeMutablePointer<AVCodecParameters>) -> UInt32 {
        switch par.pointee.codec_id {
        case AV_CODEC_ID_HEVC:
            return dolbyProfile(par) == 5 ? fourcc("dvh1") : fourcc("hvc1")
        case AV_CODEC_ID_H264:
            return fourcc("avc1")
        default:
            return 0
        }
    }

    /// Full master-playlist signaling for the video track, per Apple's HLS authoring spec, INCLUDING
    /// `VIDEO-RANGE` — REQUIRED on tvOS 27. (An earlier finding that tvOS 27 rejects VIDEO-RANGE=PQ
    /// was drawn in the confounded EVENT-playlist era and is backwards: device A/B on the fixed VOD
    /// pipeline shows PQ media is REJECTED at media admission (-12927) when the master does NOT
    /// declare it, and ACCEPTED when declared alongside full CODECS + SUPPLEMENTAL-CODECS.)
    private static func videoSignaling(_ par: UnsafeMutablePointer<AVCodecParameters>) -> VideoSignaling {
        let range: String?
        switch par.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084: range = "PQ"
        case AVCOL_TRC_ARIB_STD_B67: range = "HLG"
        default: range = nil
        }
        let dovi = doviRecord(par)

        switch par.pointee.codec_id {
        case AV_CODEC_ID_HEVC:
            if let dovi, dovi.dv_profile == 5 {
                // P5 has no cross-compatible base layer — the DV string IS the codec string.
                return VideoSignaling(codecs: String(format: "dvh1.05.%02d", dovi.dv_level),
                                      supplementalCodecs: nil, videoRange: range)
            }
            let base = hevcCodecString(par)
            if let dovi, dovi.dv_profile == 8 {
                // The compatibility brand must match the base layer or DV silently fails to engage:
                // compat 1 = HDR10/PQ base (P8.1) → db1p; 2 = SDR base (P8.2) → db2g; 4 = HLG (P8.4) → db4h.
                let brand: String
                switch Int(dovi.dv_bl_signal_compatibility_id) {
                case 2: brand = "db2g"
                case 4: brand = "db4h"
                default: brand = "db1p"
                }
                return VideoSignaling(codecs: base,
                                      supplementalCodecs: String(format: "dvh1.08.%02d/%@", dovi.dv_level, brand),
                                      videoRange: range)
            }
            return VideoSignaling(codecs: base, supplementalCodecs: nil, videoRange: range)
        case AV_CODEC_ID_H264:
            return VideoSignaling(codecs: avcCodecString(par), supplementalCodecs: nil, videoRange: range)
        default:
            return VideoSignaling(codecs: "", supplementalCodecs: nil, videoRange: nil)
        }
    }

    /// RFC 6381 HEVC token from the hvcC decoder configuration (ISO 14496-15 Annex E), e.g.
    /// `hvc1.2.4.L153.B0`. Falls back to the bare tag if the extradata isn't hvcC-shaped.
    private static func hevcCodecString(_ par: UnsafeMutablePointer<AVCodecParameters>) -> String {
        let size = Int(par.pointee.extradata_size)
        guard size >= 13, let ed = par.pointee.extradata else { return "hvc1" }
        let b = UnsafeBufferPointer(start: ed, count: size)
        guard b[0] == 1 else { return "hvc1" }                       // hvcC configurationVersion
        let profileSpace = Int((b[1] >> 6) & 0x3)
        let tier = (b[1] >> 5) & 0x1
        let profileIdc = b[1] & 0x1F
        var compat: UInt32 = 0
        for i in 2...5 { compat = (compat << 8) | UInt32(b[i]) }
        var reversed: UInt32 = 0                                     // bit-reversed per Annex E
        for i in 0..<32 where compat & (1 << UInt32(i)) != 0 { reversed |= 1 << UInt32(31 - i) }
        var s = "hvc1.\(["", "A", "B", "C"][profileSpace])\(profileIdc)"
            + ".\(String(reversed, radix: 16, uppercase: true))"
            + ".\(tier == 0 ? "L" : "H")\(b[12])"
        var constraints = Array(b[6...11])
        while constraints.count > 1, constraints.last == 0 { constraints.removeLast() }
        if !(constraints.count == 1 && constraints[0] == 0) {
            for c in constraints { s += "." + String(format: "%02X", c) }
        }
        return s
    }

    /// RFC 6381 AVC token from avcC (profile/constraints/level), e.g. `avc1.640028`.
    private static func avcCodecString(_ par: UnsafeMutablePointer<AVCodecParameters>) -> String {
        let size = Int(par.pointee.extradata_size)
        guard size >= 4, let ed = par.pointee.extradata, ed[0] == 1 else { return "avc1" }
        return String(format: "avc1.%02X%02X%02X", ed[1], ed[2], ed[3])
    }

    private static func doviRecord(_ par: UnsafeMutablePointer<AVCodecParameters>) -> AVDOVIDecoderConfigurationRecord? {
        guard let sd = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              let data = sd.pointee.data else { return nil }
        return data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
    }

    /// Retag the stream's Dolby Vision configuration as single-layer Profile 8.1 (HDR10-compatible
    /// base) — mutated IN PLACE on the input stream's codecpar so every run's `parameters_copy`, the
    /// `videoOutputTag` choice (profile 8 → hvc1) and `videoSignaling` (dvh1.08/db1p supplemental)
    /// all see the post-conversion truth. Level and rpu/bl presence carry over from the source.
    private static func patchDoviConfToP81(_ par: UnsafeMutablePointer<AVCodecParameters>) {
        guard let sd = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              let data = sd.pointee.data,
              sd.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { return }
        data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) {
            $0.pointee.dv_profile = 8
            $0.pointee.el_present_flag = 0
            $0.pointee.dv_bl_signal_compatibility_id = 1
        }
    }

    private func dolbyProfile(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Int? {
        Self.doviRecord(par).map { Int($0.dv_profile) }
    }

    private func fourcc(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        guard b.count == 4 else { return 0 }
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    // MARK: - State plumbing

    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    private func setState(_ s: State) {
        lock.lock(); _state = s; let cb = onStateChange; lock.unlock()
        cb?(s)
    }

    private func fail(_ stage: String) {
        print("[Remux] failed at \(stage) — \(config.url.lastPathComponent)")
        setState(.failed(stage))
    }

    /// Root of the remux segment cache — every session writes into its own UUID subdirectory.
    /// `RemuxCacheJanitor` sweeps orphaned subdirectories at launch.
    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nuvio-remux", isDirectory: true)
    }

    private static func makeSessionDir() -> URL {
        cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

// MARK: - Segment-splitting AVIO sink

/// Custom AVIO sink for the owned segmenter: routes movenc's APPEND-ONLY byte stream (the AVIO context
/// has no seek callback, so movenc takes its streaming paths, exactly as when writing to a pipe) into
/// discrete files. The stream is a sequence of top-level MP4 boxes: `ftyp` + `moov` (the init segment —
/// with `delay_moov` the moov arrives at the FIRST fragment flush, not at write_header, because EAC3's
/// dec3 sample entry needs a parsed frame) followed by `moof`+`mdat` pairs (the fragments). The sink
/// parses top-level box headers until the `moov` completes — everything up to its end is written
/// atomically as `init.mp4` — then switches to raw routing into the current segment window, which
/// `runRemux` rotates at its own fragment-flush boundaries (flushes are box-aligned by construction).
/// Every file is written atomically (`.part` → rename) so the loopback server keys "complete" on the
/// final name and never serves a torn file.
///
/// All methods run synchronously on the remux worker thread (the muxer calls the AVIO callback inline
/// during write_header / av_write_frame on that same thread), so no locking is needed.
private nonisolated final class SegmentWriter {
    private let outputDir: URL
    private var initData = Data()          // accumulates ftyp…moov until the moov box completes
    private var initDone = false
    private var segData = Data()
    private var segName: String?
    private var discarding = false
    /// Seek-anywhere: a repositioned run's FRESH muxer context re-emits ftyp+moov. init.mp4 is already
    /// on disk (and is the moov AVPlayer admitted), so the duplicate is parsed and DISCARDED.
    private let discardInit: Bool
    /// File name of this representation's init segment ("init.mp4" video, "aud-<T>-init.mp4" audio).
    private let initName: String

    init(outputDir: URL, initName: String = "init.mp4", discardInit: Bool = false) {
        self.outputDir = outputDir
        self.initName = initName
        self.discardInit = discardInit
    }

    /// Whether init.mp4 has been written (the moov box has been seen and routed).
    var initFinalized: Bool { initDone }

    /// True when the init segment is complete but no fragment bytes have arrived in the current
    /// window. Detects delay_moov's moov-only first flush (movenc keeps the first fragment's samples
    /// buffered and emits them on the NEXT flush) so the caller can force an extra flush.
    var awaitingFirstFragment: Bool { initDone && segData.isEmpty }

    /// Start accumulating the next segment file. Any current segment buffer is dropped.
    func beginFile(named name: String) {
        segData.removeAll(keepingCapacity: true)
        segName = name
        discarding = false
    }

    /// Route subsequent non-init bytes nowhere (used for the trailer, so any residual bytes movenc
    /// emits after the last fragment can't land in a segment file).
    func beginDiscard() {
        segData.removeAll(keepingCapacity: false)
        segName = nil
        discarding = true
    }

    /// Flush the buffered segment to disk atomically (`.part` then rename within the same directory).
    /// Returns false when the window is EMPTY — a broken invariant for the video representation (the
    /// published playlist promises media in every segment), so the caller must fail the session
    /// rather than ship a 0-byte file. `allowEmpty` (audio renditions): the audio track can end
    /// before the video does (or interleave more than a segment late) — the file is written EMPTY
    /// so the playlist entry is at least served (KNOWN LIMITATION: movenc can't emit a valid
    /// zero-sample fragment, and a silent frame can't be synthesized for every codec; AVPlayer
    /// treats the segment as a load error at that point — expected only for truncated audio tracks).
    @discardableResult
    func finalizeCurrent(allowEmpty: Bool = false) -> Bool {
        guard !discarding, let segName else { return true }
        self.segName = nil
        guard !segData.isEmpty else {
            print("[Remux] segment \(segName) finalized EMPTY — muxer emitted no fragment bytes")
            if allowEmpty { writeAtomic(Data(), name: segName) }
            return false
        }
        writeAtomic(segData, name: segName)
        segData.removeAll(keepingCapacity: true)
        return true
    }

    // MARK: AVIO write callback
    func write(_ buf: UnsafePointer<UInt8>?, count size: Int32) -> Int32 {
        let n = Int(size)
        guard n > 0, let buf else { return size }
        if initDone {
            if !discarding, segName != nil { segData.append(buf, count: n) }
            return size
        }
        initData.append(buf, count: n)
        routeInitIfComplete()
        return size
    }

    /// Scan complete top-level boxes in the init accumulator. Once the `moov` box is complete,
    /// [start, end-of-moov] is the init segment; any residue already received belongs to the first
    /// fragment and moves to the segment buffer.
    private func routeInitIfComplete() {
        var off = 0
        while initData.count - off >= 8 {
            let size = Int(initData[off]) << 24 | Int(initData[off + 1]) << 16
                     | Int(initData[off + 2]) << 8 | Int(initData[off + 3])
            guard size >= 8 else {
                // 64-bit/degenerate box sizes don't occur before moov — bail; init never finalizes,
                // the coordinator's start gate times out, and the session falls back to mpv.
                print("[Remux] unexpected box size \(size) before moov — init routing aborted")
                return
            }
            if initData.count - off < size { return }      // box incomplete — wait for more bytes
            let isMoov = initData[off + 4] == 0x6D && initData[off + 5] == 0x6F
                      && initData[off + 6] == 0x6F && initData[off + 7] == 0x76
            if isMoov {
                let end = off + size
                if !discardInit {
                    writeAtomic(initData.subdata(in: 0..<end), name: initName)
                }
                initDone = true
                if end < initData.count, !discarding, segName != nil {
                    segData.append(initData.subdata(in: end..<initData.count))
                }
                initData.removeAll(keepingCapacity: false)
                return
            }
            off += size
        }
    }

    private func writeAtomic(_ data: Data, name: String) {
        let finalURL = outputDir.appendingPathComponent(name)
        let partURL = finalURL.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partURL)
        do {
            try data.write(to: partURL, options: .atomic)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        } catch {
            print("[Remux] segment write failed: \(name) — \(error.localizedDescription)")
        }
    }
}

private nonisolated func segmentWriterWrite(_ opaque: UnsafeMutableRawPointer?,
                                            _ buf: UnsafePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<SegmentWriter>.fromOpaque(opaque).takeUnretainedValue().write(buf, count: size)
}

// MARK: - Diagnostics

/// Process physical footprint in MB (the number jetsam judges) — logged per produced segment while
/// chasing the 2 GB per-process kill observed on remux-bitrate sources (device, 2026-07-16).
nonisolated func processFootprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
}

// MARK: - Remux interrupts + FFmpeg error tags

/// FFmpeg error codes are negated fourcc tags (FFERRTAG); the C macros don't import into Swift.
private nonisolated func ffErrTag(_ tag: String) -> Int32 {
    let b = Array(tag.utf8)
    return -(Int32(b[0]) | Int32(b[1]) << 8 | Int32(b[2]) << 16 | Int32(b[3]) << 24)
}
/// AVERROR_EOF — genuine end of stream, distinct from read errors and interrupt kicks.
nonisolated let avErrorEOF = ffErrTag("EOF ")
/// AVERROR_EXIT — the interrupt callback aborted a blocking call (a reposition/stop kick).
nonisolated let avErrorExit = ffErrTag("EXIT")

/// Interrupt flags shared with FFmpeg's blocking I/O via `AVIOInterruptCB`. `cancelled` aborts
/// everything (stop); `repositionPending` kicks the worker out of a blocked av_read_frame so a seek
/// is responsive even when the source is stalled — the worker clears it before performing its own
/// av_seek_frame, which runs I/O through the same callback.
nonisolated final class RemuxInterrupts: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _repositionPending = false
    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }
    var repositionPending: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _repositionPending }
        set { lock.lock(); _repositionPending = newValue; lock.unlock() }
    }
    var shouldInterrupt: Bool { cancelled || repositionPending }
}

nonisolated func remuxShouldInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<RemuxInterrupts>.fromOpaque(opaque).takeUnretainedValue().shouldInterrupt ? 1 : 0
}
