import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

/// Observable playback state the SwiftUI controls overlay binds to. The player controller polls libmpv
/// (~2x/sec) and pushes updates here on the main thread.
@MainActor
final class MPVPlaybackState: ObservableObject {
    @Published var positionSec: Double = 0
    @Published var durationSec: Double = 0
    @Published var isPaused: Bool = false {
        didSet {
            // Playing again: the next pause shows its chrome and card again (F3).
            if oldValue, !isPaused, pauseChromeDismissed { pauseChromeDismissed = false }
        }
    }
    @Published var isBuffering: Bool = true
    @Published var controlsVisible: Bool = false
    /// Back hid the transport bar and the pause card while paused (F3, spec §6.9.4 "chrome visible →
    /// hide chrome"): the player stays, and the next Back leaves it. Cleared by any interaction that
    /// shows the chrome again (`flashControls()`) and when playback resumes.
    @Published var pauseChromeDismissed: Bool = false

    /// Touch-surface / held-arrow scrubbing (PLY-A3, spec gap 2): the time the scrub head points
    /// at. nil = not scrubbing. Select or Play/Pause commits one exact seek there; Back cancels.
    @Published var scrubTargetSec: Double?
    /// Where the scrub started (Back returns here — no seek was issued meanwhile).
    var scrubOriginSec: Double?
    /// The scrub came from a held arrow: its release commits it (a touch-surface scrub waits for
    /// Select or Play/Pause).
    var scrubCommitsOnRelease = false
    /// Hold-right fast-forward rate (2×, 3×, 4×); nil = normal speed (spec §6.9.4, decision D9).
    @Published var fastForwardRate: Double?

    @Published var audioTracks: [PlayerTrack] = []
    @Published var subtitleTracks: [PlayerTrack] = []
    /// The chrome's focus layer (transport menus, content tabs — `MPVTransportFocusView`) is
    /// presented over the player and owns the remote.
    @Published var panelOpen: Bool = false
    /// Addon subtitle fetch in flight — the picker shows "Searching…" instead of hiding the row.
    @Published var subtitleSearchInFlight: Bool = false

    /// Active skip prompt ("Skip Intro"/"Skip Outro") when playback is inside a known segment.
    @Published var skipPrompt: SkipPrompt?

    /// Playback-settings panel state (speed, subtitle/audio delay, diagnostics).
    @Published var playbackSpeed: Double = 1.0
    @Published var subtitleDelaySec: Double = 0
    @Published var audioDelaySec: Double = 0
    @Published var showStreamInfo: Bool = false
    @Published var streamInfo: StreamInfoSnapshot?
    /// Engine routing decision from `PlayerEngineRouter`, shown as the Stream Info "Engine" row.
    /// Diagnostic only in Phase 1 — playback still runs through libmpv regardless.
    @Published var routingNote: String = ""

    /// True once playback hit end-of-file (keep-open holds the last frame). Feeds
    /// `NextEpisodeEngine.playbackDidEnd()`: Up Next hand-off, end screen, or back to details.
    @Published var isEnded: Bool = false
    /// The last end of file was the episode's real end (`UpNextTrigger.isNaturalEnd`), not a stream
    /// that dropped or expired mid-way — only that one records the episode as completed. Set before
    /// `isEnded` flips.
    var endedNaturally = true
    /// The playback error card is up (PLY-1): the overlays under it stay away.
    @Published var playbackErrorShown = false

    /// Wired by the controller so the SwiftUI track picker can drive libmpv.
    var selectAudio: ((Int) -> Void)?
    var selectSubtitle: ((Int) -> Void)?
    var setSpeed: ((Double) -> Void)?
    var setSubtitleDelay: ((Double) -> Void)?
    var setAudioDelay: ((Double) -> Void)?
    var replay: (() -> Void)?
    var reclaimFocus: (() -> Void)?
    /// Exact seek to an absolute time (the Chapters tab).
    var seekTo: ((Double) -> Void)?

    /// Wired by `MPVPlayerScreen` to the `NextEpisodeEngine`; each returns true when the Up Next
    /// card consumed the press (PLY-A4/F5). Select → play the next episode now ("Choose a Source"
    /// when none was found; continue, on the "Still watching?" prompt); Down → play now as well;
    /// Menu → dismiss the card and keep watching the credits. A backward seek drops the card for
    /// the session.
    var upNextSelect: (() -> Bool)?
    var upNextDown: (() -> Bool)?
    var upNextMenu: (() -> Bool)?
    var upNextCancel: (() -> Void)?
    /// "Skip Outro" on credits ending at this position: true when Up Next plays the next episode
    /// instead (credits that run to the end of the file), so the controller doesn't seek.
    var upNextSkipCredits: ((Double) -> Bool)?
    /// Skip segments reached the controller (the engine times the Up Next card on the outro).
    var onSkipSegmentsLoaded: (([SkipSegment]) -> Void)?
    /// Set right before an Up Next hand-off replaces this player: the teardown flush records the
    /// finished episode as completed (and Trakt at 100 %), so Continue Watching moves on.
    var completedByHandOff = false
    /// The engine is prefetching the NEXT episode's addon subtitles into the shared repository —
    /// stop side-loading that list into this file.
    var freezeAddonSubtitles = false
    /// Wired by `MPVPlayerScreen` to the engine: the Up Next card is on screen. An end of file then
    /// belongs to its hand-off (the episode is in its credits), never to the error card (PLY-1).
    var upNextCardUp: (() -> Bool)?
    /// Wired likewise: a file this long is a short error/placeholder clip, not the episode (unless its
    /// metadata runtime is that short too).
    var isPlaceholderClip: ((Double) -> Bool)?

    let title: String
    init(title: String) { self.title = title }

    var fraction: Double {
        durationSec > 0 ? min(max(positionSec / durationSec, 0), 1) : 0
    }
    var hasTracks: Bool { !audioTracks.isEmpty || !subtitleTracks.isEmpty }

    /// The pause chrome (transport bar + pause card) belongs on screen: paused mid-file, and Back
    /// hasn't put it away (F3).
    var pauseChromeShown: Bool {
        isPaused && !isEnded && !playbackErrorShown && !pauseChromeDismissed
    }

    var isScrubbing: Bool { scrubTargetSec != nil }

    /// Scrub head position on the progress bar (0…1), nil when not scrubbing.
    var scrubFraction: Double? {
        guard let target = scrubTargetSec, durationSec > 0 else { return nil }
        return min(max(target / durationSec, 0), 1)
    }
}
