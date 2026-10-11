import AVFoundation
import SharedCore

/// How the picture fills the screen, chosen from the transport bar's Aspect Ratio menu — the same
/// three choices and the same wording on both engines:
///  - Fit: the whole picture, black bars where its shape differs from the screen's (the default);
///  - Fill: the picture is scaled until it covers the screen and the overflow is cropped, which
///    removes the bars of 21:9 films on a 16:9 TV;
///  - Stretch: the picture is stretched to the screen's shape, to correct a file flagged with the
///    wrong aspect ratio.
///
/// Fit and Fill are remembered (the shared, profile-synced `resizeMode` the phone writes too);
/// Stretch is a correction for one file, so it lasts for that playback only. Zoom presets are not
/// offered: AVPlayerViewController can only change its video gravity, and both engines must offer
/// the same choices.
enum PlayerAspectMode: String, CaseIterable, Identifiable, Hashable {
    case fit, fill, stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit:
            return String(localized: "player.aspect.fit", defaultValue: "Fit",
                          comment: "Player Aspect Ratio menu: show the whole picture, with black bars where its shape differs from the screen's.")
        case .fill:
            return String(localized: "player.aspect.fill", defaultValue: "Fill",
                          comment: "Player Aspect Ratio menu: scale the picture to cover the whole screen, cropping the edges.")
        case .stretch:
            return String(localized: "player.aspect.stretch", defaultValue: "Stretch",
                          comment: "Player Aspect Ratio menu: stretch the picture to the shape of the screen.")
        }
    }

    /// The native player's video gravity.
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    /// mpv `panscan`: 0 keeps the whole picture, 1 crops it to cover the window.
    var mpvPanscan: Double { self == .fill ? 1 : 0 }

    /// mpv `keepaspect`: off stretches the picture to the window.
    var mpvKeepsAspect: Bool { self != .stretch }

    /// The shared setting this mode is remembered as; nil for Stretch, which is not remembered.
    var persistedResizeMode: PlayerResizeMode? {
        switch self {
        case .fit: return PlayerResizeMode.fit
        case .fill: return PlayerResizeMode.fill
        case .stretch: return nil
        }
    }

    /// The mode a stored `resizeMode` stands for. The phone's Zoom (a cropping fill) reads as Fill.
    init(resizeMode: PlayerResizeMode) {
        switch resizeMode.name {
        case "Fill", "Zoom": self = .fill
        default: self = .fit
        }
    }

    /// Remembers this choice for the next playback (Stretch is left out, see above).
    @MainActor
    func remember() {
        guard let mode = persistedResizeMode else { return }
        PlayerSettingsRepository.shared.setResizeMode(mode: mode)
    }
}
