import Foundation
import Libavformat
import Libavcodec
import Libavutil

// Phase 1 of the hybrid player: a thin, synchronous FFmpeg (avformat) probe that inspects a stream
// URL *before* playback and reports the facts the router needs to choose an engine — container,
// video codec, Dolby Vision configuration, HDR transfer, audio/subtitle tracks, duration, and
// whether the source is seekable. See docs/tvos-hybrid-player-plan.md.
//
// The FFmpeg C types stay inside this file: `probe(...)` returns a pure-Swift `ProbeResult`, so the
// router (and its tests) never touch libav* headers. The keyframe/Cues index that Phase 2's remux
// needs is intentionally NOT collected here yet.

/// HDR transfer characteristic inferred from the video stream's color transfer function.
nonisolated enum HDRFormat: String, Sendable {
    case sdr, hdr10, hlg, other
}

/// Dolby Vision configuration record (from the HEVC `dvvC`/`dvcC` box), when present.
nonisolated struct DolbyVisionInfo: Equatable, Sendable {
    var profile: Int          // 5, 7, 8, ...
    var level: Int
    var blPresent: Bool       // base layer
    var elPresent: Bool       // enhancement layer (dual-layer P7)
    var rpuPresent: Bool      // reference processing unit (dynamic metadata)
    var compatId: Int         // dv_bl_signal_compatibility_id (1 = HDR10-compatible P8.1, etc.)
    /// Profile 7 only: MEL/FEL flavor classified by parsing the first RPU out of the initial video
    /// packets (Phase 5 — decides native-vs-mpv routing and what the 8.1 conversion costs). nil for
    /// other profiles (no scan performed).
    var elKind: DVELKind? = nil
}

nonisolated struct AudioStreamInfo: Sendable {
    var index: Int
    var codec: String         // canonical FFmpeg name: "aac", "ac3", "eac3", "truehd", "dts", ...
    var channels: Int
    var language: String?
}

nonisolated struct SubtitleStreamInfo: Sendable {
    var index: Int
    var codec: String         // "subrip", "ass", "hdmv_pgs_subtitle", "dvd_subtitle", ...
    var isBitmap: Bool         // PGS/VobSub/DVB → must burn-in or route to mpv
    var language: String?
}

/// Everything the router needs, as plain Swift values (no libav* types leak out).
nonisolated struct ProbeResult: Sendable {
    var container: String          // avformat demuxer name, e.g. "matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2"
    var videoCodec: String         // "hevc", "h264", "av1", "vp9", ... ("" if no video)
    var videoProfile: Int32        // raw AVCodecParameters.profile (FF_PROFILE_*), -99 if unknown
    var hdr: HDRFormat
    var dolbyVision: DolbyVisionInfo?
    var audio: [AudioStreamInfo]
    var subtitles: [SubtitleStreamInfo]
    var durationSec: Double
    var seekable: Bool
    /// Real video tracks in the container (attached-picture/cover-art streams excluded). A Profile 7
    /// source with a SECOND video stream is the two-track BL+EL layout — the RPUs live in the EL
    /// track, which the remux never reads, so those files stay on mpv.
    var videoStreamCount: Int = 0
}

nonisolated enum MediaProbe {
    /// Serialize request headers into FFmpeg's `headers` AVOption form for the http protocol:
    /// CRLF-terminated `Key: Value` lines. Sorted for determinism. Shared with `RemuxSession`
    /// (both open the remote source through avformat and need the same addon headers).
    static func ffmpegHeaderBlock(_ headers: [String: String]) -> String {
        headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)\r\n" }
            .joined()
    }

    /// Open `url` with avformat and return a `ProbeResult`, or nil on failure/timeout. Blocking
    /// (network I/O) — call off the main thread. A deadline-based interrupt callback guarantees the
    /// call cannot hang past `timeoutSec`.
    static func probe(url: URL, timeoutSec: Double, requestHeaders: [String: String] = [:]) -> ProbeResult? {
        MediaProbeNetwork.ensureInit()

        guard let ctx = avformat_alloc_context() else { return nil }

        // Deadline interrupt: FFmpeg polls this during blocking I/O; returning 1 aborts the operation.
        let deadline = ProbeDeadline(timeoutSec: timeoutSec)
        let opaque = Unmanaged.passRetained(deadline).toOpaque()
        defer { Unmanaged<ProbeDeadline>.fromOpaque(opaque).release() }
        ctx.pointee.interrupt_callback = AVIOInterruptCB(callback: mediaProbeShouldInterrupt, opaque: opaque)

        // Protocol-level open/read timeout (microseconds) for demuxers/protocols that honor it.
        var opts: OpaquePointer?
        av_dict_set(&opts, "timeout", String(Int(timeoutSec * 1_000_000)), 0)
        // Addon-declared stream headers (behaviorHints.proxyHeaders.request, pre-sanitized): a
        // header-gated CDN 403s a bare probe, which would silently route the stream to mpv even
        // when the native path could play it. Ignored by non-HTTP protocols.
        if !requestHeaders.isEmpty {
            av_dict_set(&opts, "headers", ffmpegHeaderBlock(requestHeaders), 0)
        }
        defer { av_dict_free(&opts) }

        var fmt: UnsafeMutablePointer<AVFormatContext>? = ctx
        // On failure avformat_open_input frees and nils the context it was given — no manual free.
        guard avformat_open_input(&fmt, url.absoluteString, nil, &opts) == 0, let fmt else { return nil }
        defer { var f: UnsafeMutablePointer<AVFormatContext>? = fmt; avformat_close_input(&f) }

        guard avformat_find_stream_info(fmt, nil) >= 0 else { return nil }

        var result = ProbeResult(
            container: fmt.pointee.iformat.flatMap { $0.pointee.name }.map { String(cString: $0) } ?? "",
            videoCodec: "",
            videoProfile: -99,
            hdr: .sdr,
            dolbyVision: nil,
            audio: [],
            subtitles: [],
            durationSec: fmt.pointee.duration > 0 ? Double(fmt.pointee.duration) / 1_000_000.0 : 0,
            seekable: fmt.pointee.pb.map { ($0.pointee.seekable & AVIO_SEEKABLE_NORMAL) != 0 } ?? false
        )

        var videoStreamIndex = -1
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let stream = fmt.pointee.streams[i], let parPtr = stream.pointee.codecpar else { continue }
            let par = parPtr.pointee
            let lang = dictValue(stream.pointee.metadata, "language")

            switch par.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                // Attached pictures (cover art muxed as an mjpeg/png "video" track) aren't playback
                // streams — skip them entirely so they can't skew the two-track P7 detection.
                let attachedPic: Int32 = 1 << 10                 // AV_DISPOSITION_ATTACHED_PIC
                guard stream.pointee.disposition & attachedPic == 0 else { break }
                result.videoStreamCount += 1
                guard result.videoCodec.isEmpty else { break }   // first video stream only
                videoStreamIndex = i
                result.videoCodec = codecName(par.codec_id)
                result.videoProfile = par.profile
                result.hdr = hdrFormat(par.color_trc)
                result.dolbyVision = dolbyVision(parPtr)
            case AVMEDIA_TYPE_AUDIO:
                result.audio.append(AudioStreamInfo(
                    index: i,
                    codec: codecName(par.codec_id),
                    channels: Int(par.ch_layout.nb_channels),
                    language: lang
                ))
            case AVMEDIA_TYPE_SUBTITLE:
                let props = avcodec_descriptor_get(par.codec_id)?.pointee.props ?? 0
                result.subtitles.append(SubtitleStreamInfo(
                    index: i,
                    codec: codecName(par.codec_id),
                    isBitmap: (props & AV_CODEC_PROP_BITMAP_SUB) != 0,
                    language: lang
                ))
            default:
                break
            }
        }

        // Profile 7 needs one more fact the container can't provide: the MEL/FEL flavor, read from
        // the first RPU NAL in the bitstream (Phase 5 routing + the FEL fidelity sub-setting). The
        // scan is bounded (packet counts + the same deadline interrupt) and only runs for P7 files;
        // find_stream_info has already buffered the initial packets, so it rarely touches the network.
        if let dv = result.dolbyVision, dv.profile == 7, videoStreamIndex >= 0 {
            result.dolbyVision?.elKind = scanP7ELKind(fmt, videoStreamIndex: videoStreamIndex, deadline: deadline)
        }
        return result
    }

    /// Read initial packets and classify the first RPU found on the video stream. `.missing` when the
    /// scan exhausts its budget without seeing one (two-track P7 keeps its RPUs in the EL track),
    /// `.unsupported` when the walker can't run (extradata not hvcC) or libdovi can't parse it.
    private static func scanP7ELKind(_ fmt: UnsafeMutablePointer<AVFormatContext>,
                                     videoStreamIndex: Int, deadline: ProbeDeadline) -> DVELKind {
        guard let par = fmt.pointee.streams[videoStreamIndex]?.pointee.codecpar,
              let nalLengthSize = DoviRpuConverter.hvccNalLengthSize(par),
              let pkt = av_packet_alloc() else { return .unsupported }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        var reads = 0, videoPackets = 0
        while reads < 400, videoPackets < 120, !deadline.expired, av_read_frame(fmt, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            reads += 1
            guard Int(pkt.pointee.stream_index) == videoStreamIndex, let data = pkt.pointee.data else { continue }
            videoPackets += 1
            if let kind = DoviRpuConverter.classifyFirstRpu(packetData: data,
                                                            size: Int(pkt.pointee.size),
                                                            nalLengthSize: nalLengthSize) {
                return kind
            }
        }
        return .missing
    }

    // MARK: - Extraction helpers

    private static func codecName(_ id: AVCodecID) -> String {
        guard let cName = avcodec_get_name(id) else { return "" }
        return String(cString: cName)
    }

    private static func hdrFormat(_ trc: AVColorTransferCharacteristic) -> HDRFormat {
        switch trc {
        case AVCOL_TRC_SMPTE2084: return .hdr10
        case AVCOL_TRC_ARIB_STD_B67: return .hlg
        case AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12: return .other
        default: return .sdr
        }
    }

    private static func dolbyVision(_ parPtr: UnsafeMutablePointer<AVCodecParameters>) -> DolbyVisionInfo? {
        let par = parPtr.pointee
        guard let sd = av_packet_side_data_get(par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              let data = sd.pointee.data,
              sd.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { return nil }
        let rec = data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        return DolbyVisionInfo(
            profile: Int(rec.dv_profile),
            level: Int(rec.dv_level),
            blPresent: rec.bl_present_flag != 0,
            elPresent: rec.el_present_flag != 0,
            rpuPresent: rec.rpu_present_flag != 0,
            compatId: Int(rec.dv_bl_signal_compatibility_id)
        )
    }

    private static func dictValue(_ dict: OpaquePointer?, _ key: String) -> String? {
        guard let entry = av_dict_get(dict, key, nil, 0), let value = entry.pointee.value else { return nil }
        let s = String(cString: value)
        return s.isEmpty ? nil : s
    }
}

/// Absolute-time deadline shared with FFmpeg's interrupt callback (checked during blocking I/O).
private nonisolated final class ProbeDeadline: Sendable {
    private let deadline: TimeInterval
    init(timeoutSec: Double) { deadline = ProcessInfo.processInfo.systemUptime + timeoutSec }
    var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline }
}

/// C-compatible interrupt callback: returns 1 (abort) once the deadline passes.
private nonisolated func mediaProbeShouldInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<ProbeDeadline>.fromOpaque(opaque).takeUnretainedValue().expired ? 1 : 0
}

/// One-time `avformat_network_init()` so avformat can open http(s) sources.
private nonisolated enum MediaProbeNetwork {
    private static let initialized: Void = {
        avformat_network_init()
        return ()
    }()
    static func ensureInit() { _ = initialized }
}
