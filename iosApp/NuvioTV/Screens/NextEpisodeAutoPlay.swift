import AVFAudio
import Combine
import Foundation
import SwiftUI
import UIKit
import SharedCore

// MARK: - Up Next preferences

/// Where the Up Next card appears when the credits timing is unknown: a fixed lead before the end
/// of the file, or a fraction of the file (a percentage threshold synced from the phone).
enum UpNextThreshold: Equatable {
    case secondsBeforeEnd(Double)
    case percent(Double)
}

/// tvOS Up Next settings (Settings → Playback → Next Episode).
///
/// Sync policy — every row is DEVICE-LOCAL (`UserDefaults`, `PlayerTuning.upNext*` keys, the same
/// pattern as the other player tuning rows); the TV never writes a profile-synced setting from here:
///  - "Autoplay Next Episode", "Start at the Credits", "Countdown" and "Ask Still Watching?": the
///    phone's synced `streamAutoPlayNextEpisodeEnabled` defaults to OFF, and writing it from the TV
///    would flip the phone's behaviour through profile sync, so tvOS keeps its own switch (default
///    ON, lean-back binge) and neither reads nor writes the shared one.
///  - "Before the End" (15/30/45/60 s) is this Apple TV's own too: the shared next-episode threshold
///    (`PlayerSettingsRepository.nextEpisodeThreshold*`) is edited on the phone on a 0.5-minute
///    grid, so 15/45 s can't be represented there, and writing it would also switch the phone from
///    its percentage mode. Until a value is picked on this TV, a threshold the profile stored (set
///    on the phone) is honoured as-is — including a percentage, without the old 97 % clamp — and a
///    profile that never stored one uses 30 s.
enum UpNextPreferences {
    /// Countdown lengths offered (build 138 feedback: 10 s felt too long — 5 s is the default, and
    /// "Off" is the "Autoplay Next Episode" switch above the row).
    static let countdownOptions = [5, 10, 15]
    static let secondsBeforeEndOptions = [15, 30, 45, 60]
    static let defaultCountdownSec = 5
    static let defaultSecondsBeforeEnd = 30

    static var autoplayEnabled: Bool { bool(PlayerTuning.upNextAutoplayKey, fallback: true) }
    static var useCredits: Bool { bool(PlayerTuning.upNextUseCreditsKey, fallback: true) }
    /// ON by default (build 138 feedback: with the TV switched off, the Apple TV kept playing
    /// episode after episode on its own).
    static var askStillWatching: Bool { bool(PlayerTuning.upNextStillWatchingKey, fallback: true) }
    /// The stored countdown, snapped to the offered lengths (a 20 s picked before they changed reads
    /// as 15 s); never picked = the 5 s default.
    static var countdownSec: Int {
        let stored = UserDefaults.standard.integer(forKey: PlayerTuning.upNextCountdownKey)
        guard stored > 0 else { return defaultCountdownSec }
        if countdownOptions.contains(stored) { return stored }
        return countdownOptions.last(where: { $0 <= stored }) ?? defaultCountdownSec
    }
    /// "Before the End" as picked on this Apple TV (nil = never picked here).
    static var localSecondsBeforeEnd: Int? {
        let stored = UserDefaults.standard.integer(forKey: PlayerTuning.upNextSecondsBeforeEndKey)
        return secondsBeforeEndOptions.contains(stored) ? stored : nil
    }

    static func setAutoplayEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PlayerTuning.upNextAutoplayKey)
    }

    static func setUseCredits(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PlayerTuning.upNextUseCreditsKey)
    }

    static func setAskStillWatching(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PlayerTuning.upNextStillWatchingKey)
    }

    static func setCountdownSec(_ seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: PlayerTuning.upNextCountdownKey)
    }

    /// "Before the End" picked on this Apple TV (device-local — see the sync policy above).
    static func setSecondsBeforeEnd(_ seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: PlayerTuning.upNextSecondsBeforeEndKey)
    }

    /// The effective fallback threshold: this TV's pick, else the profile's stored threshold, else 30 s.
    static func threshold(settings: PlayerSettingsUiState?) -> UpNextThreshold {
        if let local = localSecondsBeforeEnd { return .secondsBeforeEnd(Double(local)) }
        guard let settings, hasStoredThreshold(settings: settings) else {
            return .secondsBeforeEnd(Double(defaultSecondsBeforeEnd))
        }
        if settings.nextEpisodeThresholdMode == NextEpisodeThresholdMode.minutesBeforeEnd {
            let seconds = Double(settings.nextEpisodeThresholdMinutesBeforeEnd) * 60
            return .secondsBeforeEnd(min(max(seconds, UpNextTrigger.minimumLeadSec), 600))
        }
        return .percent(min(max(Double(settings.nextEpisodeThresholdPercent), 50), 99.9))
    }

    /// True once the profile stored a threshold of its own (set on the phone, synced). The shared UI
    /// state can't tell a stored 99 % from the untouched default, so this peeks at the
    /// profile-scoped storage the repository loads from.
    static func hasStoredThreshold(settings: PlayerSettingsUiState) -> Bool {
        if PlayerSettingsStorage.shared.loadNextEpisodeThresholdMode() != nil { return true }
        // No stored mode = the shared default mode (percentage); a stored percent alone is explicit.
        return settings.nextEpisodeThresholdMode == NextEpisodeThresholdMode.percentage
            && PlayerSettingsStorage.shared.loadNextEpisodeThresholdPercent() != nil
    }

    private static func bool(_ key: String, fallback: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? fallback
    }
}

// MARK: - Audio output lost (the TV or the receiver switched off)

/// `AVAudioSession.routeChangeNotification` with `.oldDeviceUnavailable` is how the app learns that
/// the TV or the receiver went away while the Apple TV stays awake (build 138 feedback: playback ran
/// on, episode after episode, in front of a switched-off TV). The same reason can also come with a
/// momentary HDMI re-sync — the TV switching display mode for frame-rate matching — so the loss only
/// counts if, a moment later, the route still has none of the outputs it lost. Used by both engines
/// (pause) and by `NextEpisodeEngine` (no automatic next episode without a press).
nonisolated enum AudioOutputLoss {
    static let settleDelaySec: TimeInterval = 2

    /// Call from a route-change observer, any queue. `onLost` runs on the main actor.
    static func handle(_ note: Notification, onLost: @escaping @MainActor @Sendable () -> Void) {
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
        guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let lostPorts = Set((previous?.outputs ?? []).map(\.portType))
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelaySec) {
            let current = Set(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType))
            // Back on the same kind of output: a re-sync, not a switched-off TV.
            if !lostPorts.isEmpty, !current.isDisjoint(with: lostPorts) { return }
            MainActor.assumeIsolated { onLost() }
        }
    }
}

// MARK: - Trigger timing (pure — covered by NuvioTVTests/UpNextTriggerTests)

/// When the Up Next card appears. Swift port of mobile's `PlayerNextEpisodeRules
/// .shouldShowNextEpisodeCard`, including upstream 77ce8a733 (post-credits scenes):
///  - credits (outro/ED) timing known, and the credits run to the end of the file → the card
///    appears when the credits START;
///  - credits known but followed by more than `postCreditsGapSec` of content (a post-credits scene,
///    a preview) → that content plays first: the card appears only for the last countdown seconds,
///    so the hand-off lands at the end of the file instead of over the scene;
///  - no credits timing (or "Start at the Credits" off) → the settings threshold ("N seconds before
///    the end", or a synced percentage — no 97 % clamp any more).
enum UpNextTrigger {
    enum Anchor: Equatable {
        case credits
        case afterCredits
        case beforeEnd
    }

    struct Timing: Equatable {
        /// Playback position (seconds) at which the card appears.
        let cardAtSec: Double
        let anchor: Anchor
    }

    /// Segment types that mark the credits (the shared repository maps AniSkip/Anime-Skip/IntroDB
    /// endings onto these).
    static let outroTypes: Set<String> = ["outro", "ed", "mixed-ed", "credits", "ending"]
    /// Upstream `POST_CREDITS_GAP_MS`: more content than this after the credits is a scene.
    static let postCreditsGapSec: Double = 5
    /// Shared `isShortPlaceholderDuration`: shorter files are error/placeholder clips, never episodes
    /// — unless the episode's own metadata says it is that short (see `isPlaceholder`).
    static let minimumContentSec: Double = 121
    /// Metadata runtimes up to this long mark a genuinely short episode (anime shorts, web series).
    static let shortEpisodeRuntimeSec: Double = 180
    /// An end of file this close to the duration (or 3 % of it, if more) is the episode's real end.
    static let naturalEndMarginSec: Double = 15
    /// The card never appears later than this before the end of the file.
    static let minimumLeadSec: Double = 5
    /// The next episode's stream search starts this long before the card, so the source is usually
    /// ready when the card appears.
    static let prefetchLeadSec: Double = 30

    /// A file shorter than `minimumContentSec` is an error/placeholder clip (debrid stub, "not
    /// cached" video) — never chained into the next episode — unless the episode's metadata runtime
    /// says the episode itself is that short. Unknown runtime keeps the shared placeholder rule.
    static func isPlaceholder(durationSec: Double, expectedRuntimeSec: Double?) -> Bool {
        guard durationSec.isFinite, durationSec > 0, durationSec < minimumContentSec else { return false }
        if let expected = expectedRuntimeSec, expected > 0, expected <= shortEpisodeRuntimeSec { return false }
        return true
    }

    /// End of file at (or within the margin of) the duration: the episode really finished. A stream
    /// that dropped or expired mid-way also reaches "end of file", but well short of the duration —
    /// that must not count as watched, nor chain into the next episode.
    static func isNaturalEnd(positionSec: Double, durationSec: Double) -> Bool {
        guard durationSec.isFinite, durationSec > 0, positionSec.isFinite else { return false }
        return positionSec >= durationSec - max(naturalEndMarginSec, durationSec * 0.03)
    }

    static func timing(
        durationSec: Double,
        segments: [SkipSegment],
        useCredits: Bool,
        threshold: UpNextThreshold,
        countdownSec: Double,
        expectedRuntimeSec: Double? = nil
    ) -> Timing? {
        guard durationSec.isFinite, durationSec > 0,
              !isPlaceholder(durationSec: durationSec, expectedRuntimeSec: expectedRuntimeSec) else { return nil }
        if useCredits, let credits = creditsTiming(durationSec: durationSec, segments: segments,
                                                    countdownSec: countdownSec) {
            return credits
        }
        let lead: Double
        switch threshold {
        case .secondsBeforeEnd(let seconds): lead = seconds
        case .percent(let percent): lead = durationSec * (1 - percent / 100)
        }
        return Timing(cardAtSec: max(0, durationSec - max(lead, minimumLeadSec)), anchor: .beforeEnd)
    }

    private static func creditsTiming(durationSec: Double, segments: [SkipSegment],
                                      countdownSec: Double) -> Timing? {
        // Credits that start in the first half of the file are bad data for this purpose (a
        // mis-tagged opening) — ignore them rather than pop the card mid-episode.
        let outros = segments.filter { segment in
            outroTypes.contains(segment.type.lowercased())
                && segment.start.isFinite
                && segment.end > segment.start
                && segment.start >= durationSec * 0.5
                && segment.start < durationSec
        }
        guard let start = outros.map(\.start).min(), let rawEnd = outros.map(\.end).max() else { return nil }
        let end = min(rawEnd, durationSec)
        if durationSec - end > postCreditsGapSec {
            return Timing(cardAtSec: max(end, durationSec - max(countdownSec, minimumLeadSec)),
                          anchor: .afterCredits)
        }
        return Timing(cardAtSec: start, anchor: .credits)
    }
}

// MARK: - Engine

/// Next-episode autoplay orchestration for the tvOS player (both engines).
///
/// Swift port of mobile's `PlayerNextEpisodeAutoPlay` on the shared pieces:
///  - next-episode resolution over the series episode list (aired episodes only; fetched from the
///    shared meta cache when the launch path had none — NE-8/CW-4),
///  - card timing from `UpNextTrigger` (credits segments, post-credits scenes, settings threshold),
///  - stream resolution via shared `PlayerStreamsRepository.loadEpisodeStreams`, started
///    `UpNextTrigger.prefetchLeadSec` BEFORE the card so the source is ready when it appears,
///  - stream choice via shared `StreamAutoPlaySelector` — the current stream's binge group is a
///    PREFERENCE: no match falls back to the first playable stream unless the user explicitly
///    turned "Fallback when binge group fails" off (NE-1),
///  - a visible, configurable countdown that pauses with the video (and while the top panel is
///    open), then an automatic hand-off to the presenter (`onPlayNext`) with no press. OK or Down
///    while the card is up plays at once; Menu dismisses the card and keeps the credits playing.
///
/// One engine per `PlayerScreen` (per episode), shared by the native and mpv screens so a
/// native → mpv fallback keeps the Up Next state (NE-7). It stays alive under the end screen's
/// cover (the player screens report disappearing there): its own terminal paths — cancel, choose a
/// source, hand-off — release what it observes, and `deinit` catches the rest.
@MainActor
final class NextEpisodeEngine: ObservableObject {
    enum Phase: Equatable {
        /// No card on screen.
        case hidden
        /// Up Next card on screen: countdown running, or run out and waiting on the source.
        case upNext
        /// The countdown ended into the optional "Still watching?" gate.
        case stillWatching
        /// The search finished without a playable stream for the next episode.
        case noStream
    }

    /// End-of-playback screen, when the file ended without a pending hand-off.
    enum EndScreen: Equatable {
        /// Next episode known: "Next Episode" is the default action.
        case nextEpisode
        /// No stream could be auto-selected for it: "Choose a Source" is the default action.
        case chooseSource
    }

    enum EndOutcome: Equatable {
        /// The engine owns the end of playback (hand-off, card, or end screen).
        case handled
        /// Nothing to continue with (movie, series finale, no presenter): leave the player.
        case exit
    }

    /// Consecutive episodes started WITHOUT any remote interaction. Any remote press resets it
    /// (mpv `pressesBegan`, the native host's interaction recognizer), as does a manual stream pick
    /// in `StreamPickerView`. With "Ask Still watching?" on, the countdown that would start the
    /// `stillWatchingThreshold`-th unattended episode ends in a prompt instead.
    static var consecutiveAutoPlays = 0 {
        // Someone touched the remote (or picked a stream): the confirmation the system asked for
        // after the app left the foreground is answered too.
        didSet { if consecutiveAutoPlays == 0 { autoplayNeedsConfirmation = false } }
    }
    static let stillWatchingThreshold = 3
    /// The app left the foreground (sleep, the TV button, HDMI-CEC power off putting the Apple TV to
    /// sleep) or the TV's audio output went away: the next automatic hand-off asks "Still
    /// watching?" whatever the setting, until a remote press shows someone is there.
    private static var autoplayNeedsConfirmation = false
    /// The context the last automatic hand-off created. A session that starts with any other context
    /// was started by the viewer (stream picker, Continue Watching, a deep link): a new run.
    private static var lastAutomaticHandOffContextId: String?
    /// A position jump backwards larger than this while the card is up is a seek back.
    private static let backSeekToleranceSec: Double = 3

    @Published private(set) var phase: Phase = .hidden
    /// Seconds left on the countdown (0 once it has run out, or after Play Now).
    @Published private(set) var countdownRemaining = 0
    @Published private(set) var countdownTotal = 0
    /// The video is paused, so the countdown is too.
    @Published private(set) var countdownPaused = false
    /// The next episode's stream search (or its debrid resolve) is in flight.
    @Published private(set) var isSearching = false
    /// A playable stream for the next episode is ready.
    @Published private(set) var isStreamReady = false
    /// The hand-off happens as soon as the stream is ready (countdown over, end of file, Play Now).
    @Published private(set) var playWhenReady = false
    @Published private(set) var endScreen: EndScreen?
    @Published private(set) var nextVideo: MetaVideo?
    @Published private(set) var nextEpisodeTitle = ""
    @Published private(set) var sourceName: String?

    /// Bumped by every action the engine takes on the viewer's behalf (cancel, play now, choose a
    /// source, …). The native engine uses it to tell a plain Select from one that activated a focused
    /// contextual action — see `beginSystemSelect()`.
    private(set) var userActionSerial = 0

    /// Alternate streams for the CURRENTLY-playing video (in-player source switching).
    @Published private(set) var sources: [StreamItem] = []
    @Published private(set) var sourcesLoading = false
    private var sourcesWatcher: FlowWatcher?
    /// Identity of the current `loadSources()` request — a StateFlow replays its last value on
    /// subscribe, so late emissions from a superseded request must be dropped (ME-005).
    private var sourceLoadGeneration = 0

    // MARK: Hooks the player screens install

    /// Leave the player for the details page (cancel from the card, "Back to Details").
    var onExitRequested: (() -> Void)?
    /// Open the stream picker for the next episode ("Choose a Source").
    var onPickSourceRequested: ((MetaVideo) -> Void)?
    /// Right before a next-episode hand-off: the finished episode must be flushed as completed.
    var onWillHandOff: (() -> Void)?
    /// Right before the next episode's addon subtitles are prefetched (mpv stops side-loading
    /// the shared list into the current file).
    var onPrefetchingNextSubtitles: (() -> Void)?

    // MARK: Private state

    private let context: PlaybackContext
    private let onPlayNext: (PlaybackContext) -> Void
    private var started = false
    /// Episode list fetched after launch when the context had none (NE-8/CW-4).
    private var episodesOverride: [MetaVideo]?

    private var settings: PlayerSettingsUiState?
    private var settingsWatcher: FlowWatcher?
    private var threshold: UpNextThreshold = .secondsBeforeEnd(Double(UpNextPreferences.defaultSecondsBeforeEnd))
    // Device-local preferences, read once per session (Settings is unreachable mid-playback).
    private var autoplayEnabled = true
    private var useCredits = true
    private var countdownSeconds = UpNextPreferences.defaultCountdownSec
    private var askStillWatching = false

    private var skipSegments: [SkipSegment] = []
    private var lastPositionSec: Double?
    private var lastDurationSec: Double = 0
    private var isPaused = false
    /// The top panel (Info · Subtitles · Audio · Playback) is open: the countdown waits, and an
    /// automatic hand-off that falls due meanwhile runs once it closes.
    private var isPanelOpen = false
    /// The playing episode's runtime from its metadata (seconds), when known: tells a genuinely
    /// short episode from a short error/placeholder clip.
    private var expectedRuntimeSec: Double?
    private var ended = false
    private var cardShown = false
    private var retriedAtCard = false
    /// Back-seek while the card was up: no automatic card for the rest of this session.
    private var sessionDismissed = false
    /// `sessionDismissed` as it was before a panel jump suspended Up Next (restored if it fails).
    private var sessionDismissedBeforeJump: Bool?
    /// Cancel-and-exit / pick-source: the engine is done.
    private var cancelled = false
    /// `onPlayNext` fired.
    private var handedOff = false
    private var handOffIsAutomatic = false
    private var countdownTask: Task<Void, Never>?
    /// The app is not active (between `willResignActive` and `didBecomeActive`): the countdown
    /// stands still and no hand-off replaces the player — nothing starts an episode off screen.
    private var systemSuspended = false
    /// App-lifecycle and audio-route observers (`observeSystemLifecycle`).
    private var lifecycleObservers: [NSObjectProtocol] = []

    private struct SearchTarget {
        let video: MetaVideo
        /// A manual jump from the player panel: plays at once, never the Up Next flow.
        let isJump: Bool
    }
    private var searchTarget: SearchTarget?
    private var searchGeneration = 0
    private var searchStarted = false
    private var searchFailed = false
    private var streamsWatcher: FlowWatcher?
    private var timeoutTask: Task<Void, Never>?
    private var selectedStream: StreamItem?
    private var readyStream: StreamItem?
    private var readyURL: URL?
    /// Latest emission from `episodeStreamsState` (the exported StateFlow has no sync `.value`).
    private var latestStreamsState: StreamsUiState?

    /// Panel accessors (the playback-settings panel renders episode/source sections from these).
    var episodes: [MetaVideo] { episodesOverride ?? context.episodes }
    /// Exposed for the player's episode jump list (watched-badge lookups).
    var parentMetaId: String { context.parentMetaId }
    var contentType: String { context.contentType }
    var currentSeason: Int? { context.season }
    var currentEpisode: Int? { context.episode }
    var currentUrlString: String { context.url.absoluteString }

    /// The Up Next card is on screen.
    var isCardVisible: Bool { phase != .hidden }
    /// The countdown is over (or Play Now was pressed) and the hand-off waits on the source.
    var isWaitingForSource: Bool { playWhenReady && !isStreamReady && phase == .upNext }
    /// The engine is done with this player: it cancelled (exit, choose a source) or handed off.
    var isFinished: Bool { cancelled || handedOff }
    /// The episode a manual jump (Episodes tab) is finding a stream for, while it searches — the
    /// players show it, so the jump is never silent.
    var episodeJumpInFlight: MetaVideo? {
        guard isSearching, let target = searchTarget, target.isJump else { return nil }
        return target.video
    }

    /// A file this long is a short error/placeholder clip, not the playing episode — unless its
    /// metadata runtime says the episode really is that short (mpv's error card, PLY-1).
    func isPlaceholderClip(durationSec: Double) -> Bool {
        UpNextTrigger.isPlaceholder(
            durationSec: durationSec,
            expectedRuntimeSec: expectedRuntimeSec ?? Self.runtimeSec(parsing: context.meta?.runtime)
        )
    }

    init(context: PlaybackContext, onPlayNext: @escaping (PlaybackContext) -> Void) {
        self.context = context
        self.onPlayNext = onPlayNext
    }

    deinit {
        // Normally already released by `stop()` or a terminal path; a player torn down while
        // covered (the end screen) gets no second disappearance, so nothing may outlive the engine.
        settingsWatcher?.cancel()
        sourcesWatcher?.cancel()
        streamsWatcher?.cancel()
        countdownTask?.cancel()
        timeoutTask?.cancel()
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Lifecycle

    /// Starts the orchestration. Only presenters that can swap contexts start it. Re-entrant: a
    /// `start()` after `stop()` resumes watching with the session state intact.
    func start() {
        guard !cancelled, !handedOff else { return }
        if !started {
            started = true
            // Started by the viewer rather than by the previous episode's automatic hand-off: the
            // "Still watching?" run starts over (whatever the launch path — the stream picker resets
            // it too, Continue Watching and deep links did not).
            if Self.lastAutomaticHandOffContextId != context.id { Self.consecutiveAutoPlays = 0 }
            Self.lastAutomaticHandOffContextId = nil
            autoplayEnabled = UpNextPreferences.autoplayEnabled
            useCredits = UpNextPreferences.useCredits
            countdownSeconds = UpNextPreferences.countdownSec
            askStillWatching = UpNextPreferences.askStillWatching

            PlayerSettingsRepository.shared.ensureLoaded()
            // Seeded synchronously: the watcher's first emission lands a main-queue turn later.
            settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState
            threshold = UpNextPreferences.threshold(settings: settings)

            resolveNextEpisode()
            fetchEpisodesIfNeeded()
        }
        if settingsWatcher == nil {
            settingsWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
                guard let self, let value = emitted as? PlayerSettingsUiState else { return }
                self.settings = value
                self.threshold = UpNextPreferences.threshold(settings: value)
            }
        }
        if lifecycleObservers.isEmpty {
            observeSystemLifecycle()
            // Whatever happened while nothing was observing (`stop()` removed the observers).
            systemSuspended = UIApplication.shared.applicationState == .background
        }
        // Resume what `stop()` interrupted.
        if phase == .upNext, !cancelled, !handedOff {
            if countdownRemaining > 0, countdownTask == nil {
                startCountdown(total: countdownTotal, remaining: countdownRemaining)
            }
            if let next = nextVideo { ensureSearch(for: next, retryFailed: playWhenReady) }
        }
    }

    /// Stop watching and searching. The session state survives (see `start()`): an in-flight
    /// next-episode search is simply started again when it's next needed.
    func stop() {
        removeLifecycleObservers()
        settingsWatcher?.cancel()
        settingsWatcher = nil
        sourcesWatcher?.cancel()
        sourcesWatcher = nil
        if sourcesLoading { sourcesLoading = false }
        countdownTask?.cancel()
        countdownTask = nil
        if isSearching {
            if searchTarget?.isJump == true {
                // An interrupted panel jump is abandoned: Up Next is back as the jump found it.
                searchTarget = nil
                searchStarted = false
                sessionDismissed = sessionDismissedBeforeJump ?? sessionDismissed
                sessionDismissedBeforeJump = nil
            } else {
                searchStarted = false    // the prefetch re-runs on the next position tick
            }
        }
        tearDownSearch()
    }

    /// The session is over (exit, choose a source, hand-off): drop the long-lived observers now.
    /// `stop()` normally does it when the player disappears, but a player that was already covered
    /// (the end screen) as it went away never reports a second disappearance.
    private func releaseObservers() {
        removeLifecycleObservers()
        settingsWatcher?.cancel()
        settingsWatcher = nil
        sourcesWatcher?.cancel()
        sourcesWatcher = nil
        if sourcesLoading { sourcesLoading = false }
    }

    // MARK: - Leaving the app, the TV switched off (build 138 feedback)

    /// The engine guards the hand-off itself, whichever engine plays (each also pauses its video):
    ///  - `willResignActive` → `didBecomeActive`: the countdown stands still and no hand-off runs;
    ///  - `didEnterBackground` (sleep — including HDMI-CEC switching the Apple TV off with the TV —
    ///    the TV button's app switch, the screensaver) and the audio output going away (the TV or
    ///    receiver switched off): a countdown on screen turns into "Still watching?", and the next
    ///    automatic hand-off asks first, until a remote press shows someone is there.
    private func observeSystemLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemSuspended = true }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemSuspended = true
                    self?.requireConfirmationBeforeAutoplay(reason: "app in the background")
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidBecomeActive() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                AudioOutputLoss.handle(note) { [weak self] in
                    self?.requireConfirmationBeforeAutoplay(reason: "audio output lost")
                }
            },
        ]
    }

    private func removeLifecycleObservers() {
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers.removeAll()
    }

    private func systemDidBecomeActive() {
        guard systemSuspended else { return }
        systemSuspended = false
        // A hand-off the viewer asked for (Play Now, a jump) that fell due meanwhile runs now.
        evaluateHandOff()
    }

    /// Nobody may be watching any more: an automatic countdown on screen becomes "Still watching?"
    /// (a hand-off the viewer asked for stays theirs), and the next automatic one asks first.
    private func requireConfirmationBeforeAutoplay(reason: String) {
        Self.autoplayNeedsConfirmation = true
        guard started, !cancelled, !handedOff, phase == .upNext,
              countdownTask != nil || (playWhenReady && handOffIsAutomatic) else { return }
        print("[UpNext] \(reason) — the countdown waits for \u{201C}Still watching?\u{201D}")
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = 0
        playWhenReady = false
        handOffIsAutomatic = false
        phase = .stillWatching
    }

    /// The countdown ran out (or the file ended under the card) without a press: the automatic
    /// hand-off asks "Still watching?" first — the Nth unattended episode with the setting on
    /// (Android TV parity), or always after the app left the foreground or lost its audio output.
    private var mustConfirmAutoplay: Bool {
        if Self.autoplayNeedsConfirmation || systemSuspended { return true }
        if UIApplication.shared.applicationState == .background { return true }
        return askStillWatching && Self.consecutiveAutoPlays >= Self.stillWatchingThreshold - 1
    }

    /// A player engine (re)attached (native → mpv fallback): forget the last position so the new
    /// engine's first ticks aren't mistaken for a seek back.
    func playerAttached() {
        lastPositionSec = nil
    }

    // MARK: - Next-episode resolution

    private func resolveNextEpisode() {
        let next = Self.resolveNextAiredEpisode(
            episodes: episodes,
            currentSeason: context.season,
            currentEpisode: context.episode
        )
        nextVideo = next
        nextEpisodeTitle = next.map { Self.episodeTitle($0) } ?? ""
        // The playing episode's own runtime first, else the title-level one ("24 min").
        let current = episodes.first { video in
            guard let s = video.season?.value, let e = video.episode?.value else { return false }
            return s == context.season && e == context.episode
        }
        if let minutes = current?.runtime?.value, minutes > 0 {
            expectedRuntimeSec = Double(minutes) * 60
        } else {
            expectedRuntimeSec = Self.runtimeSec(parsing: context.meta?.runtime)
        }
    }

    /// Launch paths that picked a stream before the episode list arrived (Home continue watching,
    /// deep links) — fetch it here (cache-first) so autoplay still works for the session.
    private func fetchEpisodesIfNeeded() {
        guard context.episodes.isEmpty, context.season != nil, context.episode != nil,
              ["series", "tv", "show", "tvshow"].contains(context.contentType.lowercased()) else { return }
        MetaDetailsRepository.shared.fetch(type: context.contentType, id: context.parentMetaId, cacheResult: true) { [weak self] details, _ in
            let videos = details?.videos ?? []
            guard !videos.isEmpty else { return }
            // Suspend completions can land off-main; hop before touching engine state.
            DispatchQueue.main.async {
                guard let self, !self.cancelled, !self.handedOff, self.episodesOverride == nil else { return }
                self.episodesOverride = videos
                self.resolveNextEpisode()
            }
        }
    }

    // MARK: - Player inputs

    /// Intro/recap/outro segments for the playing episode (credits-aware card timing).
    func setSkipSegments(_ segments: [SkipSegment]) {
        skipSegments = segments
    }

    /// The video paused/resumed: the countdown pauses with it (never after the end of the file).
    func setPaused(_ paused: Bool) {
        let resumed = isPaused && !paused
        isPaused = paused
        let frozen = paused && !ended
        if countdownPaused != frozen { countdownPaused = frozen }
        // An automatic hand-off held by the pause (`evaluateHandOff`) runs once playback resumes.
        if resumed { evaluateHandOff() }
    }

    /// The top panel opened/closed. While it is up the countdown waits, and an automatic hand-off
    /// is held (it would replace the player under the panel); one that fell due runs on close.
    func setPanelOpen(_ open: Bool) {
        guard isPanelOpen != open else { return }
        isPanelOpen = open
        if !open { evaluateHandOff() }
    }

    /// Called on every player position tick.
    func onProgress(positionSec: Double, durationSec: Double) {
        guard started, !cancelled, !handedOff, positionSec.isFinite, durationSec.isFinite, durationSec > 0 else { return }
        let previous = lastPositionSec
        lastPositionSec = positionSec
        lastDurationSec = durationSec
        // A seek back while the card is up means "I'm still watching this one": drop the card
        // for the rest of the session (the end screen still offers the next episode).
        if let previous, positionSec > 1, positionSec + Self.backSeekToleranceSec < previous, phase != .hidden {
            dismissForSession()
            return
        }
        guard !ended, !sessionDismissed, autoplayEnabled, searchTarget?.isJump != true,
              let next = nextVideo,
              let timing = UpNextTrigger.timing(
                  durationSec: durationSec,
                  segments: skipSegments,
                  useCredits: useCredits,
                  threshold: threshold,
                  countdownSec: Double(countdownSeconds),
                  expectedRuntimeSec: expectedRuntimeSec
              )
        else { return }

        if !searchStarted, positionSec >= timing.cardAtSec - UpNextTrigger.prefetchLeadSec {
            beginSearch(for: SearchTarget(video: next, isJump: false))
        }
        if !cardShown, positionSec >= timing.cardAtSec {
            showCard(next: next, positionSec: positionSec, durationSec: durationSec)
        }
    }

    /// The file reached its end. `natural` is false when it stopped well short of its duration (a
    /// dropped or expired stream — `UpNextTrigger.isNaturalEnd`): that is not a watched episode.
    @discardableResult
    func playbackDidEnd(natural: Bool = true) -> EndOutcome {
        if !ended {
            ended = true
            if countdownPaused { countdownPaused = false }
        }
        guard started else { return .exit }
        guard !cancelled, !handedOff else { return .handled }
        if searchTarget?.isJump == true { return .handled }   // a panel jump plays when resolved
        guard let next = nextVideo else { return .exit }

        // Cut short with no card up: never chain into the next episode over it — the end screen
        // offers the next episode (and Back to Details, where the saved position resumes). With the
        // card up the episode itself was already over (credits / final lead): carry on below.
        if !natural && phase == .hidden {
            playWhenReady = false
            endScreen = searchFailed ? .chooseSource : .nextEpisode
            return .handled
        }

        switch phase {
        case .stillWatching:
            return .handled   // waits for an answer on the last frame
        case .noStream:
            phase = .hidden
            endScreen = .chooseSource
            return .handled
        case .upNext:
            // End of file cuts the countdown short: hand off now when the stream is ready,
            // otherwise the card keeps "Finding a source…" and the hand-off follows the source.
            countdownTask?.cancel()
            countdownTask = nil
            countdownRemaining = 0
            if !playWhenReady {
                // The file outran the countdown — the countdown running out all the same, "Still
                // watching?" included. (After Play Now the hand-off is the viewer's, not automatic.)
                if mustConfirmAutoplay {
                    phase = .stillWatching
                    return .handled
                }
                handOffIsAutomatic = true
                playWhenReady = true
            }
            ensureSearch(for: next, retryFailed: false)
            evaluateHandOff()
            return .handled
        case .hidden:
            break
        }

        // A short error/placeholder clip (debrid stub, "not cached" video) is not a watched episode:
        // never chain into the next one automatically — offer it on the end screen instead.
        let placeholderClip = UpNextTrigger.isPlaceholder(durationSec: lastDurationSec,
                                                          expectedRuntimeSec: expectedRuntimeSec)
        if autoplayEnabled && !sessionDismissed && !placeholderClip {
            // The file ended before the card fired (a seek into the tail, a tail shorter than the
            // lead, or a duration the trigger never saw): run the card now, straight to the hand-off.
            cardShown = true
            ensureSearch(for: next, retryFailed: true)
            countdownTotal = countdownSeconds
            countdownRemaining = 0
            if mustConfirmAutoplay {
                phase = .stillWatching
                return .handled
            }
            phase = .upNext
            handOffIsAutomatic = true
            playWhenReady = true
            evaluateHandOff()
            return .handled
        }

        endScreen = searchFailed ? .chooseSource : .nextEpisode
        return .handled
    }

    /// "Play Again" from the end screen: a new viewing of this episode, so Up Next re-arms fully.
    func resetForReplay() {
        guard started, !cancelled, !handedOff else { return }
        countdownTask?.cancel()
        countdownTask = nil
        ended = false
        endScreen = nil
        if phase != .hidden { phase = .hidden }
        countdownRemaining = 0
        countdownPaused = false
        cardShown = false
        retriedAtCard = false
        sessionDismissed = false
        playWhenReady = false
        lastPositionSec = nil
        // A ready stream stays valid for the next episode; a failed search gets a fresh try.
        if searchFailed {
            searchStarted = false
            searchFailed = false
        }
    }

    /// Playback left the last frame without an explicit "Play Again" (a seek back, or the system
    /// player restarting the file): only the end-of-file state clears — a card dismissed by the
    /// seek back stays dismissed for the session.
    func playbackResumedFromEnd() {
        guard started, !cancelled, !handedOff, ended else { return }
        ended = false
        endScreen = nil
        let frozen = isPaused
        if countdownPaused != frozen { countdownPaused = frozen }
    }

    /// The end screen went away by itself (Menu on its cover) — clear it so it isn't re-presented.
    func endScreenDismissedByUser() {
        endScreen = nil
    }

    // MARK: - Remote (both engines)

    /// Select/OK (PLY-A4/F5, the system's Up Next grammar). Card up → play the next episode now;
    /// no stream found → "Choose a Source". "Still watching?" → continue. Returns true when consumed.
    func handleSelect() -> Bool {
        switch phase {
        case .upNext, .stillWatching:
            return playNow()
        case .noStream:
            pickSource()
            return true
        case .hidden:
            return false
        }
    }

    /// Menu/Back (PLY-A4/F5). Card up → dismiss it for the session and keep watching the credits.
    /// At the end of the file there are no credits left to watch, and on "Still watching?" Back
    /// means "Back to Details": both still cancel and leave for the details page. Returns true when
    /// consumed.
    func handleMenu() -> Bool {
        switch phase {
        case .hidden:
            return false
        case .stillWatching:
            cancelAndExit()
            return true
        case .upNext, .noStream:
            if ended {
                cancelAndExit()
                return true
            }
            dismissForSession()
            // `dismissForSession` declined (a panel jump in flight): never leave the card stuck.
            if phase != .hidden { cancelAndExit() }
            return true
        }
    }

    /// D-pad Down. Card up → play now ("Choose a Source" when no stream was found).
    func handleDown() -> Bool {
        switch phase {
        case .upNext, .stillWatching:
            return playNow()
        case .noStream:
            pickSource()
            return true
        case .hidden:
            return false
        }
    }

    /// Native engine: a Select press reached the system player while the card may be up. The same
    /// press may be activating a focused contextual action ("Cancel", "Play Now", …), so OK's card
    /// meaning (`handleSelect`) is decided a beat later: this returns a token when the card is up
    /// (nil = nothing to do), and `resolveSystemSelect(token:)` applies it only if no card action
    /// ran in between. Not while the viewer has paused mid-file: that Select belongs to the system
    /// transport (resume, commit a scrub — say, back to rewatch the ending), and the countdown is
    /// frozen meanwhile anyway.
    func beginSystemSelect() -> Int? {
        guard started, !cancelled, !handedOff, phase != .hidden,
              !isPaused || ended || phase == .stillWatching else { return nil }
        return userActionSerial
    }

    func resolveSystemSelect(token: Int) {
        guard token == userActionSerial else { return }
        _ = handleSelect()
    }

    /// "Skip Outro" on credits that run to the end of the file: skipping them IS going to the next
    /// episode, so it plays now — instead of a seek onto the last frame, with a one-second card or a
    /// source search that only starts there. False = seek as usual (no next episode, autoplay off,
    /// Up Next dismissed for the session, a scene after the credits, or a panel jump in flight).
    @discardableResult
    func skipCreditsToNext(creditsEndSec: Double) -> Bool {
        guard started, !cancelled, !handedOff, !ended, autoplayEnabled, !sessionDismissed,
              searchTarget?.isJump != true, let next = nextVideo, lastDurationSec > 0,
              creditsEndSec >= lastDurationSec - UpNextTrigger.postCreditsGapSec else { return false }
        userActionSerial &+= 1
        Self.consecutiveAutoPlays = 0
        cardShown = true
        countdownTask?.cancel()
        countdownTask = nil
        countdownTotal = countdownSeconds
        countdownRemaining = 0
        handOffIsAutomatic = false
        playWhenReady = true
        if phase != .upNext { phase = .upNext }
        ensureSearch(for: next, retryFailed: true)
        evaluateHandOff()
        return true
    }

    /// Play the next episode now (Down, the native "Play Now" action, "Continue Watching").
    @discardableResult
    func playNow() -> Bool {
        guard started, !cancelled, !handedOff, let next = nextVideo,
              phase == .upNext || phase == .stillWatching else { return false }
        userActionSerial &+= 1
        Self.consecutiveAutoPlays = 0
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = 0
        if phase != .upNext { phase = .upNext }
        handOffIsAutomatic = false
        playWhenReady = true
        ensureSearch(for: next, retryFailed: true)
        evaluateHandOff()
        return true
    }

    /// "Next Episode" on the end screen.
    func playNextFromEndScreen() {
        guard started, !cancelled, !handedOff, let next = nextVideo else { return }
        userActionSerial &+= 1
        Self.consecutiveAutoPlays = 0
        handOffIsAutomatic = false
        playWhenReady = true
        ensureSearch(for: next, retryFailed: true)
        evaluateHandOff()
    }

    /// "Choose a Source": open the stream picker for the next episode.
    func pickSource() {
        guard !cancelled, !handedOff, let next = nextVideo else { return }
        openStreamPicker(for: next)
    }

    /// Leave the player for `video`'s stream list (else for the details page).
    private func openStreamPicker(for video: MetaVideo) {
        guard !cancelled, !handedOff else { return }
        cancelled = true
        userActionSerial &+= 1
        Self.consecutiveAutoPlays = 0
        countdownTask?.cancel()
        countdownTask = nil
        if phase != .hidden { phase = .hidden }
        tearDownSearch()
        releaseObservers()
        if let onPickSourceRequested {
            onPickSourceRequested(video)
        } else {
            onExitRequested?()
        }
    }

    /// Cancel autoplay and leave the player for the details page. The end screen (if any) is left
    /// up on purpose: it goes away with the player in one transition.
    func cancelAndExit() {
        guard !handedOff else { return }
        let first = !cancelled
        cancelled = true
        userActionSerial &+= 1
        Self.consecutiveAutoPlays = 0
        countdownTask?.cancel()
        countdownTask = nil
        if phase != .hidden { phase = .hidden }
        tearDownSearch()
        releaseObservers()
        if first { onExitRequested?() }
    }

    /// Seek back while the card is up: keep watching this episode. The card stays away for the rest
    /// of the session; a stream already found is kept for the end screen's "Next Episode".
    func dismissForSession() {
        guard started, !cancelled, !handedOff, searchTarget?.isJump != true,
              cardShown || phase != .hidden else { return }
        userActionSerial &+= 1
        sessionDismissed = true
        playWhenReady = false
        countdownTask?.cancel()
        countdownTask = nil
        if phase != .hidden { phase = .hidden }
    }

    // MARK: - Manual episode jump (player panel)

    /// Jump straight to an arbitrary episode: search its streams and play the auto-selected one
    /// immediately. Reuses the search/selection machinery without the card.
    func jumpToEpisode(_ episode: MetaVideo) {
        guard settings != nil, !cancelled, !handedOff else { return }
        userActionSerial &+= 1
        Self.consecutiveAutoPlays = 0
        countdownTask?.cancel()
        countdownTask = nil
        if phase != .hidden { phase = .hidden }
        // No Up Next card while the jump resolves; a failed jump gives the session back as it was.
        if searchTarget?.isJump != true { sessionDismissedBeforeJump = sessionDismissed }
        sessionDismissed = true
        beginSearch(for: SearchTarget(video: episode, isJump: true))
    }

    // MARK: - Source switching (player panel)

    /// Load alternate streams for the video that's playing right now. Uses the repository's
    /// dedicated `sourceState` flow, so it can never collide with the next-episode search (which
    /// owns `episodeStreamsState` and now starts well before the card).
    func loadSources() {
        guard !sourcesLoading else { return }
        sourcesLoading = true
        sources = []

        sourcesWatcher?.cancel()
        sourceLoadGeneration += 1
        let generation = sourceLoadGeneration

        // Load FIRST, then subscribe. The shared `fetchStreams` publishes this request's state
        // synchronously — its loading groups, or the finished result of an identical request it
        // deduplicates against (a reopened panel, a source switch on the same video) — so the
        // StateFlow's replay is always this request's, never an earlier video's list, and a
        // deduplicated empty result ends the spinner instead of leaving it up for good.
        PlayerStreamsRepository.shared.loadSources(
            type: context.contentType,
            videoId: context.videoId,
            season: context.season.map { KotlinInt(int: Int32($0)) },
            episode: context.episode.map { KotlinInt(int: Int32($0)) },
            forceRefresh: false
        )

        var sawActivity = false
        sourcesWatcher = FlowWatcherKt.watch(PlayerStreamsRepository.shared.sourceState) { [weak self] emitted in
            guard let self, generation == self.sourceLoadGeneration,
                  let state = emitted as? StreamsUiState else { return }
            self.sources = self.allStreams(state.groups)
            if state.isAnyLoading || !state.groups.isEmpty || state.emptyStateReason != nil { sawActivity = true }
            if sawActivity, !state.isAnyLoading { self.sourcesLoading = false }
        }
    }

    /// Switch the current video to a different stream (it starts at the current position).
    /// Returns false when the stream can't be played at all; true means "handled" — a debrid
    /// stream resolves asynchronously first (the panel may dismiss; playback switches when the
    /// link lands, ~1s for cached torrents, and a failed resolve leaves playback untouched).
    func playSource(_ stream: StreamItem) -> Bool {
        let direct: String? = stream.playableDirectUrl
        if let direct, !direct.isEmpty, let url = URL(string: direct) {
            switchToSource(stream: stream, url: url)
            return true
        }
        guard DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: stream) else { return false }
        DirectDebridPlaybackResolver.shared.resolveToPlayableStream(
            stream: stream,
            season: context.season.map { KotlinInt(int: Int32($0)) },
            episode: context.episode.map { KotlinInt(int: Int32($0)) }
        ) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self, let success = result as? DirectDebridPlayableResult.Success else { return }
                let resolved: String? = success.stream.playableDirectUrl
                guard let resolved, !resolved.isEmpty, let url = URL(string: resolved) else { return }
                self.switchToSource(stream: success.stream, url: url)
            }
        }
        return true
    }

    private func switchToSource(stream: StreamItem, url: URL) {
        guard !handedOff else { return }
        Self.consecutiveAutoPlays = 0

        let switched = PlaybackContext(
            url: url,
            title: context.title,
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            season: context.season,
            episode: context.episode,
            poster: context.poster,
            background: context.background,
            providerName: stream.addonName,
            providerAddonId: stream.addonId,
            streamTitle: stream.streamLabel,
            streamSubtitle: { let s: String? = stream.description_; return s }(),
            externalSubtitles: (stream.externalSubtitles).map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            },
            bingeGroup: { let bg: String? = stream.behaviorHints.bingeGroup; return bg }(),
            episodes: episodes,
            synopsis: context.synopsis,
            episodeStill: context.episodeStill,
            meta: context.meta,
            fileSizeBytes: { let n: Int64? = stream.behaviorHints.videoSize?.int64Value; return n }(),
            requestHeaders: StreamModelsKt.sanitizePlaybackHeaders(
                headers: stream.behaviorHints.proxyHeaders?.request),
            // The new source picks up exactly where this one is (c69b643a6).
            startPositionSec: lastPositionSec,
            seriesTitle: seriesTitleForRecord,
            episodeTitle: context.episodeTitle,
            logo: context.logo
        )
        handedOff = true
        countdownTask?.cancel()
        countdownTask = nil
        tearDownSearch()
        releaseObservers()
        onPlayNext(switched)
    }

    // MARK: - Card + countdown

    private func showCard(next: MetaVideo, positionSec: Double, durationSec: Double) {
        cardShown = true
        // A prefetch that found nothing gets one fresh try when the card appears.
        if searchFailed && !retriedAtCard {
            retriedAtCard = true
            ensureSearch(for: next, retryFailed: true)
        } else {
            ensureSearch(for: next, retryFailed: false)
        }
        if searchFailed {
            phase = .noStream
            return
        }
        phase = .upNext
        // Never promise more seconds than the file has left.
        let left = max(1, Int((durationSec - positionSec).rounded(.up)))
        startCountdown(total: min(countdownSeconds, left))
    }

    /// Make sure the next episode's search is running or has produced a stream. `retryFailed`
    /// also re-runs a search that already came back empty.
    private func ensureSearch(for next: MetaVideo, retryFailed: Bool) {
        guard !isStreamReady, !isSearching, searchTarget?.isJump != true else { return }
        if searchFailed && !retryFailed { return }
        beginSearch(for: SearchTarget(video: next, isJump: false))
    }

    private func startCountdown(total: Int, remaining: Int? = nil) {
        countdownTask?.cancel()
        countdownTotal = total
        countdownRemaining = remaining ?? total
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .upNext, !self.cancelled, !self.handedOff else { return }
                // Frozen while the video is paused, while the top panel is open, and while the app
                // is not in the foreground.
                if self.countdownPaused || self.isPanelOpen || self.systemSuspended { continue }
                if self.countdownRemaining <= 1 {
                    self.countdownFinished()
                    return
                }
                self.countdownRemaining -= 1
            }
        }
    }

    private func countdownFinished() {
        guard phase == .upNext, !cancelled, !handedOff else { return }
        countdownTask = nil
        countdownRemaining = 0
        // The countdown ran out untouched. With "Ask Still watching?" on, the Nth unattended
        // autoplay in a row asks first (Android TV parity) — OK / Down continue. So does any
        // autoplay after the app left the foreground or lost its audio output.
        if mustConfirmAutoplay {
            phase = .stillWatching
            return
        }
        handOffIsAutomatic = true
        playWhenReady = true
        if let next = nextVideo { ensureSearch(for: next, retryFailed: false) }
        evaluateHandOff()
    }

    // MARK: - Hand-off

    private func evaluateHandOff() {
        guard !cancelled, !handedOff, isStreamReady, let target = searchTarget,
              let url = readyURL, let stream = readyStream else { return }
        // Never start an episode while the app is not in the foreground: the hand-off that fell
        // due runs on `didBecomeActive` (an automatic one has turned into "Still watching?").
        guard !systemSuspended else { return }
        if target.isJump {
            handOff(stream: stream, url: url, video: target.video, isNextEpisode: false)
            return
        }
        guard playWhenReady, phase != .stillWatching else { return }
        // Never swap the player out from under the open top panel on its own: an automatic
        // hand-off that fell due (end of file) runs when the panel closes (`setPanelOpen`).
        if handOffIsAutomatic && isPanelOpen { return }
        // Nor from under a video the viewer paused mid-file (the countdown ran out during the
        // credits and the source came in after the pause): it runs when playback resumes.
        if handOffIsAutomatic && isPaused && !ended { return }
        handOff(stream: stream, url: url, video: target.video, isNextEpisode: true)
    }

    private func handOff(stream: StreamItem, url: URL, video: MetaVideo, isNextEpisode: Bool) {
        handedOff = true
        countdownTask?.cancel()
        countdownTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        streamsWatcher?.cancel()
        streamsWatcher = nil
        releaseObservers()
        let nextContext = makeNextContext(stream: stream, url: url, next: video)
        if isNextEpisode {
            if handOffIsAutomatic {
                Self.consecutiveAutoPlays += 1
                // The next engine keeps the run going only for the context handed to it here.
                Self.lastAutomaticHandOffContextId = nextContext.id
            } else {
                Self.consecutiveAutoPlays = 0
            }
            // The finished episode is recorded as completed on teardown, so Continue Watching
            // moves on to this one.
            onWillHandOff?()
            // Head start for the next player's addon subtitles, under the id its own fetch uses (it
            // deduplicates; the native engine gates its master playlist on them). Only now that the
            // hand-off is committed: the shared repository holds ONE list, and prefetching at stream
            // selection — up to a minute before the end — swapped the current episode's subtitles
            // out from under the player still showing it.
            onPrefetchingNextSubtitles?()
            SubtitleRepository.shared.fetchAddonSubtitles(type: nextContext.contentType, videoId: nextContext.videoId)
        } else {
            Self.consecutiveAutoPlays = 0
        }
        print("[UpNext] hand-off — \(Self.episodeTitle(video)) via \(stream.addonName)")
        if phase != .hidden { phase = .hidden }
        // `endScreen` is left as it is on purpose: the presenter replaces this whole player (and
        // an end-screen cover on it) in one transition — dismissing the cover here as well would
        // race that swap.
        onPlayNext(nextContext)
    }

    // MARK: - Search + selection

    private func beginSearch(for target: SearchTarget) {
        guard let settings = settings ?? (PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState)
        else { return }
        tearDownSearch()
        let generation = searchGeneration
        searchTarget = target
        searchStarted = true
        searchFailed = false
        selectedStream = nil
        readyStream = nil
        readyURL = nil
        latestStreamsState = nil
        if isStreamReady { isStreamReady = false }
        isSearching = true
        sourceName = nil

        // Addons are asked with the episode's own id; the progress key stays `episodeVideoId`.
        let videoId = Self.streamQueryVideoId(metaId: context.parentMetaId, episode: target.video)
        print("[UpNext] search begin — \(videoId) s\(target.video.season?.stringValue ?? "?")e\(target.video.episode?.stringValue ?? "?")\(target.isJump ? " (jump)" : "")")
        PlayerStreamsRepository.shared.loadEpisodeStreams(
            type: context.contentType,
            videoId: videoId,
            season: target.video.season,
            episode: target.video.episode,
            forceRefresh: false
        )

        streamsWatcher = FlowWatcherKt.watch(PlayerStreamsRepository.shared.episodeStreamsState) { [weak self] emitted in
            guard let self, generation == self.searchGeneration, let state = emitted as? StreamsUiState else { return }
            self.latestStreamsState = state
            print("[UpNext] streams: groups=\(state.groups.count) playable=\(self.allStreams(state.groups).count) loading=\(state.isAnyLoading)")
            self.handleStreams(state, settings: settings)
        }

        // Bounded auto-select timeout (mobile default 3s, clamped 1–30).
        let timeoutSeconds = min(max(Int(settings.streamAutoPlayTimeoutSeconds), 1), 30)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            guard let self, !Task.isCancelled, generation == self.searchGeneration,
                  self.selectedStream == nil, !self.cancelled else { return }
            // At timeout: pick from whatever has arrived so far; if nothing yet and addons are
            // still responding, let the watcher finish the job when loading completes.
            let state = self.latestStreamsState
            let groups = state?.groups ?? []
            print("[UpNext] timeout(\(timeoutSeconds)s): groups=\(groups.count) loading=\(state?.isAnyLoading ?? false)")
            if !groups.isEmpty {
                self.attemptSelection(groups: groups, settings: settings, loadFinished: !(state?.isAnyLoading ?? false))
            }
            // Hard deadline: a hung addon can leave the flow "loading" forever. Give stragglers a
            // grace window past the soft timeout, then resolve with whatever exists (or "no stream").
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, generation == self.searchGeneration,
                  self.selectedStream == nil, !self.cancelled else { return }
            let late = self.latestStreamsState
            print("[UpNext] hard deadline: groups=\(late?.groups.count ?? 0) loading=\(late?.isAnyLoading ?? false) — resolving")
            self.attemptSelection(groups: late?.groups ?? [], settings: settings, loadFinished: true)
        }
    }

    private func tearDownSearch() {
        searchGeneration += 1
        streamsWatcher?.cancel()
        streamsWatcher = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if isSearching { isSearching = false }
        PlayerStreamsRepository.shared.clearEpisodeStreams()
    }

    private func handleStreams(_ state: StreamsUiState, settings: PlayerSettingsUiState) {
        guard selectedStream == nil, !cancelled, !handedOff else { return }
        let groups = state.groups
        if groups.isEmpty && state.isAnyLoading { return }

        if state.isAnyLoading {
            // Early exit while still loading: only for a same-binge-group match (mobile parity).
            attemptBingeGroupOnlySelection(groups: groups, settings: settings)
            // Upstream 58864ec1 (#1825): "still loading" is judged inside the configured auto-play
            // source scope — once every in-scope source has finished, an out-of-scope source still
            // fetching must neither delay the pick nor be picked.
            guard selectedStream == nil, !cancelled else { return }
            let scope = effectiveAutoPlaySource(settings)
            if StreamAutoPlayLoadingPolicyKt.areAutoPlaySourcesLoaded(groups, source: scope, installedAddonIds: state.installedAddonIds) {
                print("[UpNext] in-scope sources loaded (\(scope)) while others still fetch — selecting now")
                attemptSelection(groups: groups, settings: settings, loadFinished: true, installedAddonIds: state.installedAddonIds)
            }
        } else {
            attemptSelection(groups: groups, settings: settings, loadFinished: true, installedAddonIds: state.installedAddonIds)
        }
    }

    private func allStreams(_ groups: [AddonStreamGroup]) -> [StreamItem] {
        groups.flatMap { group in
            group.streams.filter {
                let direct: String? = $0.playableDirectUrl
                // Never hand off to the file that is playing right now: an addon that misreads the
                // next episode's id answers with the current episode's streams.
                if let direct, !direct.isEmpty { return direct != currentUrlString }
                // Debrid setups: torrent/clientResolve results carry NO direct URL — they resolve
                // to one at play time (exactly like the stream picker's click path).
                return DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: $0)
            }
        }
    }

    /// The current stream's binge group, when the user prefers it; nil = no preference.
    private func preferredBingeGroup(_ settings: PlayerSettingsUiState) -> String? {
        guard settings.streamAutoPlayPreferBingeGroup else { return nil }
        let group = (context.bingeGroup ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return group.isEmpty ? nil : group
    }

    private func attemptBingeGroupOnlySelection(groups: [AddonStreamGroup], settings: PlayerSettingsUiState) {
        guard preferredBingeGroup(settings) != nil else { return }
        if let match = select(from: groups, settings: settings, bingeGroupOnly: true,
                              installedAddonIds: latestStreamsState?.installedAddonIds ?? []) {
            didSelect(match)
        }
    }

    private func attemptSelection(groups: [AddonStreamGroup], settings: PlayerSettingsUiState, loadFinished: Bool,
                                  installedAddonIds: Set<String>? = nil) {
        guard selectedStream == nil, !cancelled, !handedOff else { return }
        let installed = installedAddonIds ?? latestStreamsState?.installedAddonIds ?? []
        if let match = select(from: groups, settings: settings, bingeGroupOnly: false, installedAddonIds: installed) {
            didSelect(match)
        } else if loadFinished {
            finishWithoutStream()
        }
    }

    /// MANUAL mode (the default) configures no auto-play scope of its own: like mobile's
    /// `effectiveAutoPlaySource`, the next-episode pick then runs over every source. A scope, addon
    /// or plugin selection left over from an automatic mode applies only in that mode.
    private func effectiveAutoPlaySource(_ settings: PlayerSettingsUiState) -> StreamAutoPlaySource {
        settings.streamAutoPlayMode == StreamAutoPlayMode.manual
            ? StreamAutoPlaySource.allSources : settings.streamAutoPlaySource
    }

    /// NE-1: the binge group is a PREFERENCE. The pick always runs (MANUAL mode selects the first
    /// stream over every source — tvOS has no picker to fall back to mid-playback); automatic modes
    /// keep their source scope and addon/plugin filters (and regex, in regex mode). Binge-group-only
    /// happens solely when the playing stream HAS a binge group, the user prefers it, and they
    /// explicitly turned "Fallback when binge group fails" off (its default is on).
    private func select(from groups: [AddonStreamGroup], settings: PlayerSettingsUiState, bingeGroupOnly: Bool,
                        installedAddonIds: Set<String>) -> StreamItem? {
        let streams = allStreams(groups)
        guard !streams.isEmpty else { return nil }

        let mode = settings.streamAutoPlayMode
        let manual = mode == StreamAutoPlayMode.manual
        let effectiveMode = manual ? StreamAutoPlayMode.firstStream : mode
        let effectiveRegex = mode == StreamAutoPlayMode.regexMatch ? settings.streamAutoPlayRegex : ""
        let effectiveAddons: Set<String> = manual ? [] : settings.streamAutoPlaySelectedAddons
        let effectivePlugins: Set<String> = manual ? [] : settings.streamAutoPlaySelectedPlugins
        let bingeGroup = preferredBingeGroup(settings)
        if bingeGroupOnly && bingeGroup == nil { return nil }
        let requireBingeGroup = bingeGroupOnly
            || (bingeGroup != nil && !settings.streamAutoPlayNextEpisodeFallbackEnabled)

        let debrid = DebridSettingsRepository.shared.snapshot()
        // Only the groups the shared repository marked as installed addons count as "addons" for the
        // source scope; the rest are plugin groups. The set is authoritative — an EMPTY set is a
        // valid plugin-only fan-out (Codex r1), not "unknown", so there is no all-groups fallback.
        let installedAddonNames = Set(groups.filter { installedAddonIds.contains($0.addonId) }.map { $0.addonName })

        return StreamAutoPlaySelector.shared.selectAutoPlayStream(
            streams: streams,
            mode: effectiveMode,
            regexPattern: effectiveRegex,
            source: effectiveAutoPlaySource(settings),
            installedAddonNames: installedAddonNames,
            selectedAddons: effectiveAddons,
            selectedPlugins: effectivePlugins,
            preferredBingeGroup: bingeGroup,
            preferBingeGroupInSelection: bingeGroup != nil,
            bingeGroupOnly: requireBingeGroup,
            debridEnabled: debrid.canResolvePlayableLinks,
            activeResolverProviderId: { let id: String? = debrid.activeResolverProviderId; return id }()
        )
    }

    private func didSelect(_ stream: StreamItem) {
        guard selectedStream == nil, !cancelled, !handedOff, let target = searchTarget else { return }
        print("[UpNext] selected — \(stream.addonName): \(stream.streamLabel)")
        selectedStream = stream
        sourceName = stream.addonName
        timeoutTask?.cancel()
        timeoutTask = nil
        streamsWatcher?.cancel()
        streamsWatcher = nil
        resolve(stream, for: target)
    }

    /// Direct links are ready as they are; debrid results resolve to a direct link now (the old
    /// play-time resolve), so the hand-off itself is instant.
    private func resolve(_ stream: StreamItem, for target: SearchTarget) {
        let direct: String? = stream.playableDirectUrl
        if let direct, !direct.isEmpty, let url = URL(string: direct) {
            streamReady(stream: stream, url: url)
            return
        }
        guard DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: stream) else {
            selectedStream = nil
            finishWithoutStream()
            return
        }
        let generation = searchGeneration
        print("[UpNext] resolving debrid stream — \(stream.addonName)")
        DirectDebridPlaybackResolver.shared.resolveToPlayableStream(
            stream: stream,
            season: target.video.season,
            episode: target.video.episode
        ) { [weak self] result, _ in
            // Kotlin suspend completions can land off-main; hop before touching engine state.
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration, !self.cancelled, !self.handedOff else { return }
                if let success = result as? DirectDebridPlayableResult.Success {
                    let resolved: String? = success.stream.playableDirectUrl
                    if let resolved, !resolved.isEmpty, let url = URL(string: resolved) {
                        print("[UpNext] resolved — next episode ready")
                        self.streamReady(stream: success.stream, url: url)
                        return
                    }
                }
                print("[UpNext] debrid resolve failed — \(String(describing: result))")
                self.selectedStream = nil          // reopen finishWithoutStream's guard
                self.finishWithoutStream()
            }
        }
    }

    private func streamReady(stream: StreamItem, url: URL) {
        if url.absoluteString == currentUrlString {
            print("[UpNext] resolved stream is the current file — refusing the same-episode hand-off")
            selectedStream = nil
            finishWithoutStream()
            return
        }
        readyStream = stream
        readyURL = url
        sourceName = stream.addonName
        if isSearching { isSearching = false }
        isStreamReady = true
        evaluateHandOff()
    }

    private func finishWithoutStream() {
        guard selectedStream == nil, !cancelled, !handedOff else { return }
        print("[UpNext] no stream found")
        timeoutTask?.cancel()
        timeoutTask = nil
        streamsWatcher?.cancel()
        streamsWatcher = nil
        if isSearching { isSearching = false }
        playWhenReady = false
        if let jump = searchTarget, jump.isJump {
            // A failed panel jump leaves the current episode playing, with Up Next as the jump
            // found it (the next episode itself was never searched: its prefetch runs again).
            searchTarget = nil
            searchStarted = false
            searchFailed = false
            sessionDismissed = sessionDismissedBeforeJump ?? false
            sessionDismissedBeforeJump = nil
            cardShown = false
            retriedAtCard = false
            // The viewer asked for that episode: no stream could be picked for it automatically,
            // so its stream list opens (a source chosen by hand) — never a jump that silently does
            // nothing (build 138 feedback).
            if onPickSourceRequested != nil {
                print("[UpNext] jump found no stream — opening the stream list for it")
                openStreamPicker(for: jump.video)
                return
            }
            if ended {
                // The file ran out while the jump was resolving: land where an ended file lands —
                // the end screen (the next episode, never a replay), or the details page.
                if nextVideo != nil {
                    endScreen = .nextEpisode
                } else {
                    cancelAndExit()
                }
            }
            return
        }
        searchFailed = true
        if ended {
            countdownTask?.cancel()
            countdownTask = nil
            if phase != .hidden { phase = .hidden }
            endScreen = .chooseSource
        } else if phase == .upNext {
            countdownTask?.cancel()
            countdownTask = nil
            phase = .noStream
        }
    }

    /// Kotlin-bridged optional strings: blank counts as missing (addons send "" for no still).
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func makeNextContext(stream: StreamItem, url: URL, next: MetaVideo) -> PlaybackContext {
        PlaybackContext(
            url: url,
            title: Self.episodeTitle(next),
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: Self.episodeVideoId(metaId: context.parentMetaId, episode: next),
            season: next.season?.value,
            episode: next.episode?.value,
            poster: context.poster,
            background: context.background,
            providerName: stream.addonName,
            providerAddonId: stream.addonId,
            streamTitle: stream.streamLabel,
            streamSubtitle: { let s: String? = stream.description_; return s }(),
            externalSubtitles: (stream.externalSubtitles).map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            },
            bingeGroup: { let bg: String? = stream.behaviorHints.bingeGroup; return bg }(),
            episodes: episodes,
            // The next episode's own still/overview only — never the previous episode's.
            synopsis: Self.nonEmpty(next.overview),
            episodeStill: Self.nonEmpty(next.thumbnail),
            meta: context.meta,
            fileSizeBytes: { let n: Int64? = stream.behaviorHints.videoSize?.int64Value; return n }(),
            requestHeaders: StreamModelsKt.sanitizePlaybackHeaders(
                headers: stream.behaviorHints.proxyHeaders?.request),
            // CW-1: same series; the next episode's own name.
            seriesTitle: seriesTitleForRecord,
            episodeTitle: Self.nonEmpty(next.title),
            logo: context.logo
        )
    }

    /// CW-1: the series name the next context's progress record is filed under. A launch from a
    /// legacy progress record may not have had it (its label was dropped, the picker's fetch had not
    /// landed); by the hand-off that fetch — or this engine's own — has cached the series meta.
    private var seriesTitleForRecord: String? {
        if let seriesTitle = context.seriesTitle { return seriesTitle }
        guard context.season != nil, context.episode != nil else { return nil }
        return ProgressRecordTitles.cachedSeriesName(type: context.contentType, id: context.parentMetaId)
    }

    // MARK: - Episode resolution (Swift port of mobile's PlayerNextEpisodeRules)

    static func resolveNextAiredEpisode(episodes: [MetaVideo], currentSeason: Int?, currentEpisode: Int?) -> MetaVideo? {
        guard let currentSeason, let currentEpisode else { return nil }
        let sorted = episodes
            .compactMap { video -> (MetaVideo, Int, Int)? in
                guard let s = video.season?.value, let e = video.episode?.value else { return nil }
                return (video, s, e)
            }
            .sorted { a, b in a.1 == b.1 ? a.2 < b.2 : a.1 < b.1 }

        guard let index = sorted.firstIndex(where: { $0.1 == currentSeason && $0.2 == currentEpisode }),
              index + 1 < sorted.count
        else { return nil }

        let next = sorted[index + 1].0
        let released: String? = next.released
        return hasAired(released) ? next : nil
    }

    /// Treats missing/unparseable dates as aired (mobile behavior). Delegates to the shared
    /// core/time parser so zoned timestamps compare as real instants and date-only values use
    /// UTC midnight — the old Swift port compared local calendar dates and mis-gated episodes
    /// around midnight/timezone boundaries (fixed upstream in v0.3.0; kept in sync here).
    static func hasAired(_ raw: String?) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return EpisodeReleaseDateParserKt.isEpisodeReleaseAired(raw: raw, nowEpochMs: nowMs)?.boolValue ?? true
    }

    // MARK: - Formatting

    /// An episode's watch-progress key — the `PlaybackContext.videoId` of an auto-played episode
    /// and of the "Choose a Source" picker: `parent:season:episode`, exactly what `EpisodesSection`
    /// launches with and what the Detail and player watched lookups query (the shared progress
    /// lookup matches the id exactly), so an auto-played episode lands under the same key.
    static func episodeVideoId(metaId: String, episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return "\(metaId):\(s):\(e)"
        }
        return episode.id
    }

    /// The id the stream addons are asked with for the next episode: its own `MetaVideo.id`
    /// (mobile `PlayerNextEpisodeAutoPlay` parity) — kitsu/anime catalogs and tmdb-keyed metas don't
    /// follow `parent:season:episode`; identical to `episodeVideoId` for IMDb/Cinemeta series. The
    /// synthesized form is the fallback for a blank id.
    static func streamQueryVideoId(metaId: String, episode: MetaVideo) -> String {
        if let id = nonEmpty(episode.id) { return id }
        return episodeVideoId(metaId: metaId, episode: episode)
    }

    /// Seconds from a catalog runtime string ("45 min", "1h 30min", "24"), nil when unreadable.
    static func runtimeSec(parsing raw: String?) -> Double? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        var total = 0.0
        var number = 0.0
        var hasNumber = false
        for character in raw {
            if let digit = character.wholeNumberValue, character.isASCII {
                number = number * 10 + Double(digit)
                hasNumber = true
            } else if character == " " {
                continue
            } else if hasNumber {
                if character == "h" {
                    total += number * 3600
                } else if character == "m" {
                    total += number * 60
                }
                number = 0
                hasNumber = false
            }
        }
        if hasNumber { total += number * 60 }   // a bare number is minutes
        return total > 0 ? total : nil
    }

    static func episodeTitle(_ episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return "S\(s)E\(e) \u{00B7} \(episode.title)"
        }
        return episode.title
    }
}
