import AVFoundation
import Foundation

// Spatial audio on the native (AVPlayer) engine: TrueHD Atmos and DTS:X tracks become Dolby Atmos.
//
// AVPlayer cannot decode TrueHD or DTS, and the remux used to turn them into AAC 5.1, which loses the
// lossless mix and every height channel. SpatialAudioBridge (Apache-2.0, github.com/kristofferR/
// SpatialAudioBridge) decodes the track, renders its objects to 7.1.4 speaker feeds and encodes them as
// Apple Positional Audio Codec (APAC), which tvOS plays natively. This file holds the decisions around
// that conversion that need no library or FFmpeg types, so they stay unit-testable: when it applies,
// which tracks are candidates, and how the result is described to the viewer. The conversion itself is
// `SpatialAudioEngine.swift`; the session wiring is `SpatialAudioSession.swift`.

/// The object-based format a spatial rendition is converted from.
nonisolated enum SpatialAudioKind: String, Sendable, Equatable {
    case trueHDAtmos
    case dtsX

    /// The source as the Stream Info row names it. Format names are not translated.
    var sourceName: String {
        switch self {
        case .trueHDAtmos: return "TrueHD Atmos"
        case .dtsX: return "DTS:X"
        }
    }

    /// What the Audio menu calls the rendition: the receiver shows Dolby Atmos for both formats, but a
    /// DTS:X release is looked for under its own name.
    var menuName: String {
        switch self {
        case .trueHDAtmos: return "Dolby Atmos"
        case .dtsX: return "DTS:X"
        }
    }
}

/// `AVCodecParameters.profile` values of the audio codecs involved, as FFmpeg defines them
/// (libavcodec/defs.h `AV_PROFILE_*`). Plain numbers, so nothing here depends on how recent the
/// FFmpeg inside MPVKit is: an older build simply never reports the Atmos / DTS:X ones.
nonisolated enum FFmpegAudioProfile {
    static let unknown = -99
    /// `AV_PROFILE_TRUEHD_ATMOS` (FFmpeg 7.0 and later).
    static let trueHDAtmos = 30
    /// `AV_PROFILE_DTS` (core), `_ES`, `_96_24`, `_HD_HRA`, `_EXPRESS`: lossy, never DTS:X.
    static let lossyDTS: Set<Int> = [20, 30, 40, 50, 70]
    /// `AV_PROFILE_DTS_HD_MA`, `_MA_X`, `_MA_X_IMAX`.
    static let dtsHDMA = 60
    static let dtsHDMAX = 61
    static let dtsHDMAXIMAX = 62
}

nonisolated enum SpatialAudioPolicy {

    // MARK: - Settings

    /// Settings > Playback > Audio > Spatial Audio for TrueHD Atmos and DTS:X. Device-local, ON by
    /// default (registered in `NuvioTVApp`; a missing key also reads as ON, so the policy does not
    /// depend on the registration having run).
    static var userEnabled: Bool {
        UserDefaults.standard.object(forKey: PlayerTuning.spatialAudioKey) as? Bool ?? true
    }

    /// The conversion applies: the viewer wants it and this Apple TV can output Dolby Atmos.
    static var isEnabled: Bool { userEnabled && deviceCanOutputAtmos }

    /// Settings > Playback > Audio > Lossless Surround Sound. Same rules as `userEnabled`.
    static var losslessEnabled: Bool {
        UserDefaults.standard.object(forKey: PlayerTuning.losslessAudioKey) as? Bool ?? true
    }

    // MARK: - Device

    /// Apple TV HD (AppleTV5,x) has no Dolby Atmos output and an A8 chip that could not run the
    /// APAC encoder faster than real time; every Apple TV 4K (AppleTV6,2 and later) can. The tvOS
    /// Simulator reports the Mac's architecture and passes.
    static let deviceCanOutputAtmos: Bool = !modelIdentifier().hasPrefix("AppleTV5,")

    /// The hardware model identifier ("AppleTV11,1"), read through `uname(2)` like the About pane.
    static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier += String(UnicodeScalar(UInt8(value)))
        }
    }

    // MARK: - Candidates

    /// What a track is announced to carry, from FFmpeg's profile or the track title: Atmos for TrueHD,
    /// DTS:X for DTS. nil when nothing says so. A hint, not proof: the converter decides when it
    /// decodes the track (`SpatialAudioSession`).
    static func announcedKind(codec: String, profile: Int, title: String?) -> SpatialAudioKind? {
        let text = (title ?? "").lowercased()
        switch codec {
        case "truehd":
            if profile == FFmpegAudioProfile.trueHDAtmos || text.contains("atmos") { return .trueHDAtmos }
        case "dts":
            if profile == FFmpegAudioProfile.dtsHDMAX || profile == FFmpegAudioProfile.dtsHDMAXIMAX { return .dtsX }
            if text.contains("dts:x") || text.contains("dts-x") || text.contains("dtsx") || text.contains("dts x") {
                return .dtsX
            }
        default:
            break
        }
        return nil
    }

    /// Whether the track the viewer starts on is worth converting to find out. Every TrueHD track
    /// (FFmpeg only flags Atmos in recent builds, and a plain TrueHD track is rejected within a
    /// fraction of a second) and every lossless-capable DTS track (alternate DTS:X presentations are
    /// reported as plain DTS-HD MA); a DTS track FFmpeg knows to be lossy is never DTS:X.
    static func probeKind(codec: String, profile: Int) -> SpatialAudioKind? {
        switch codec {
        case "truehd": return .trueHDAtmos
        case "dts": return FFmpegAudioProfile.lossyDTS.contains(profile) ? nil : .dtsX
        default: return nil
        }
    }

    /// The first track of a probe that is announced to be object-based, for the router's label.
    static func announcedKind(in audio: [AudioStreamInfo]) -> SpatialAudioKind? {
        for stream in audio {
            if let kind = announcedKind(codec: stream.codec, profile: Int(stream.profile), title: stream.title) {
                return kind
            }
        }
        return nil
    }

    /// Announced tracks other than the initial one that get a spatial rendition too (converted on the
    /// first request, never at startup). Capped: each one is an engine that can hold memory.
    static let maxExtraRenditions = 3

    // MARK: - The APAC output

    /// APAC 7.1.4: twelve channels at 256 kbit/s each. The master lists `apac.31.03` (profile 31,
    /// level 3, "Apple's channel-based APAC") and 12 channels, not JOC.
    static let apacCodecToken = "apac.31.03"
    static let apacChannelCount = 12
    static let apacBitRate = 3_072_000

    /// "Dolby Atmos via APAC 7.1.4 (from TrueHD Atmos)", the Stream Info row of a converted track.
    static func deliveredDescription(for kind: SpatialAudioKind) -> String {
        let source = kind.sourceName
        return String(localized: "Dolby Atmos via APAC 7.1.4 (from \(source))")
    }

    /// What `AtmosOutputActivator.configureAudioSession()` does (playback category, movie playback
    /// mode, multichannel content, activation), run off the main thread: calling it where the
    /// activator lives would put an `AVAudioSession` activation on the main thread, which Xcode's
    /// runtime diagnostics flag as a hang risk (see `NuvioTVApp`).
    static func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setSupportsMultichannelContent(true)
        try? session.setActive(true)
    }
}
