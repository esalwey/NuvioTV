import Foundation

/// Settings > Playback > Dolby Vision: how Dolby Vision files are played, in one choice instead of
/// two switches. The mode is stored through the legacy keys (`PlayerTuning.nativeDVKey`,
/// `dvP7FelMpvKey`) plus `dvHdr10OnlyKey`, so every existing reader (the engine router, the stream
/// ranking's "plays as Dolby Vision" rule) and an older build keep working, and a profile that
/// only ever had the two switches opens on the matching mode.
nonisolated enum DolbyVisionMode: String, CaseIterable, Identifiable, Sendable {
    /// Native player for compatible files (true Dolby Vision), Profile 7 converted to 8.1.
    case automatic
    /// Automatic, but Profile 7 FEL releases play on mpv as HDR10 so nothing is discarded.
    case hdr10Fel
    /// Dolby Vision files play as their HDR10 base layer, on the native player with the Dolby Vision
    /// data stripped (Profile 5, which has no HDR10 layer, excepted).
    case hdr10Only
    /// No native player at all: everything plays on mpv.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .hdr10Fel: return String(localized: "HDR10 for Profile 7 FEL")
        case .hdr10Only: return String(localized: "HDR10 Only")
        case .off: return String(localized: "Off")
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return String(localized: "Play Dolby Vision, HDR10 and other compatible files on the native player for true Dolby Vision output on Apple TV 4K; everything else stays on the mpv player. Profile 7 discs convert to 8.1 on the fly.")
        case .hdr10Fel:
            return String(localized: "Like Automatic, but Profile 7 FEL releases, whose enhancement data the 8.1 conversion must discard, play on the mpv player as HDR10 with nothing discarded. MEL releases still play natively.")
        case .hdr10Only:
            return String(localized: "Dolby Vision files play as HDR10, their base layer, for displays that show Dolby Vision artifacts. Profile 5 has no HDR10 layer and keeps playing as Dolby Vision.")
        case .off:
            return String(localized: "Everything plays on the mpv player, and Dolby Vision shows as HDR10.")
        }
    }

    /// The native (AVPlayer) engine may be chosen at all (`PlayerTuning.nativeDVKey`).
    var nativeEngineEnabled: Bool { self != .off }

    /// Profile 7 FEL goes to mpv instead of being converted (`PlayerTuning.dvP7FelMpvKey`).
    var sendsP7FelToMpv: Bool { self == .hdr10Fel }

    /// Dolby Vision files play as their HDR10 base layer: the native player's remux drops the Dolby
    /// Vision data (`DolbyVisionHandling.stripToBase`), and a stream it cannot rewrite goes to mpv.
    var stripsDolbyVision: Bool { self == .hdr10Only }

    /// A Dolby Vision file can reach the screen as Dolby Vision (the stream ranking asks).
    var playsDolbyVision: Bool { self == .automatic || self == .hdr10Fel }

    // MARK: Storage

    /// The mode the three stored keys describe. The legacy switches stay the truth for the engine
    /// on/off and the FEL rule, so a value written by an older build or a test harness
    /// (`defaults write … player.nativeDolbyVision -bool NO`) is honoured.
    static func resolve(nativeEnabled: Bool, p7FelToMpv: Bool, hdr10Only: Bool) -> DolbyVisionMode {
        if !nativeEnabled { return .off }
        if hdr10Only { return .hdr10Only }
        return p7FelToMpv ? .hdr10Fel : .automatic
    }

    static var current: DolbyVisionMode {
        let defaults = UserDefaults.standard
        return resolve(nativeEnabled: defaults.bool(forKey: PlayerTuning.nativeDVKey),
                       p7FelToMpv: defaults.bool(forKey: PlayerTuning.dvP7FelMpvKey),
                       hdr10Only: defaults.bool(forKey: PlayerTuning.dvHdr10OnlyKey))
    }

    func store() {
        let defaults = UserDefaults.standard
        defaults.set(nativeEngineEnabled, forKey: PlayerTuning.nativeDVKey)
        defaults.set(sendsP7FelToMpv, forKey: PlayerTuning.dvP7FelMpvKey)
        defaults.set(stripsDolbyVision, forKey: PlayerTuning.dvHdr10OnlyKey)
    }
}
