import Foundation

// The pure routing decision of the hybrid player. Given a `ProbeResult` (or nil), the viewer's Dolby
// Vision setting and the Player preference (`PlayerEnginePreference`), decide which engine should
// render the stream. Deliberately dependency-free (no libav*, no SwiftUI) so it is trivially
// testable — see `selfCheckFailures()` below and NuvioTVTests/PlayerEngineRouterTests.
// See docs/player-spec.md, "Engine routing", for the rules and where each one comes from.
//
// NATIVE FIRST. The native engine (AVPlayer) is the only exact copy of the system player there is,
// so the router sends it everything AVPlayer can play, and mpv only what it cannot:
//  - formats AVPlayer has no decoder for (VP9, MPEG-2, 10-bit H.264, HEVC 4:2:2 / 12-bit / 8K ...);
//  - containers the on-device remux cannot index (AVI, MPEG-TS, ...) and sources that cannot seek;
//  - files with no audio track that can be copied or transcoded;
//  - what the viewer asked for (Player: Prefer mpv, a Dolby Vision mode, the FEL fidelity choice);
//  - files whose subtitles in the viewer's language exist only as images (decided by the caller,
//    `PlayerScreen`, which knows the language plan and the addon subtitles).
// Anything ambiguous that AVPlayer might still play is tried natively when the viewer prefers it, and
// a native engine that fails hands the file to mpv (`NativePlaybackCoordinator`).

nonisolated enum PlaybackEngine: String, Sendable {
    case native   // AVPlayer: fed by the on-device remux (true Dolby Vision, hardware decode) or opening an HLS stream itself
    case mpv      // libmpv, the universal fallback
}

/// How the native engine gets the stream to AVPlayer.
nonisolated enum NativeDelivery: String, Sendable {
    /// The on-device remux turns the file (MKV, MP4, MOV, WebM) into a local HLS stream.
    case remux
    /// The stream already is HLS (an addon's playlist, a Jellyfin / Emby transcode, live TV):
    /// AVPlayer opens it itself, with no remux and no local server.
    case directHLS
}

/// What the remux does with the Dolby Vision data of the video track.
nonisolated enum DolbyVisionHandling: String, Sendable {
    /// Dolby Vision stays: Profile 5 and 8 as they are, Profile 7 converted to 8.1.
    case passthrough
    /// The Dolby Vision data is dropped and the base layer plays as the plain HDR10 / HLG / SDR
    /// stream it is (`RemuxSession.Config.dolbyVisionHandling`).
    case stripToBase
}

nonisolated struct EngineDecision: Equatable, Sendable {
    let engine: PlaybackEngine
    let reason: String
    /// The probed Dolby Vision profile, whichever engine was chosen (nil: no DV, or no probe).
    /// PLY-A9: a Profile 5 file that ends up on mpv — routed there, or after a native fallback —
    /// needs libplacebo's reshaping (`MPVTVPlayerViewController.forceDVReshape`, contract C1).
    var dvProfile: Int? = nil
    /// Native only: remux or direct HLS.
    var delivery: NativeDelivery = .remux
    /// Native only: what the remux does with the Dolby Vision data.
    var dvHandling: DolbyVisionHandling = .passthrough

    /// mpv must render this file with Dolby Vision reshaping (Profile 5 has no HDR10/SDR base layer).
    var needsDVReshapeOnMPV: Bool { dvProfile == 5 }

    /// Short label for the Stream Info overlay, e.g. "Native · DV P8.1" or "mpv · audio truehd".
    var displayNote: String {
        "\(engine == .native ? String(localized: "Native") : "mpv") \u{00B7} \(reason)"
    }
}

/// How the native engine plays one stream: the router's decision, as the coordinator needs it.
nonisolated struct NativePlaybackPlan: Equatable, Sendable {
    var delivery: NativeDelivery = .remux
    var dolbyVision: DolbyVisionHandling = .passthrough
}

/// The routing inputs that are not facts about the stream.
nonisolated struct RoutingOptions: Equatable, Sendable {
    /// Settings > Playback > Advanced > Player.
    var enginePreference: PlayerEnginePreference = .automatic
    /// This Apple TV decodes AV1 in hardware (the 4th generation, A19, and later; the 2nd and 3rd
    /// generation have no AV1 decoder and VideoToolbox has no software one on tvOS).
    var hardwareAV1 = false
}

nonisolated enum PlayerEngineRouter {
    /// Decide the engine for a probed stream. `nativeDVEnabled` is the legacy kill switch behind the
    /// Dolby Vision picker's Off; `dvP7FelToMpv` is its FEL-fidelity mode (send Profile 7 FEL files to
    /// mpv instead of discarding their enhancement layer in the 8.1 conversion). `stripDolbyVision` is
    /// the "HDR10 Only" Dolby Vision mode: Dolby Vision files play as their HDR10 base layer (Profile
    /// 5 has none and is left to the usual rules). All three come from `DolbyVisionMode`.
    static func route(probe: ProbeResult?, nativeDVEnabled: Bool, dvP7FelToMpv: Bool = false,
                      stripDolbyVision: Bool = false, options: RoutingOptions = RoutingOptions()) -> EngineDecision {
        var decision = decide(probe: probe, nativeDVEnabled: nativeDVEnabled, dvP7FelToMpv: dvP7FelToMpv,
                              stripDolbyVision: stripDolbyVision, options: options)
        decision.dvProfile = probe?.dolbyVision?.profile
        return decision
    }

    /// A stream whose URL names an HLS playlist is routed without a probe (`isHLSURL`): AVPlayer
    /// reads CODECS from the playlist itself, and a stream it rejects falls back to mpv.
    static func routeHLS(nativeDVEnabled: Bool, options: RoutingOptions = RoutingOptions()) -> EngineDecision {
        guard nativeDVEnabled else { return EngineDecision(engine: .mpv, reason: "native engine off") }
        guard options.enginePreference != .preferMpv else {
            return EngineDecision(engine: .mpv, reason: "player preference")
        }
        return EngineDecision(engine: .native, reason: "HLS direct", delivery: .directHLS)
    }

    /// The native player could play this stream if the viewer's routing preferences were set aside
    /// (the Player choice and the Dolby Vision modes): what the "Player Engine" menu may offer, and
    /// whether a failed native attempt had anything left to fall back from. A probe that found nothing
    /// proves nothing, so it counts as possible.
    static func nativeCouldPlay(probe: ProbeResult?, options: RoutingOptions = RoutingOptions()) -> Bool {
        var relaxed = options
        relaxed.enginePreference = .preferNative
        return route(probe: probe, nativeDVEnabled: true, options: relaxed).engine == .native
    }

    /// The URL names an HLS playlist (`.m3u8`): an addon's playlist, a Jellyfin / Emby transcode
    /// (`/videos/<id>/master.m3u8`), a live channel.
    static func isHLSURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
    }

    private static func decide(probe: ProbeResult?, nativeDVEnabled: Bool, dvP7FelToMpv: Bool,
                               stripDolbyVision: Bool, options: RoutingOptions) -> EngineDecision {
        func mpv(_ reason: String) -> EngineDecision { EngineDecision(engine: .mpv, reason: reason) }
        guard nativeDVEnabled else { return mpv("native engine off") }
        let preference = options.enginePreference
        guard let p = probe else {
            // Nothing is known about the stream. Prefer Native still tries it natively (the remux
            // opens the source itself, and a failure there falls back to mpv); otherwise mpv.
            if preference == .preferNative {
                return EngineDecision(engine: .native, reason: "probe unavailable, trying native")
            }
            return mpv("probe unavailable")
        }
        // A stream that already is HLS needs no remux: AVPlayer opens it.
        if isHLSContainer(p.container) {
            return decideHLS(p, stripDolbyVision: stripDolbyVision, options: options)
        }
        guard p.seekable else { return mpv("source not seekable") }
        guard isNativeContainer(p.container) else { return mpv("container \(p.container)") }
        guard isNativeVideoCodec(p, options: options) else {
            return mpv(p.videoCodec.isEmpty ? "no video stream" : "video \(p.videoCodec)")
        }
        // H.264 High 10 / 4:2:2 / 4:4:4 (10-bit anime encodes, mostly): no hardware decoder on Apple
        // TV and none in AVPlayer — the item fails after the remux spun up and playback restarts on
        // mpv. Straight to mpv instead.
        if p.videoCodec == "h264", isUnsupportedH264Profile(p.videoProfile) {
            return mpv("video h264 profile \(p.videoProfile)")
        }
        // HEVC that is not Main / Main 10 at a size the Apple TV decodes (4:2:2, 4:4:4, 12-bit, 8K):
        // the remux used to start anyway and the item never became ready (45 s of black, then mpv).
        if p.videoCodec == "hevc", let why = unsupportedHEVCReason(p) {
            return mpv("video hevc \(why)")
        }
        // Interlaced video (1080i broadcast captures, DVD sources): the HLS authoring spec wants it
        // deinterlaced before it reaches AVPlayer and nothing says tvOS does it, so mpv, whose
        // deinterlacing is known. Prefer Native tries AVPlayer anyway.
        if isInterlaced(p), preference != .preferNative {
            return mpv("interlaced video")
        }

        // Dolby Vision. Profile 5 and single-layer Profile 8 play natively on tvOS 17.2+. Dual-layer
        // Profile 7 converts to 8.1 during the remux (EL NALs dropped, RPUs rewritten via libdovi) —
        // when it is one track whose RPUs the probe could parse. Everything else that carries Dolby
        // Vision (HDR10 Only, two-track Profile 7, Profile 7 with no convertible RPU, Profile 4 / 9 /
        // 10 ...) plays natively as its base layer alone — the plain HDR10 / HLG / SDR stream mpv
        // would have shown — with the Dolby Vision data stripped by the remux.
        var dvHandling = DolbyVisionHandling.passthrough
        if let dv = p.dolbyVision {
            if stripDolbyVision, dv.profile != 5 {
                dvHandling = .stripToBase
            } else {
                switch dv.profile {
                case 5, 8:
                    break
                case 7:
                    if p.videoStreamCount == 1 {
                        switch dv.elKind {
                        case .mel:
                            break
                        case .fel:
                            if dvP7FelToMpv { return mpv("DV P7 FEL (fidelity preference)") }
                        case .missing, .unsupported, nil:
                            dvHandling = .stripToBase
                        }
                    } else {
                        dvHandling = .stripToBase
                    }
                default:
                    dvHandling = .stripToBase
                }
            }
        }

        // At least one audio track must be AVPlayer-compatible (stream-copied) or decodable by
        // libavcodec (the remux transcodes it to AAC: TrueHD, DTS, Opus, Vorbis, PCM, MP2, MP3 ...).
        // Video-only files are fine.
        let hasCompatibleAudio = p.audio.isEmpty
            || p.audio.contains { isNativeAudio($0.codec) || isTranscodableAudio($0) }
        guard hasCompatibleAudio else {
            return mpv("audio \(p.audio.first?.codec ?? "none")")
        }

        // Prefer mpv: only a file that really plays as Dolby Vision keeps the native player.
        if preference == .preferMpv, !(p.dolbyVision != nil && dvHandling == .passthrough) {
            return mpv("player preference")
        }
        return EngineDecision(engine: .native, reason: nativeReason(p, dvHandling: dvHandling),
                              dvHandling: dvHandling)
    }

    /// An HLS stream the probe read (an extension-less playlist URL): the same video and audio limits as
    /// the remux, minus everything about the container, which AVPlayer reads itself.
    private static func decideHLS(_ p: ProbeResult, stripDolbyVision: Bool, options: RoutingOptions) -> EngineDecision {
        func mpv(_ reason: String) -> EngineDecision { EngineDecision(engine: .mpv, reason: reason) }
        if options.enginePreference == .preferMpv { return mpv("player preference") }
        guard isNativeVideoCodec(p, options: options) else {
            return mpv(p.videoCodec.isEmpty ? "no video stream" : "video \(p.videoCodec) in HLS")
        }
        if p.videoCodec == "h264", isUnsupportedH264Profile(p.videoProfile) {
            return mpv("video h264 profile \(p.videoProfile)")
        }
        if p.videoCodec == "hevc", let why = unsupportedHEVCReason(p) {
            return mpv("video hevc \(why)")
        }
        // The playlist cannot be rewritten the way the remux rewrites a file: an HLS stream that carries
        // Dolby Vision plays as it is, and "HDR10 Only" asks mpv for it instead.
        if stripDolbyVision, let dv = p.dolbyVision, dv.profile != 5 {
            return mpv("DV P\(dv.profile) \u{2192} HDR10 (preference)")
        }
        let hasCompatibleAudio = p.audio.isEmpty || p.audio.contains { isHLSAudio($0.codec) }
        guard hasCompatibleAudio else {
            return mpv("audio \(p.audio.first?.codec ?? "none") in HLS")
        }
        return EngineDecision(engine: .native, reason: "HLS direct", delivery: .directHLS)
    }

    // MARK: - Criteria

    /// avformat reports comma-joined demuxer names (e.g. "matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2").
    private static func isNativeContainer(_ container: String) -> Bool {
        let c = container.lowercased()
        return c.contains("matroska") || c.contains("webm") || c.contains("mp4") || c.contains("mov")
    }

    /// avformat's HLS demuxer ("hls").
    private static func isHLSContainer(_ container: String) -> Bool {
        container.lowercased().split(separator: ",").contains { $0 == "hls" || $0 == "applehttp" }
    }

    /// Video AVPlayer can decode in hardware: H.264 and HEVC, and AV1 where the Apple TV has the decoder.
    private static func isNativeVideoCodec(_ p: ProbeResult, options: RoutingOptions) -> Bool {
        p.videoCodec == "hevc" || p.videoCodec == "h264" || (p.videoCodec == "av1" && options.hardwareAV1)
    }

    /// Audio codecs AVPlayer can play directly (the remux stream-copies these). MP3 is not one: it is
    /// decoded and re-encoded like the other codecs below (`RemuxSession.isCopyableAudio`).
    private static func isNativeAudio(_ codec: String) -> Bool {
        switch codec {
        case "aac", "ac3", "eac3", "flac", "alac": return true
        default: return false
        }
    }

    /// Audio the remux transcodes to AAC (`AudioTranscoder.isTranscodable`): whatever libavcodec can
    /// decode. The probe asks libavcodec (`AudioStreamInfo.decodable`); a canned probe is judged by the
    /// codecs that path was built for. Canonical descriptor names as MediaProbe reports them: FFmpeg
    /// calls DTS (incl. DTS-HD, decoded via its core/extensions) "dts".
    private static func isTranscodableAudio(_ audio: AudioStreamInfo) -> Bool {
        if let decodable = audio.decodable { return decodable }
        switch audio.codec {
        case "truehd", "dts", "opus", "vorbis", "mp3", "mp2": return true
        default: return audio.codec.hasPrefix("pcm_")
        }
    }

    /// Audio codecs AVPlayer takes inside an HLS stream.
    private static func isHLSAudio(_ codec: String) -> Bool {
        switch codec {
        case "aac", "ac3", "eac3", "mp3", "flac", "alac": return true
        default: return false
        }
    }

    /// FF_PROFILE_H264_* values (the intra flag, 2048, masked off) AVPlayer cannot decode: High 10,
    /// High 4:2:2, High 4:4:4 (and its predictive form), CAVLC 4:4:4. Unknown (-99) passes.
    private static func isUnsupportedH264Profile(_ profile: Int32) -> Bool {
        guard profile >= 0 else { return false }
        switch profile & ~2048 {
        case 110, 122, 144, 244, 44: return true
        default: return false
        }
    }

    /// The largest picture, in luma samples, the Apple TV's HEVC decoder is asked for: 4096 x 2304 (a
    /// level 5.1 picture is 8 912 896 samples at most; this leaves room for DCI 4K and for portrait 4K).
    static let maxHEVCPictureSamples = 4096 * 2304

    /// Why AVPlayer on Apple TV cannot decode this HEVC, or nil. Only Main (FF_PROFILE_HEVC_MAIN 1) and
    /// Main 10 (2) are decoded: RExt (4) is 4:2:2, 4:4:4 and 12-bit, SCC (9) screen content, and
    /// profile 3 a still picture. Unknown (-99, or 0) passes, as do sizes and levels the probe did not
    /// read. Level 6 and up is 8K and beyond the A15; levels 5.2 and below are left to AVPlayer — a
    /// declaration it does not accept fails the item at once, which hands the file to mpv.
    static func unsupportedHEVCReason(_ p: ProbeResult) -> String? {
        if p.videoProfile > 0, p.videoProfile != 1, p.videoProfile != 2 {
            return "profile \(p.videoProfile)"
        }
        if p.videoBitDepth > 10 { return "\(p.videoBitDepth)-bit" }
        let samples = Int(p.videoWidth) * Int(p.videoHeight)
        if samples > maxHEVCPictureSamples { return "\(p.videoWidth)x\(p.videoHeight)" }
        if p.videoLevel >= 180 { return "level \(Double(p.videoLevel) / 30)" }
        return nil
    }

    /// AVFieldOrder 2...5 (TT, BB, TB, BT): the stream is interlaced. 0 (unknown) and 1 (progressive) are not.
    static func isInterlaced(_ p: ProbeResult) -> Bool {
        (2...5).contains(p.videoFieldOrder)
    }

    private static func nativeReason(_ p: ProbeResult, dvHandling: DolbyVisionHandling) -> String {
        if let dv = p.dolbyVision {
            if dvHandling == .stripToBase {
                return "DV P\(dv.profile) \u{2192} \(baseLayerName(p.hdr))"
            }
            if dv.profile == 7 {
                return "DV P7 \(dv.elKind == .fel ? "FEL" : "MEL") \u{2192} 8.1"
            }
            // compatId 1 == HDR10-compatible base layer, i.e. Profile 8.1.
            return dv.profile == 8 && dv.compatId == 1 ? "DV P8.1" : "DV P\(dv.profile)"
        }
        return baseLayerName(p.hdr)
    }

    private static func baseLayerName(_ hdr: HDRFormat) -> String {
        switch hdr {
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .other: return "HDR"
        case .sdr: return "SDR"
        }
    }
}

#if DEBUG
extension PlayerEngineRouter {
    /// Router assertions with canned probe results — stands in for a unit-test target (the same
    /// cases are in NuvioTVTests/PlayerEngineRouterTests). Returns human-readable failures; run once
    /// at first playback (see PlayerScreen).
    static func selfCheckFailures() -> [String] {
        var fails: [String] = []
        func expect(_ actual: PlaybackEngine, _ expected: PlaybackEngine, _ msg: String) {
            if actual != expected { fails.append("router self-check: \(msg) (got \(actual.rawValue))") }
        }
        func sample(video: String = "hevc", dv: DolbyVisionInfo? = nil, hdr: HDRFormat = .sdr,
                    audio: [String] = ["eac3"], seekable: Bool = true,
                    container: String = "matroska,webm", videoStreams: Int = 1,
                    profile: Int32 = 0, fieldOrder: Int32 = 0, bitDepth: Int32 = 0,
                    width: Int32 = 0, height: Int32 = 0, level: Int32 = -99) -> ProbeResult {
            ProbeResult(
                container: container, videoCodec: video, videoProfile: profile, hdr: hdr, dolbyVision: dv,
                audio: audio.enumerated().map { AudioStreamInfo(index: $0.offset, codec: $0.element, channels: 6, language: "eng") },
                subtitles: [], durationSec: 3600, seekable: seekable, videoStreamCount: videoStreams,
                videoWidth: width, videoHeight: height, videoLevel: level, videoBitDepth: bitDepth,
                videoFieldOrder: fieldOrder
            )
        }
        let p5 = DolbyVisionInfo(profile: 5, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 0)
        let p81 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 1)
        let p9 = DolbyVisionInfo(profile: 9, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 2)
        func p7(_ kind: DVELKind?) -> DolbyVisionInfo {
            DolbyVisionInfo(profile: 7, level: 6, blPresent: true, elPresent: true, rpuPresent: true,
                            compatId: 0, elKind: kind)
        }

        expect(route(probe: sample(dv: p5), nativeDVEnabled: true).engine, .native, "DV P5 MKV → native")
        expect(route(probe: sample(dv: p81), nativeDVEnabled: true).engine, .native, "DV P8.1 MKV → native")
        expect(route(probe: sample(dv: p7(.mel)), nativeDVEnabled: true).engine, .native, "DV P7 MEL → native (8.1 conversion)")
        expect(route(probe: sample(dv: p7(.fel)), nativeDVEnabled: true).engine, .native, "DV P7 FEL → native by default")
        expect(route(probe: sample(dv: p7(.fel)), nativeDVEnabled: true, dvP7FelToMpv: true).engine, .mpv, "DV P7 FEL + fidelity pref → mpv")
        expect(route(probe: sample(dv: p7(.mel)), nativeDVEnabled: true, dvP7FelToMpv: true).engine, .native, "DV P7 MEL unaffected by FEL pref")
        // "HDR10 Only" and the Dolby Vision files the 8.1 conversion cannot take now play natively as
        // their base layer, stripped.
        let stripped = route(probe: sample(dv: p81), nativeDVEnabled: true, stripDolbyVision: true)
        expect(stripped.engine, .native, "DV P8.1 + HDR10 Only → native, stripped")
        if stripped.dvHandling != .stripToBase { fails.append("router self-check: DV P8.1 + HDR10 Only strips the DV data") }
        expect(route(probe: sample(dv: p7(.mel)), nativeDVEnabled: true, stripDolbyVision: true).engine, .native, "DV P7 MEL + HDR10 Only → native, stripped")
        expect(route(probe: sample(dv: p5), nativeDVEnabled: true, stripDolbyVision: true).engine, .native, "DV P5 keeps Dolby Vision under HDR10 Only")
        if route(probe: sample(dv: p5), nativeDVEnabled: true, stripDolbyVision: true).dvHandling != .passthrough {
            fails.append("router self-check: DV P5 is never stripped")
        }
        expect(route(probe: sample(hdr: .hdr10), nativeDVEnabled: true, stripDolbyVision: true).engine, .native, "plain HDR10 unaffected by HDR10 Only")
        let twoTrack = route(probe: sample(dv: p7(.mel), videoStreams: 2), nativeDVEnabled: true)
        expect(twoTrack.engine, .native, "DV P7 two-track → native, base layer")
        if twoTrack.dvHandling != .stripToBase { fails.append("router self-check: DV P7 two-track strips the DV data") }
        expect(route(probe: sample(dv: p7(.missing)), nativeDVEnabled: true).engine, .native, "DV P7 without RPUs → native, base layer")
        expect(route(probe: sample(dv: p7(.unsupported)), nativeDVEnabled: true).engine, .native, "DV P7 unparseable RPU → native, base layer")
        expect(route(probe: sample(dv: p7(nil)), nativeDVEnabled: true).engine, .native, "DV P7 unclassified → native, base layer")
        expect(route(probe: sample(video: "h264", dv: p9, hdr: .sdr), nativeDVEnabled: true).engine, .native, "DV P9 (AVC, SDR base) → native as SDR")
        expect(route(probe: sample(hdr: .hdr10), nativeDVEnabled: true).engine, .native, "HDR10 HEVC → native")
        expect(route(probe: sample(video: "h264"), nativeDVEnabled: true).engine, .native, "H.264 → native")
        expect(route(probe: sample(video: "av1"), nativeDVEnabled: true).engine, .mpv, "AV1 → mpv without a hardware decoder")
        expect(route(probe: sample(video: "av1"), nativeDVEnabled: true, options: RoutingOptions(hardwareAV1: true)).engine, .native, "AV1 → native with a hardware decoder")
        expect(route(probe: sample(video: "vp9", container: "matroska,webm"), nativeDVEnabled: true).engine, .mpv, "VP9 → mpv")
        expect(route(probe: sample(audio: ["truehd"]), nativeDVEnabled: true).engine, .native, "TrueHD-only → native (transcode)")
        expect(route(probe: sample(audio: ["dts"]), nativeDVEnabled: true).engine, .native, "DTS-only → native (transcode)")
        expect(route(probe: sample(audio: ["opus"]), nativeDVEnabled: true).engine, .native, "Opus-only → native (transcode)")
        expect(route(probe: sample(audio: ["vorbis"]), nativeDVEnabled: true).engine, .native, "Vorbis-only → native (transcode)")
        expect(route(probe: sample(audio: ["pcm_s16le"]), nativeDVEnabled: true).engine, .native, "PCM-only → native (transcode)")
        expect(route(probe: sample(audio: ["mp2"]), nativeDVEnabled: true).engine, .native, "MP2-only → native (transcode)")
        expect(route(probe: sample(audio: ["mp3"]), nativeDVEnabled: true).engine, .native, "MP3-only → native (transcode)")
        expect(route(probe: sample(audio: ["wmav2"]), nativeDVEnabled: true).engine, .mpv, "audio nobody asked libavcodec about → mpv")
        expect(route(probe: sample(video: "h264", profile: 100), nativeDVEnabled: true).engine, .native, "H.264 High → native")
        expect(route(probe: sample(video: "h264", profile: 110), nativeDVEnabled: true).engine, .mpv, "H.264 High 10 → mpv")
        expect(route(probe: sample(video: "h264", profile: 244), nativeDVEnabled: true).engine, .mpv, "H.264 High 4:4:4 → mpv")
        expect(route(probe: sample(video: "h264", profile: -99), nativeDVEnabled: true).engine, .native, "H.264 unknown profile → native")
        // HEVC the Apple TV cannot decode.
        expect(route(probe: sample(profile: 2, bitDepth: 10, width: 3840, height: 2160, level: 153), nativeDVEnabled: true).engine, .native, "HEVC Main 10 4K L5.1 → native")
        expect(route(probe: sample(profile: 4), nativeDVEnabled: true).engine, .mpv, "HEVC RExt (4:2:2, 4:4:4, 12-bit) → mpv")
        expect(route(probe: sample(profile: 2, bitDepth: 12), nativeDVEnabled: true).engine, .mpv, "HEVC 12-bit → mpv")
        expect(route(probe: sample(profile: 2, width: 7680, height: 4320), nativeDVEnabled: true).engine, .mpv, "HEVC 8K → mpv")
        expect(route(probe: sample(profile: 2, width: 2160, height: 3840), nativeDVEnabled: true).engine, .native, "HEVC portrait 4K → native")
        expect(route(probe: sample(profile: 2, level: 186), nativeDVEnabled: true).engine, .mpv, "HEVC level 6.2 → mpv")
        expect(route(probe: sample(profile: 2, level: 156), nativeDVEnabled: true).engine, .native, "HEVC level 5.2 → native")
        expect(route(probe: sample(profile: -99), nativeDVEnabled: true).engine, .native, "HEVC unknown profile → native")
        // Interlaced video.
        expect(route(probe: sample(video: "h264", fieldOrder: 2), nativeDVEnabled: true).engine, .mpv, "interlaced → mpv")
        expect(route(probe: sample(video: "h264", fieldOrder: 1), nativeDVEnabled: true).engine, .native, "progressive → native")
        expect(route(probe: sample(video: "h264", fieldOrder: 2), nativeDVEnabled: true,
                     options: RoutingOptions(enginePreference: .preferNative)).engine, .native, "interlaced + Prefer Native → native")
        expect(route(probe: sample(audio: ["truehd", "ac3"]), nativeDVEnabled: true).engine, .native, "TrueHD+AC3 → native")
        expect(route(probe: sample(seekable: false), nativeDVEnabled: true).engine, .mpv, "non-seekable → mpv")
        expect(route(probe: sample(container: "avi"), nativeDVEnabled: true).engine, .mpv, "AVI → mpv")
        expect(route(probe: sample(container: "mpegts"), nativeDVEnabled: true).engine, .mpv, "MPEG-TS → mpv")
        expect(route(probe: sample(dv: p5), nativeDVEnabled: false).engine, .mpv, "flag off → mpv")
        expect(route(probe: nil, nativeDVEnabled: true).engine, .mpv, "nil probe → mpv")
        expect(route(probe: nil, nativeDVEnabled: true, options: RoutingOptions(enginePreference: .preferNative)).engine, .native, "nil probe + Prefer Native → native")
        // HLS.
        let hls = route(probe: sample(video: "h264", audio: ["aac"], seekable: false, container: "hls"), nativeDVEnabled: true)
        expect(hls.engine, .native, "HLS → native, direct")
        if hls.delivery != .directHLS { fails.append("router self-check: HLS is delivered directly") }
        expect(route(probe: sample(video: "vp9", audio: ["aac"], container: "hls"), nativeDVEnabled: true).engine, .mpv, "VP9 in HLS → mpv")
        expect(route(probe: sample(video: "h264", audio: ["dts"], container: "hls"), nativeDVEnabled: true).engine, .mpv, "DTS in HLS → mpv")
        expect(routeHLS(nativeDVEnabled: true).engine, .native, "an .m3u8 URL → native")
        expect(routeHLS(nativeDVEnabled: false).engine, .mpv, "an .m3u8 URL + flag off → mpv")
        // The Player preference.
        expect(route(probe: sample(), nativeDVEnabled: true, options: RoutingOptions(enginePreference: .preferMpv)).engine, .mpv, "Prefer mpv → mpv")
        expect(route(probe: sample(dv: p81), nativeDVEnabled: true, options: RoutingOptions(enginePreference: .preferMpv)).engine, .native, "Prefer mpv keeps true Dolby Vision native")
        expect(route(probe: sample(dv: p81), nativeDVEnabled: true, stripDolbyVision: true,
                     options: RoutingOptions(enginePreference: .preferMpv)).engine, .mpv, "Prefer mpv + HDR10 Only → mpv")
        expect(routeHLS(nativeDVEnabled: true, options: RoutingOptions(enginePreference: .preferMpv)).engine, .mpv, "Prefer mpv + an .m3u8 URL → mpv")
        if !nativeCouldPlay(probe: sample(), options: RoutingOptions(enginePreference: .preferMpv)) {
            fails.append("router self-check: Prefer mpv still leaves the native player possible")
        }
        // PLY-A9: the DV profile travels with every decision, mpv ones included.
        let p5OnMpv = route(probe: sample(dv: p5, seekable: false), nativeDVEnabled: true)
        if p5OnMpv.engine != .mpv || !p5OnMpv.needsDVReshapeOnMPV {
            fails.append("router self-check: non-seekable DV P5 → mpv with reshaping")
        }
        if route(probe: sample(dv: p81), nativeDVEnabled: true).needsDVReshapeOnMPV {
            fails.append("router self-check: DV P8.1 needs no reshaping")
        }
        if !isHLSURL(URL(string: "https://example.com/videos/1/master.m3u8?api_key=x")!)
            || isHLSURL(URL(string: "https://example.com/movie.mkv")!) {
            fails.append("router self-check: HLS URL detection")
        }
        return fails
    }
}
#endif
