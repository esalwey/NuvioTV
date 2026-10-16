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
            // Playing again: the next pause shows its chrome again (F3), after its own delay.
            if oldValue, !isPaused {
                if pauseChromeDismissed { pauseChromeDismissed = false }
                if pauseChromeRevealed { pauseChromeRevealed = false }
            }
        }
    }
    /// The chrome of the current pause has come in. The picture freezes at once; the chrome follows
    /// `PlayerSpec.Chrome.pauseRevealDelaySec` later when it was away (the controller arms it), at
    /// once when it was already up.
    @Published var pauseChromeRevealed: Bool = false
    /// How the chrome's parts fade in this time: the cascade after a pause, or the quick one of every
    /// other way the chrome comes back (`PlayerSpec.Chrome`).
    @Published var chromeCascade: MPVChromeCascade = .show
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
    /// A finger rests on the touch surface (the controller's `touchesBegan` / `touchesEnded`).
    @Published var fingerDown: Bool = false
    /// The knob is drawn on the playhead: a finger has rested on a paused player for
    /// `PlayerSpec.Scrub.knobDelaySec` without swiping.
    @Published var knobShown: Bool = false
    /// A finger touched the paused player: the chrome is the bar alone (its title, buttons and pills
    /// faded out) until the scrub is committed or cancelled, as on the system player.
    @Published var scrubChrome: Bool = false
    /// The bar alone, brought up by a ±10 s click while the chrome was away (it hides
    /// `PlayerSpec.Chrome.skimLifetime` after the last click, and shows no clock pill).
    @Published var skimVisible: Bool = false
    /// The bar's fill is the pale lavender it takes after a skip click (it is white until then).
    @Published var barTinted: Bool = false
    /// A hold on an edge (rewind or fast-forward): the head runs by its own clock while the picture
    /// stays frozen on the frame it stopped on (`MPVScan`); nil = no hold.
    @Published var scan: MPVScan?
    /// After a hold's release the seek is still out: the bar shows a spinner on the badge's side
    /// (-1 left, 1 right) until the picture has arrived.
    @Published var seekSettleDirection: Double?
    /// The skip glyph of a ±10 s click, drawn beside the elapsed time for
    /// `PlayerSpec.Skip.glyphLifetimeSec` after the click.
    @Published var skipHint: SkipHint?
    /// "Subtitles on for N seconds": what the system draws under the remaining time while the
    /// subtitles a back skip turned on are up. nil = no hint.
    @Published var subtitleHint: Int?

    @Published var audioTracks: [PlayerTrack] = []
    @Published var subtitleTracks: [PlayerTrack] = []
    /// The Subtitles menu's "Automatic" row is the one chosen: nothing was picked by hand (or a pick
    /// was handed back to the language plan), as on the system popover's "Auto".
    @Published var subtitlesAutomatic = true
    /// The chrome's focus layer (transport menus, content tabs — `MPVTransportFocusView`) is
    /// presented over the player and owns the remote.
    @Published var panelOpen: Bool = false
    /// The focus layer shows the content tabs' view (pills and panel, no transport bar): the captions
    /// ride above it.
    @Published var tabViewOpen: Bool = false
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

    /// The pause chrome belongs on screen: paused mid-file, its reveal delay is over, and Back hasn't
    /// put it away (F3). It is the transport bar alone — the system player has no centred pause glyph
    /// and no pause card — and it stays up until the viewer acts (docs/player-spec.md, "Pause").
    var pauseChromeShown: Bool {
        isPaused && pauseChromeRevealed && !isEnded && !playbackErrorShown && !pauseChromeDismissed
    }

    var isScrubbing: Bool { scrubTargetSec != nil }

    /// The playhead as the bar draws it at `uptime`: the last polled position plus the time since, at the
    /// playback speed, while the picture is actually playing (a pause, a stall and a scrub stand still);
    /// during a hold, where the hold's own clock has put it. At most a second ahead of the last poll, so
    /// a stalled poll cannot run the head away, and never past the end.
    func displayPosition(at uptime: TimeInterval) -> Double {
        if let scan { return scan.position(at: uptime) }
        guard isAdvancing, positionStampedAt > 0 else {
            return positionSec
        }
        let elapsed = min(max(uptime - positionStampedAt, 0), 1)
        let advanced = positionSec + elapsed * max(playbackSpeed, 0)
        return durationSec > 0 ? min(advanced, durationSec) : advanced
    }

    /// The playhead is moving on its own (the bar's clock may run).
    var isAdvancing: Bool {
        !isPaused && !isBuffering && !isEnded && !isScrubbing && scan == nil
    }

    /// What the slot beside the elapsed time shows at `uptime`, in the order the system bar gives it:
    /// the spinner of a hold's seek, the hold's badge, the skip glyph of a click, the pause glyph.
    /// The pause glyph is away while a finger rests on the surface (the knob) and while the head is
    /// scrubbed, and comes back when neither is left (6.083 s, and never during the 12 flicks).
    func slot(at uptime: TimeInterval) -> MPVBarSlot? {
        if let direction = seekSettleDirection {
            return .seeking(direction: direction < 0 ? -1 : 1)
        }
        if let scan, scan.badgeVisible(at: uptime) {
            return .scan(direction: scan.direction < 0 ? -1 : 1, digit: scan.digit(at: uptime))
        }
        if let skipHint {
            return .skip(direction: skipHint.direction, id: skipHint.id)
        }
        if isPaused, scan == nil, !isScrubbing, !knobShown {
            return .pause
        }
        return nil
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

/// The system player's skip glyph for a click on the left / right edge (the circular arrow with the
/// seconds in it, on the right of the elapsed time for a forward click and on its left for a back
/// one): which side, and how many seconds that click skipped. A new `id` per click.
struct SkipHint: Equatable {
    let id: Int
    /// -1 = back, 1 = forward.
    let direction: Int
    let seconds: Int
}

/// How far the captions ride up: with the transport chrome, or with the content tabs' view.
enum MPVSubtitleLift: Equatable {
    case none
    case chrome
    case tabs
}

/// How the chrome's parts fade in: after a pause, or in the quick cascade of every other way the
/// chrome returns (a commit, a touch while playing, Play) — `PlayerSpec.Chrome`.
enum MPVChromeCascade: Equatable {
    case show
    case pause
}

/// What fills the slot beside the elapsed time (`MPVPlaybackState.slot(at:)`).
enum MPVBarSlot: Equatable {
    case pause
    case skip(direction: Int, id: Int)
    case scan(direction: Int, digit: Int?)
    case seeking(direction: Int)

    /// -1 = the slot hangs off the left of the elapsed time, 1 = off its right. The skip glyph, the
    /// hold's badge and its spinner lead the way the head is going; the pause glyph is on the right.
    var side: Int {
        switch self {
        case .pause: return 1
        case .skip(let direction, _): return direction
        case .scan(let direction, _): return direction
        case .seeking(let direction): return direction
        }
    }
}

/// A hold on a left / right edge, as the system player runs it: the picture freezes on the frame it
/// stopped on, the head runs by its own clock in three tiers (8, 24 then 48 media seconds per second,
/// each lasting 2.4 s from the freeze) and a bare digit joins the badge from the second tier on. The
/// release seeks to wherever the head got to (`PlayerSpec.Remote`).
struct MPVScan: Equatable {
    /// -1 = rewind, 1 = fast-forward.
    let direction: Double
    /// Where the head was when the picture froze.
    let startPosition: Double
    /// `ProcessInfo.systemUptime` of the freeze.
    let startUptime: TimeInterval
    /// The file's length (0 = unknown): the head stops short of the end.
    let duration: Double

    func elapsed(at uptime: TimeInterval) -> TimeInterval {
        max(uptime - startUptime, 0)
    }

    /// The tier (1, 2 or 3) the hold is in `uptime`.
    func tier(at uptime: TimeInterval) -> Int {
        let tiers = PlayerSpec.Remote.scanRates.count
        let step = Int(elapsed(at: uptime) / PlayerSpec.Remote.scanTierSec)
        return min(step + 1, tiers)
    }

    /// The digit beside the badge: none in the first tier, then the tier's number.
    func digit(at uptime: TimeInterval) -> Int? {
        PlayerSpec.Remote.scanDigits[tier(at: uptime) - 1]
    }

    /// The badge's glyph appears a moment after the picture freezes.
    func badgeVisible(at uptime: TimeInterval) -> Bool {
        elapsed(at: uptime) >= PlayerSpec.Remote.scanBadgeDelaySec
    }

    /// Where the head is at `uptime`: the freeze position plus the distance the tiers have run, kept
    /// inside the file.
    func position(at uptime: TimeInterval) -> Double {
        let raw = startPosition + direction * Self.distance(atElapsed: elapsed(at: uptime))
        let upper = duration > 0 ? max(duration - PlayerSpec.Remote.scanEndMarginSec, 0) : raw
        return min(max(raw, 0), max(upper, 0))
    }

    /// How fast the head runs `elapsed` seconds after the freeze (media seconds per second): still
    /// for the start delay, then the first tier's rate, and a short ramp to each next tier's.
    static func rate(atElapsed elapsed: TimeInterval) -> Double {
        interpolated(knots, at: elapsed)
    }

    /// The distance the head has run `elapsed` seconds after the freeze (media seconds).
    static func distance(atElapsed elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        var area = 0.0
        for index in 0..<(knots.count - 1) {
            let a = knots[index], b = knots[index + 1]
            if elapsed <= a.t { break }
            guard b.t > a.t else { continue }
            let end = min(elapsed, b.t)
            let rateAtEnd = a.r + (b.r - a.r) * (end - a.t) / (b.t - a.t)
            area += (end - a.t) * (a.r + rateAtEnd) / 2
        }
        if let last = knots.last, elapsed > last.t {
            area += (elapsed - last.t) * last.r
        }
        return area
    }

    /// Breakpoints of the rate: (elapsed, rate). Tier changes ramp over `scanRampSec`.
    private static let knots: [(t: Double, r: Double)] = {
        let rates = PlayerSpec.Remote.scanRates
        let start = PlayerSpec.Remote.scanStartDelaySec
        let tier = PlayerSpec.Remote.scanTierSec
        let ramp = PlayerSpec.Remote.scanRampSec
        var points: [(t: Double, r: Double)] = [(0, 0), (start, 0), (start, rates[0])]
        for index in 1..<rates.count {
            points.append((tier * Double(index), rates[index - 1]))
            points.append((tier * Double(index) + ramp, rates[index]))
        }
        return points
    }()

    private static func interpolated(_ points: [(t: Double, r: Double)], at time: Double) -> Double {
        guard let first = points.first, time > first.t else { return 0 }
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            if time < b.t, b.t > a.t, time >= a.t {
                return a.r + (b.r - a.r) * (time - a.t) / (b.t - a.t)
            }
        }
        return points.last?.r ?? 0
    }
}
