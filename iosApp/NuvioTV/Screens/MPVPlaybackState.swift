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
    @Published var positionSec: Double = 0 {
        didSet { positionStampedAt = ProcessInfo.processInfo.systemUptime }
    }
    /// Uptime of the last write to `positionSec`. The playhead is polled twice a second; the bar draws
    /// the time in between from this stamp (`displayPosition(at:)`) so the head and the labels move
    /// smoothly, as the system player's do.
    private(set) var positionStampedAt: TimeInterval = 0
    @Published var durationSec: Double = 0
    @Published var isPaused: Bool = false {
        didSet {
            // Playing again: the next pause shows its chrome again (F3).
            if oldValue, !isPaused, pauseChromeDismissed { pauseChromeDismissed = false }
        }
    }
    @Published var isBuffering: Bool = true
    @Published var controlsVisible: Bool = false
    /// Back hid the transport bar while paused (F3, docs/player-spec.md "Pause": Back hides the
    /// controls and does not exit): the player stays, and the next Back leaves it. Cleared by any
    /// interaction that shows the chrome again (`flashControls()`) and when playback resumes.
    @Published var pauseChromeDismissed: Bool = false

    /// Touch-surface scrubbing while paused (PLY-A3, spec gap 2): the time the scrub head points
    /// at. nil = not scrubbing. Select or Play/Pause commits one exact seek there; Back cancels.
    @Published var scrubTargetSec: Double?
    /// Where the scrub started (Back returns here — no seek was issued meanwhile).
    var scrubOriginSec: Double?
    /// Hold fast-forward / rewind rate (2×, 3×, 4×; negative = rewind); nil = normal speed
    /// (spec §6.9.4, decision D9).
    @Published var fastForwardRate: Double?
    /// Where the head is while a rewind (or a hold while paused) walks it by timer; nil otherwise.
    /// The bar shows this rather than the keyframe each seek lands on.
    var rateSeekTarget: Double?
    /// The skip hint of a ±10 s click ("+10 ›" / "‹ -10", the clicks in a row added up), drawn in the
    /// bar's state slot for as long as the bar stays up after the last click.
    @Published var skipHint: SkipHint?

    @Published var audioTracks: [PlayerTrack] = []
    @Published var subtitleTracks: [PlayerTrack] = []
    /// The Subtitles menu's "Automatic" row is the one chosen: nothing was picked by hand (or a pick
    /// was handed back to the language plan), as on the system popover's "Auto".
    @Published var subtitlesAutomatic = true
    /// The chrome's focus layer (transport menus, content tabs — `MPVTransportFocusView`) is
    /// presented over the player and owns the remote.
    @Published var panelOpen: Bool = false
    /// Addon subtitle fetch in flight — the picker shows "Searching…" instead of hiding the row.
    @Published var subtitleSearchInFlight: Bool = false

    /// Active skip prompt ("Skip Intro"/"Skip Outro") when playback is inside a known segment.
    @Published var skipPrompt: SkipPrompt? {
        didSet { if skipPrompt == nil, skipChipFocused { skipChipFocused = false } }
    }
    /// Up moved "focus" onto the skip chip (the system's contextual action is a focusable button):
    /// Select then skips, any other input hands it back. Select pauses and resumes otherwise, as on
    /// the system player — a chip that stays up for a whole intro never takes the pause away.
    @Published var skipChipFocused: Bool = false
    /// The chrome's focus layer is drawn over the player and has taken the bar's place: the passive
    /// bar underneath stays put, fully drawn, until the layer is on top of it, then steps aside
    /// without a fade (and is back, still without a fade, before the layer goes) — two fades at once
    /// made the bar dim and light up again.
    @Published var chromeCovered: Bool = false
    /// "Intro skipped": the confirmation shown for a moment after Automatic Skipping skipped a segment.
    @Published var autoSkipToast: AutoSkipToast?

    /// Playback-settings panel state (speed, subtitle/audio delay, diagnostics).
    @Published var playbackSpeed: Double = 1.0
    /// How the picture fills the screen (the transport bar's Aspect Ratio menu).
    @Published var aspectMode: PlayerAspectMode = .fit
    @Published var subtitleDelaySec: Double = 0
    @Published var audioDelaySec: Double = 0
    /// Volume boost (dB, 0 = off) and dialogue boost (dB, 0 = off) of the Audio menu, remembered
    /// between playbacks (`MPVAudioSettings`).
    @Published var audioGainDb: Int = MPVAudioSettings.current.gainDb
    @Published var dialogueBoostDb: Int = MPVAudioSettings.current.dialogueDb
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
    /// The "Automatic" row: forget the manual pick and let the language plan choose again.
    var selectAutoSubtitles: (() -> Void)?
    var setSpeed: ((Double) -> Void)?
    var setAspectMode: ((PlayerAspectMode) -> Void)?
    var setSubtitleDelay: ((Double) -> Void)?
    var setAudioDelay: ((Double) -> Void)?
    var setAudioGain: ((Int) -> Void)?
    var setDialogueBoost: ((Int) -> Void)?
    var replay: (() -> Void)?
    var reclaimFocus: (() -> Void)?
    /// Play/Pause as the remote answers it (scrub commit, scan stop, toggle): the chrome's focus layer
    /// calls it for a Play/Pause press while focus sits in the bar or in a tab.
    var togglePlayPause: (() -> Void)?
    /// Exact seek to an absolute time (the Chapters tab).
    var seekTo: ((Double) -> Void)?
    /// Start Over (PLY-A13, the transport bar): back to 0:00, dropping any resume still pending.
    var startOver: (() -> Void)?
    /// Engine switch: write the playing audio and subtitle tracks to the title's track memory, so the
    /// other engine opens on them.
    var rememberTracks: (() -> Void)?

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
    var upNextSkipCredits: ((Double, Bool) -> Bool)?
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

    /// The pause chrome belongs on screen: paused mid-file, and Back hasn't put it away (F3). It is
    /// the transport bar alone — the system player has no centred pause glyph and no pause card — and
    /// it stays up until the viewer acts (docs/player-spec.md, "Pause").
    var pauseChromeShown: Bool {
        isPaused && !isEnded && !playbackErrorShown && !pauseChromeDismissed
    }

    var isScrubbing: Bool { scrubTargetSec != nil }

    /// The playhead as the bar draws it at `uptime`: the last polled position plus the time since, at the
    /// playback speed, while the picture is actually playing (a pause, a stall, a scan, a scrub and a
    /// rewind stand still or are driven by their own value). At most a second ahead of the last poll, so
    /// a stalled poll cannot run the head away, and never past the end.
    func displayPosition(at uptime: TimeInterval) -> Double {
        guard isAdvancing, positionStampedAt > 0 else {
            return positionSec
        }
        let elapsed = min(max(uptime - positionStampedAt, 0), 1)
        let advanced = positionSec + elapsed * max(playbackSpeed, 0)
        return durationSec > 0 ? min(advanced, durationSec) : advanced
    }

    /// The playhead is moving on its own (the bar's clock may run).
    var isAdvancing: Bool {
        !isPaused && !isBuffering && !isEnded && !isScrubbing && fastForwardRate == nil
    }

    func displayFraction(at uptime: TimeInterval) -> Double {
        durationSec > 0 ? min(max(displayPosition(at: uptime) / durationSec, 0), 1) : 0
    }

    /// Scrub head position on the progress bar (0…1), nil when not scrubbing.
    var scrubFraction: Double? {
        guard let target = scrubTargetSec, durationSec > 0 else { return nil }
        return min(max(target / durationSec, 0), 1)
    }
}

/// The system player's skip hint for a click on the left / right edge ("+10 ›", mirrored for back):
/// which side, and the seconds skipped by the clicks in a row. A new `id` per click.
struct SkipHint: Equatable {
    let id: Int
    /// -1 = back, 1 = forward.
    let direction: Int
    let seconds: Int
}
