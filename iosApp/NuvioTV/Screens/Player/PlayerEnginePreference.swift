import Foundation

/// Settings > Playback > Advanced > Player: which engine plays a file when more than one could.
///
/// The native player (AVPlayer, fed by the on-device remux or opening an HLS stream itself) is the
/// only exact copy of the system player there is: its transport bar, scrubbing, skips, menus,
/// Siri and Liquid Glass are the system's own. So the default is native first. The three choices
/// differ only where the native player would give something up; what it cannot play at all (VP9,
/// MPEG-2, 10-bit H.264, a stream that is not seekable...) always goes to mpv, and a native player
/// that fails still hands the file to mpv.
///
/// It sits next to the Dolby Vision picker and does not replace it: Dolby Vision "Off" is the older
/// kill switch for the native player (`PlayerTuning.nativeDVKey`) and still wins, and the other
/// Dolby Vision modes (HDR10 only, HDR10 for Profile 7 FEL) keep deciding how Dolby Vision files
/// are played when the native player is used. See docs/player-spec.md, "Engine routing".
nonisolated enum PlayerEnginePreference: String, CaseIterable, Identifiable, Sendable {
    /// Native first. The default.
    case automatic
    /// Native for everything it can open at all, even at the cost of image subtitles, a stream
    /// the probe could not read, or interlaced video it may not deinterlace.
    case preferNative
    /// mpv for everything, except the Dolby Vision files the Dolby Vision picker sends to the native
    /// player (true Dolby Vision needs it).
    case preferMpv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .preferNative: return String(localized: "Prefer Native")
        case .preferMpv: return String(localized: "Prefer mpv")
        }
    }

    /// The line under the Player row. `nativeEngineEnabled` is false when the Dolby Vision picker
    /// is on Off: the native player is then off whatever this says.
    func detail(nativeEngineEnabled: Bool) -> String {
        guard nativeEngineEnabled else {
            return String(localized: "The native player is turned off in Dolby Vision settings, so everything plays on mpv.")
        }
        switch self {
        case .automatic:
            return String(localized: "Native first: each file plays on the Apple player, with the system controls, whenever it can, and on the mpv player for the formats it cannot play. A file whose subtitles in your language exist only as images stays on mpv.")
        case .preferNative:
            return String(localized: "Everything the Apple player can open plays on it, even if that means doing without image subtitles or a stream that could not be read first. mpv only takes what the Apple player cannot play.")
        case .preferMpv:
            return String(localized: "Everything plays on the mpv player, except Dolby Vision files, which keep the Apple player for true Dolby Vision output.")
        }
    }

    // MARK: Storage

    /// The stored choice; absent or unknown reads as Automatic.
    static var current: PlayerEnginePreference {
        UserDefaults.standard.string(forKey: PlayerTuning.enginePreferenceKey)
            .flatMap(PlayerEnginePreference.init(rawValue:)) ?? .automatic
    }

    func store() {
        UserDefaults.standard.set(rawValue, forKey: PlayerTuning.enginePreferenceKey)
    }
}
