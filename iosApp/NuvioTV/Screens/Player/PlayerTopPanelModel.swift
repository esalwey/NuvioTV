import Combine
import SwiftUI

// Engine-agnostic backing model for the swipe-down top panel (Info · Subtitles · Audio). The native
// AVPlayer screen fills it through `NativePlayerPanelAdapter`; the mpv screen can plug in the same
// way later (its `MPVPlaybackState` already exposes track lists + select closures). Closures rather
// than a protocol keep it a plain ObservableObject the SwiftUI panel can observe directly.

/// One selectable row in the Subtitles or Audio tab.
struct PlayerPanelOption: Identifiable, Equatable {
    enum Group: Equatable { case off, embedded, addon, audio }
    /// Stable id: the rendition NAME on the native path (AVPlayer keys options by name), the mpv
    /// track id on the mpv path. `"off"` for the Off row.
    let id: String
    let title: String
    /// Secondary line ("Forced", "SDH", addon name…); nil = none.
    var detail: String? = nil
    /// Language code of the track (ISO 639 / BCP 47, any form the engine has; nil = unknown).
    /// The Subtitles tab groups addon rows by it; rows without one stay ungrouped.
    var language: String? = nil
    let group: Group
    var isSelected: Bool
}

/// One capsule in the Info tab's metadata row ("53 min", "4K", "Dolby Vision"…).
struct PlayerPanelChip: Identifiable, Hashable {
    let text: String
    var symbol: String? = nil
    /// Marks the runtime chip so the catalog runtime can stand in until playback reports one.
    var isRuntime = false
    var id: String { text }
}

/// Info tab content: what's-playing header, metadata chips, live stream rows.
struct PlayerPanelInfo: Equatable {
    var header: NativeInfoHeader
    var chips: [PlayerPanelChip] = []
    var rows: [NativeInfoRow] = []
}

@MainActor
final class PlayerTopPanelModel: ObservableObject {
    @Published var info: PlayerPanelInfo
    /// Subtitles tab rows in display order: Off first (like the system panel), then the file's own
    /// tracks, then addon-fetched ones. Empty while nothing is known yet.
    @Published var subtitles: [PlayerPanelOption] = []
    /// True until the addon subtitle fetch has finished — drives the "Searching…" empty state.
    @Published var subtitlesSearching = true
    /// Addon subtitles that arrived after playback had already started (LANG-08). The Subtitles
    /// tab says "N found after playback started" while it is > 0. Engines that never add rows
    /// late leave it at 0.
    @Published var lateAddonSubtitleCount: Int = 0
    @Published var audio: [PlayerPanelOption] = []
    /// Human name of the current audio output route ("Living Room", "AirPods Pro", "Apple TV").
    @Published var outputRouteName = ""
    /// Whether the Audio tab offers the system route picker (AirPlay/Bluetooth). False on engines
    /// that don't drive AVAudioSession routing.
    @Published var canPickRoute = true
    /// Whether the Audio tab points to the system player's own Audio button for Enhance Dialogue /
    /// Reduce Loud Sounds (VIS-07). Only the native engine has that button, so it sets this true;
    /// mpv leaves it false and the hint is not shown.
    @Published var showsSystemAudioHint: Bool = false

    /// Current subtitle delay in milliseconds (0 = none, positive = subtitles later). Meaningless
    /// while `supportsSubtitleDelay` is false.
    @Published var subtitleDelayMs: Int = 0
    /// Whether the current engine can re-time subtitles at all — false hides the Subtitles tab's
    /// "Timing" row entirely. mpv sets this true (`MPVPlayerPanelAdapter`); the native AVPlayer
    /// adapter leaves it false until the delay mechanism lands (beta.15 §B3).
    @Published var supportsSubtitleDelay: Bool = false

    /// Current audio delay in milliseconds (0 = none, positive = audio later). Shown in the Audio
    /// tab's right column while `supportsAudioDelay` is true (LANG-13).
    @Published var audioDelayMs: Int = 0
    /// Whether the current engine can shift audio (mpv `audio-delay`). False hides the row.
    @Published var supportsAudioDelay: Bool = false

    /// Last tab the viewer had open, so the panel reopens there for the rest of the session (F16).
    /// The model lives as long as the player screen, which is exactly one session. Not published:
    /// only read when the panel is built.
    var lastTab: PlayerPanelTab = .info

    /// nil = Off.
    var onSelectSubtitle: ((PlayerPanelOption?) -> Void)?
    var onSelectAudio: ((PlayerPanelOption) -> Void)?
    /// New delay in milliseconds, already clamped to ±`SUBTITLE_DELAY_MAX_MS`.
    var onSubtitleDelayChange: ((Int) -> Void)?
    /// New audio delay in milliseconds, already clamped to ±`PlayerTopPanelModel.audioDelayLimitMs`.
    var onAudioDelayChange: ((Int) -> Void)?
    var onClose: (() -> Void)?

    /// Audio delay bound (±10 s), the range the old Playback-tab row allowed.
    static let audioDelayLimitMs = 10_000

    init(info: PlayerPanelInfo) {
        self.info = info
    }
}
