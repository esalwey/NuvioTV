import Foundation

// Phase 1 of the hybrid player: the pure routing decision. Given a `ProbeResult` (or nil) and the
// user's native-DV setting, decide which engine should render the stream. Deliberately dependency-
// free (no libav*, no SwiftUI) so it is trivially testable — see `selfCheckFailures()` below.
// See docs/tvos-hybrid-player-plan.md.
//
// Routing is conservative: the native AVPlayer path is chosen only when every check passes;
// anything ambiguous falls through to mpv, which plays everything today.

nonisolated enum PlaybackEngine: String, Sendable {
    case native   // AVPlayer, fed by the on-device MKV→fMP4 remux (true Dolby Vision, hardware decode)
    case mpv      // libmpv, the universal fallback
}

nonisolated struct EngineDecision: Equatable, Sendable {
    let engine: PlaybackEngine
    let reason: String
    /// The probed Dolby Vision profile, whichever engine was chosen (nil: no DV, or no probe).
    /// PLY-A9: a Profile 5 file that ends up on mpv — routed there, or after a native fallback —
    /// needs libplacebo's reshaping (`MPVTVPlayerViewController.forceDVReshape`, contract C1).
    var dvProfile: Int? = nil
    /// The file has an object-based audio track (TrueHD Atmos / DTS:X, announced by FFmpeg's profile or
    /// the track title) and Spatial Audio is on: the native player converts it to Dolby Atmos (APAC).
    /// Only ever set on a native decision; mpv decodes such a track to its 5.1 / 7.1 bed, without the
    /// heights.
    var spatialAudio: SpatialAudioKind? = nil

    /// mpv must render this file with Dolby Vision reshaping (Profile 5 has no HDR10/SDR base layer).
    var needsDVReshapeOnMPV: Bool { dvProfile == 5 }

    /// Short label for the Stream Info overlay, e.g. "Native · DV P8.1 · Atmos" or "mpv · audio truehd".
    var displayNote: String {
        var note = "\(engine == .native ? String(localized: "Native") : "mpv") \u{00B7} \(reason)"
        if engine == .native, let spatialAudio {
            note += " \u{00B7} " + (spatialAudio == .trueHDAtmos ? "Atmos" : "DTS:X")
        }
        return note
    }
}

nonisolated enum PlayerEngineRouter {
    /// Decide the engine for a probed stream. `nativeDVEnabled` is the Settings > Playback beta flag;
    /// `dvP7FelToMpv` is its FEL-fidelity sub-setting (send Profile 7 FEL files to mpv instead of
    /// discarding their enhancement layer in the 8.1 conversion). `stripDolbyVision` is the "HDR10
    /// Only" Dolby Vision mode: Dolby Vision files play on mpv, which shows their HDR10 layer
    /// (Profile 5 has none and is left to the usual rules). All three come from `DolbyVisionMode`.
    ///
    /// `spatialAudio` is the Settings > Playback > Audio switch (`SpatialAudioPolicy.isEnabled`). It
    /// changes the label of a native decision, not the decision: the native engine is the only one that
    /// can play TrueHD Atmos / DTS:X as Dolby Atmos (APAC needs AVPlayer; mpv's PCM output cannot carry
    /// it), and no rule below sends such a file to mpv because of its audio — TrueHD and DTS are
    /// transcodable (`isTranscodableAudio`), so a file whose best audio is one of them is native
    /// whenever its container, video and Dolby Vision profile are. What is left on mpv for such a
    /// file is what the native engine cannot play at all (container, video codec, non-seekable
    /// source, two-track Profile 7) or what the viewer chose: the Dolby Vision mode (Off, HDR10 Only,
    /// HDR10 for Profile 7 FEL) and the Player Engine switch. Those preferences are about the picture and
    /// are explicit, so Atmos does not override them.
    static func route(probe: ProbeResult?, nativeDVEnabled: Bool, dvP7FelToMpv: Bool = false,
                      stripDolbyVision: Bool = false, spatialAudio: Bool = false) -> EngineDecision {
        var decision = decide(probe: probe, nativeDVEnabled: nativeDVEnabled, dvP7FelToMpv: dvP7FelToMpv,
                              stripDolbyVision: stripDolbyVision)
        decision.dvProfile = probe?.dolbyVision?.profile
        if spatialAudio, decision.engine == .native, let probe {
            decision.spatialAudio = SpatialAudioPolicy.announcedKind(in: probe.audio)
        }
        return decision
    }

    private static func decide(probe: ProbeResult?, nativeDVEnabled: Bool, dvP7FelToMpv: Bool,
                               stripDolbyVision: Bool) -> EngineDecision {
        guard nativeDVEnabled else { return EngineDecision(engine: .mpv, reason: "native engine off") }
        guard let p = probe else { return EngineDecision(engine: .mpv, reason: "probe unavailable") }
        guard p.seekable else { return EngineDecision(engine: .mpv, reason: "source not seekable") }
        guard isNativeContainer(p.container) else {
            return EngineDecision(engine: .mpv, reason: "container \(p.container)")
        }
        guard p.videoCodec == "hevc" || p.videoCodec == "h264" else {
            return EngineDecision(engine: .mpv, reason: p.videoCodec.isEmpty ? "no video stream" : "video \(p.videoCodec)")
        }
        // H.264 High 10 / 4:2:2 / 4:4:4 (10-bit anime encodes, mostly): no hardware decoder on Apple
        // TV and none in AVPlayer — the item fails after the remux spun up and playback restarts on
        // mpv. Straight to mpv instead.
        if p.videoCodec == "h264", isUnsupportedH264Profile(p.videoProfile) {
            return EngineDecision(engine: .mpv, reason: "video h264 profile \(p.videoProfile)")
        }

        // Dolby Vision profile gating. P5 and single-layer P8 play natively on tvOS 17.2+. Dual-layer
        // P7 converts to 8.1 during the remux (Phase 5: EL NALs dropped, RPUs rewritten via libdovi) —
        // but only the single-track layout whose RPUs the probe could actually parse; anything else
        // (two-track BL+EL, no RPU found, unparseable RPU) stays on mpv.
        if let dv = p.dolbyVision {
            // "HDR10 Only": mpv plays the HDR10 layer. Profile 5 has none, so it follows the rules below.
            if stripDolbyVision, dv.profile != 5 {
                return EngineDecision(engine: .mpv, reason: "DV P\(dv.profile) \u{2192} HDR10 (preference)")
            }
            switch dv.profile {
            case 5, 8: break
            case 7:
                guard p.videoStreamCount == 1 else {
                    return EngineDecision(engine: .mpv, reason: "DV P7 two-track")
                }
                switch dv.elKind {
                case .mel:
                    break
                case .fel:
                    if dvP7FelToMpv {
                        return EngineDecision(engine: .mpv, reason: "DV P7 FEL (fidelity preference)")
                    }
                case .missing, .unsupported, nil:
                    return EngineDecision(engine: .mpv, reason: "DV P7 (no convertible RPU)")
                }
            default: return EngineDecision(engine: .mpv, reason: "DV P\(dv.profile)")
            }
        }

        // At least one audio track must be AVPlayer-compatible (stream-copied) or one the remux
        // converts (TrueHD/DTS to lossless FLAC or AAC, or to Dolby Atmos). Video-only files are fine.
        let hasCompatibleAudio = p.audio.isEmpty
            || p.audio.contains { isNativeAudio($0.codec) || isTranscodableAudio($0.codec) }
        guard hasCompatibleAudio else {
            return EngineDecision(engine: .mpv, reason: "audio \(p.audio.first?.codec ?? "none")")
        }

        return EngineDecision(engine: .native, reason: nativeReason(p))
    }

    // MARK: - Criteria

    /// avformat reports comma-joined demuxer names (e.g. "matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2").
    private static func isNativeContainer(_ container: String) -> Bool {
        let c = container.lowercased()
        return c.contains("matroska") || c.contains("webm") || c.contains("mp4") || c.contains("mov")
    }

    /// Audio codecs AVPlayer can play directly (the remux stream-copies these).
    private static func isNativeAudio(_ codec: String) -> Bool {
        switch codec {
        case "aac", "ac3", "eac3", "flac", "alac", "mp3": return true
        default: return false
        }
    }

    /// Codecs the remux transcodes to AAC when no copyable track exists (AudioTranscoder — decoders
    /// verified present in the MPVKit FFmpeg build). Canonical descriptor names as MediaProbe reports
    /// them: FFmpeg calls DTS (incl. DTS-HD, decoded via its core/extensions) "dts". Opus and Vorbis
    /// joined in 2026-10 (`AudioTranscoder.isTranscodable`).
    private static func isTranscodableAudio(_ codec: String) -> Bool {
        codec == "truehd" || codec == "dts" || codec == "opus" || codec == "vorbis"
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

    private static func nativeReason(_ p: ProbeResult) -> String {
        if let dv = p.dolbyVision {
            if dv.profile == 7 {
                return "DV P7 \(dv.elKind == .fel ? "FEL" : "MEL") \u{2192} 8.1"
            }
            // compatId 1 == HDR10-compatible base layer, i.e. Profile 8.1.
            return dv.profile == 8 && dv.compatId == 1 ? "DV P8.1" : "DV P\(dv.profile)"
        }
        switch p.hdr {
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .other: return "HDR"
        case .sdr: return "SDR"
        }
    }
}

#if DEBUG
extension PlayerEngineRouter {
    /// Router assertions with canned probe results — stands in for a unit-test target (this project
    /// has none). Returns human-readable failures; run once at first playback (see PlayerScreen).
    static func selfCheckFailures() -> [String] {
        var fails: [String] = []
        func expect(_ actual: PlaybackEngine, _ expected: PlaybackEngine, _ msg: String) {
            if actual != expected { fails.append("router self-check: \(msg) (got \(actual.rawValue))") }
        }
        func sample(video: String = "hevc", dv: DolbyVisionInfo? = nil, hdr: HDRFormat = .sdr,
                    audio: [String] = ["eac3"], seekable: Bool = true,
                    container: String = "matroska,webm", videoStreams: Int = 1,
                    profile: Int32 = 0) -> ProbeResult {
            ProbeResult(
                container: container, videoCodec: video, videoProfile: profile, hdr: hdr, dolbyVision: dv,
                audio: audio.enumerated().map { AudioStreamInfo(index: $0.offset, codec: $0.element, channels: 6, language: "eng") },
                subtitles: [], durationSec: 3600, seekable: seekable, videoStreamCount: videoStreams
            )
        }
        let p5 = DolbyVisionInfo(profile: 5, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 0)
        let p81 = DolbyVisionInfo(profile: 8, level: 6, blPresent: true, elPresent: false, rpuPresent: true, compatId: 1)
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
        expect(route(probe: sample(dv: p81), nativeDVEnabled: true, stripDolbyVision: true).engine, .mpv, "DV P8.1 + HDR10 Only → mpv")
        expect(route(probe: sample(dv: p7(.mel)), nativeDVEnabled: true, stripDolbyVision: true).engine, .mpv, "DV P7 MEL + HDR10 Only → mpv")
        expect(route(probe: sample(dv: p5), nativeDVEnabled: true, stripDolbyVision: true).engine, .native, "DV P5 keeps Dolby Vision under HDR10 Only")
        expect(route(probe: sample(hdr: .hdr10), nativeDVEnabled: true, stripDolbyVision: true).engine, .native, "plain HDR10 unaffected by HDR10 Only")
        expect(route(probe: sample(dv: p7(.mel), videoStreams: 2), nativeDVEnabled: true).engine, .mpv, "DV P7 two-track → mpv")
        expect(route(probe: sample(dv: p7(.missing)), nativeDVEnabled: true).engine, .mpv, "DV P7 without RPUs → mpv")
        expect(route(probe: sample(dv: p7(.unsupported)), nativeDVEnabled: true).engine, .mpv, "DV P7 unparseable RPU → mpv")
        expect(route(probe: sample(dv: p7(nil)), nativeDVEnabled: true).engine, .mpv, "DV P7 unclassified → mpv")
        expect(route(probe: sample(hdr: .hdr10), nativeDVEnabled: true).engine, .native, "HDR10 HEVC → native")
        expect(route(probe: sample(video: "h264"), nativeDVEnabled: true).engine, .native, "H.264 → native")
        expect(route(probe: sample(video: "av1"), nativeDVEnabled: true).engine, .mpv, "AV1 → mpv")
        expect(route(probe: sample(audio: ["truehd"]), nativeDVEnabled: true).engine, .native, "TrueHD-only → native (transcode)")
        expect(route(probe: sample(audio: ["dts"]), nativeDVEnabled: true).engine, .native, "DTS-only → native (transcode)")
        expect(route(probe: sample(audio: ["opus"]), nativeDVEnabled: true).engine, .native, "Opus-only → native (transcode)")
        expect(route(probe: sample(audio: ["vorbis"]), nativeDVEnabled: true).engine, .native, "Vorbis-only → native (transcode)")
        expect(route(probe: sample(audio: ["pcm_s16le"]), nativeDVEnabled: true).engine, .mpv, "PCM-only → mpv")
        expect(route(probe: sample(video: "h264", profile: 100), nativeDVEnabled: true).engine, .native, "H.264 High → native")
        expect(route(probe: sample(video: "h264", profile: 110), nativeDVEnabled: true).engine, .mpv, "H.264 High 10 → mpv")
        expect(route(probe: sample(video: "h264", profile: 244), nativeDVEnabled: true).engine, .mpv, "H.264 High 4:4:4 → mpv")
        expect(route(probe: sample(video: "h264", profile: -99), nativeDVEnabled: true).engine, .native, "H.264 unknown profile → native")
        expect(route(probe: sample(audio: ["truehd", "ac3"]), nativeDVEnabled: true).engine, .native, "TrueHD+AC3 → native")
        expect(route(probe: sample(seekable: false), nativeDVEnabled: true).engine, .mpv, "non-seekable → mpv")
        expect(route(probe: sample(container: "avi"), nativeDVEnabled: true).engine, .mpv, "AVI → mpv")
        expect(route(probe: sample(dv: p5), nativeDVEnabled: false).engine, .mpv, "flag off → mpv")
        expect(route(probe: nil, nativeDVEnabled: true).engine, .mpv, "nil probe → mpv")
        // Spatial audio: an announced TrueHD Atmos / DTS:X track labels a native decision and never
        // changes the engine; the viewer's explicit routing (native engine off, HDR10 Only, FEL on mpv)
        // still wins.
        var atmosProbe = sample(hdr: .hdr10, audio: ["truehd", "ac3"])
        atmosProbe.audio[0].profile = Int32(FFmpegAudioProfile.trueHDAtmos)
        let atmos = route(probe: atmosProbe, nativeDVEnabled: true, spatialAudio: true)
        if atmos.engine != .native || atmos.spatialAudio != .trueHDAtmos {
            fails.append("router self-check: TrueHD Atmos + spatial audio → native, labelled")
        }
        if route(probe: atmosProbe, nativeDVEnabled: true, spatialAudio: false).spatialAudio != nil {
            fails.append("router self-check: spatial audio off → no Atmos label")
        }
        expect(route(probe: atmosProbe, nativeDVEnabled: false, spatialAudio: true).engine, .mpv, "Atmos + native engine off → mpv")
        var dtsxProbe = sample(dv: p81, audio: ["dts"])
        dtsxProbe.audio[0].title = "DTS:X 7.1"
        let dtsx = route(probe: dtsxProbe, nativeDVEnabled: true, spatialAudio: true)
        if dtsx.engine != .native || dtsx.spatialAudio != .dtsX || !dtsx.displayNote.hasSuffix("DTS:X") {
            fails.append("router self-check: DTS:X + DV P8.1 → native, labelled")
        }
        expect(route(probe: dtsxProbe, nativeDVEnabled: true, stripDolbyVision: true, spatialAudio: true).engine, .mpv,
               "DTS:X + HDR10 Only → mpv (the viewer's Dolby Vision choice wins)")
        if route(probe: sample(audio: ["truehd"]), nativeDVEnabled: true, spatialAudio: true).spatialAudio != nil {
            fails.append("router self-check: plain TrueHD (not announced) carries no label")
        }
        // PLY-A9: the DV profile travels with every decision, mpv ones included.
        let p5OnMpv = route(probe: sample(dv: p5, seekable: false), nativeDVEnabled: true)
        if p5OnMpv.engine != .mpv || !p5OnMpv.needsDVReshapeOnMPV {
            fails.append("router self-check: non-seekable DV P5 → mpv with reshaping")
        }
        if route(probe: sample(dv: p81), nativeDVEnabled: true).needsDVReshapeOnMPV {
            fails.append("router self-check: DV P8.1 needs no reshaping")
        }
        return fails
    }
}
#endif
