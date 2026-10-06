import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

// Playback models (PlaybackContext, PlayerTuning, PlayerTrack, SkipSegment/SkipPrompt,
// StreamInfoSnapshot, SubtitleFile) now live in PlaybackModels.swift so every engine shares them.

/// CAMetalLayer subclass that ignores degenerate drawable sizes (mirrors the iOS player's MetalLayer).
final class TVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// libmpv-backed player for tvOS. Siri-remote transport: select/play-pause toggles, left/right seek
/// ±10s, down (or a down swipe) opens the top panel, Menu exits. Publishes position/duration/paused/buffering and
/// track lists to `state`, and records watch progress (resume position) via `WatchProgressRepository`.
final class MPVTVPlayerViewController: UIViewController {

    private var metalLayer = TVMetalLayer()
    var mpv: OpaquePointer?
    private var lastDrawableSize: CGSize = .zero
    let eventQueue = DispatchQueue(label: "mpv-events", qos: .userInitiated)
    let context: PlaybackContext
    let state: MPVPlaybackState
    private var didLoad = false
    private var pollTimer: Timer?
    var hideWork: DispatchWorkItem?
    private var lastSaveUptime: TimeInterval = 0
    private var pendingResumeSec: Double?
    /// A saved row with a percentage and no timecode (Simkl episode or Trakt playback row, upstream
    /// b7657dbe4): scaled by this file's own duration once mpv has loaded it.
    private var pendingResumeFraction: Double?
    /// The file is loaded but mpv did not know its duration yet: the first `duration` change
    /// applies `pendingResumeFraction` (main thread only).
    private var resumeFractionAwaitsDuration = false
    var seekTimer: Timer?
    var seekDirection: Double = 0
    var seekHoldCount = 0
    private var subtitleWatcher: FlowWatcher?
    private var subtitleLoadingWatcher: FlowWatcher?
    private var playerSettingsWatcher: FlowWatcher?
    var playerSettings: PlayerSettingsUiState?
    var didAutoSelectTracks = false
    /// Preferred audio-language targets in priority order, resolved once in `setupMpv()` (before
    /// `mpv_initialize`) so mpv's own first `aid=auto` resolution already honors them.
    var preferredAudioLanguages: [String] = []
    /// True once `alang` reached mpv — as an option pre-init, or via the property re-apply.
    var didApplyAlang = false
    /// Set by an explicit pick in selectAudio(_:); no automatic path may override it afterwards.
    /// Insurance, not a live race: there is exactly one `loadfile` per controller (SwiftUI rebuilds
    /// the player per episode via `.id(ctx.id)`), so a user pick can only ever follow the automatic
    /// selection, never race it. The flag keeps that true if the controller is ever reused.
    var didUserSelectAudio = false
    var addedSubtitleUrls = Set<String>()
    var fileLoaded = false
    /// Subtitle choice memory (c9d6f5f63): the choice saved for this title (series-wide), the addon
    /// subtitles side-loaded into this file by URL, the addon list last filtered for it, and the last
    /// track walk's subtitle rows.
    lazy var persistedTrackPreference: PersistedPlayerTrackPreference? =
        PlayerSubtitleMemory.load(parentMetaId: context.parentMetaId)
    var sideLoadedAddonSubtitles: [String: AddonSubtitle] = [:]
    var latestAddonSubtitles: [AddonSubtitle] = []
    var lastSubtitleInfos: [TrackInfo] = []
    /// This file's subtitle selection is settled: restored, planned, or picked by the viewer.
    var subtitleSelectionResolved = false
    /// A saved addon choice waits this long, at most, for this episode's addon subtitles.
    var subtitleRestoreDeadline: DispatchWorkItem?
    var subtitleRestoreDeadlinePassed = false
    static let subtitleRestoreWaitSec: TimeInterval = 8
    /// The audio pass's inputs for the subtitle language plan (it may run after a restore gave up).
    var subtitlePlanAudio: AudioTrack?
    var subtitlePlanAudioTargets: [String] = []
    /// `eventQueue`-confined: an addon subtitle to select once its side-load lands, and the addon URL
    /// behind each credential-scoped local copy.
    var pendingSubtitleSelectURL: String?
    var externalSubtitleSources: [String: String] = [:]
    /// Trakt scrobbling (no-ops while Trakt is disconnected — the shared repo checks auth).
    var traktScrobbleItem: TraktScrobbleItem?
    var traktScrobbleRequested = false
    /// The other trackers' scrobble (Simkl — every connected tracker but Trakt, through
    /// `TrackingScrobbleCoordinator.scrobbleOtherTrackers`) is open: started with the Trakt session
    /// but independently of its item build, which returns nil for `kitsu:`/`mal:` ids. Cleared by the
    /// one stop, so the `deinit` fallback after `viewDidDisappear` sends no second one.
    var otherTrackersOpen = false
    /// Set once the player is going away. `buildItem` completes asynchronously — if the user backs
    /// out before it returns, the late completion must not start a scrobble that nothing will ever
    /// stop (ME-004).
    var traktSessionClosed = false
    /// PLY-6: the file loaded, but its duration only reaches `state` on the next refresh tick — the
    /// Trakt start waits for that tick, so the placeholder-clip guard and the start percentage both
    /// see the real duration instead of 0.
    var traktStartPending = false
    /// Where the FILE_LOADED resume seek lands. The Trakt start reports it while that seek is still
    /// in flight (a resumed episode used to open its scrobble at 0 %).
    var resumeTargetSec: Double?
    var skipSegments: [SkipSegment] = []
    /// Last raw eof-reached value (edge detection for the post-play cover).
    private var lastEofFlag = false
    /// PLY-4: last cached pause flag — a pause pushes the position to the account (mobile flushes
    /// on every playing → paused), as does leaving the app mid-playback (the TV button, sleep):
    /// neither reaches `viewDidDisappear`'s flush.
    private var lastPausedFlag = false
    private var backgroundObserver: NSObjectProtocol?
    var streamHeadersCarryCredentials = false

    /// Contract C1 (PLY-A9): the probe found Dolby Vision Profile 5 and this file plays on mpv. Its
    /// IPTPQc2 colours only come out right through libplacebo's reshaping, so the session renders
    /// with `vo=gpu-next`. Set by the representable right after `init`, before the view loads.
    var forceDVReshape = false
    /// `forceDVReshape` actually switched this session to `gpu-next` (never on the simulator).
    private var dvReshapeActive = false
    /// PLY-A1, `eventQueue`-confined: this file's display criteria still wait for mpv to report a
    /// video size. FILE_LOADED often arrives before the first decoded frame, when `video-params` is
    /// still empty and the criteria can't be built. Reset on every `loadfile`.
    private var displayCriteriaAwaitsVideoSize = true
    /// Playback is paused while the TV switches its display mode (PLY-A1), so audio does not run on
    /// over a black screen. At most `displaySwitchHoldMaxSec`.
    private var displaySwitchHoldActive = false
    private static let displaySwitchHoldMaxSec: TimeInterval = 3
    /// PLY-A8: app-lifecycle and audio-interruption observers, removed in `deinit`.
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Why playback was paused by the system rather than the viewer. Only an audio interruption that
    /// ends with `.shouldResume` resumes by itself; leaving the app (TV button, sleep) stays paused.
    private enum SystemPauseReason { case interruption, resignedActive }
    private var systemPauseReason: SystemPauseReason?
    /// Uptime of the last pause/play flip `refreshState` saw — a Now Playing toggle that lands right
    /// after a local press is the same press, not a second one.
    private var lastPauseFlipUptime: TimeInterval = 0
    /// Control Center / iPhone Remote / Siri (PLY-A7, VIS-06).
    private var nowPlaying: MPVNowPlaying?

    // MARK: Event-driven property cache
    //
    // The main thread must NEVER call mpv_get_property: synchronous reads contend on the core
    // lock, which is busiest during the first minute of playback (demuxer cache fill, decoder
    // spin-up) — that contention was the beta-reported "player laggy at first" / "swipe-up menu
    // slow to appear" (tracker BUG-2/BUG-3). Values arrive as MPV_EVENT_PROPERTY_CHANGE payloads
    // on `eventQueue` and land in this lock-guarded snapshot; the UI timer only reads the cache.
    struct PropSnapshot {
        var position: Double = 0
        var duration: Double = 0
        var paused = false
        var coreIdle = false
        var cacheWait = false
        var eof = false
        var videoW: Int64 = 0
        var videoH: Int64 = 0
    }
    private let propLock = NSLock()
    private var propSnapshot = PropSnapshot()
    /// Coalesces track-list refresh requests (many property events can arrive in a burst).
    var trackRefreshPending = false
    /// Uptime when FILE_LOADED fired — drives the first-90s `[MPVStats]` diagnostics.
    private var fileLoadedUptime: TimeInterval = 0
    /// Times playback entered paused-for-cache (buffering underruns), for diagnostics.
    private var cacheWaitCount = 0

    /// Observation ids for mpv_observe_property (arrive back as `reply_userdata`).
    private enum ObservedProp: UInt64 {
        case timePos = 1, duration, pause, coreIdle, pausedForCache, eofReached, trackCount
        case videoW, videoH, aid
    }

    func cachedProps() -> PropSnapshot {
        propLock.lock(); defer { propLock.unlock() }
        return propSnapshot
    }

    func updateProps(_ mutate: (inout PropSnapshot) -> Void) {
        propLock.lock(); defer { propLock.unlock() }
        mutate(&propSnapshot)
    }

    /// Called when the user presses Menu, so the SwiftUI cover can dismiss.
    var onExit: (() -> Void)?
    /// Set when a Menu press was consumed by the up-next dismiss so the matching release is
    /// swallowed too (same pattern as `PlayerPanelHostController`) — nothing above sees a half press.
    var swallowMenuRelease = false
    /// Hand focus to the chrome's focus layer: the transport buttons (Up, a swipe up, with the bar
    /// showing) or the content tabs (Down with nothing else to do, or a down swipe).
    var onOpenChrome: ((PlayerChromeEntry) -> Void)?
    /// Explicit start position handed over by a native → mpv fallback (NE-7/PLY-8). Wins over the
    /// saved progress — which may already be marked completed near the end, and would restart the
    /// episode from 0.
    private let startPositionSec: Double?

    // MARK: Playback errors (PLY-1)

    /// The error card's "Choose Another Source": back to a stream list for this episode. nil = no
    /// picker behind the player — the button reads "Back" and leaves the player.
    var onChooseAnotherSource: (() -> Void)?
    /// The error on screen (the card is `errorHost`); nil while playback is healthy.
    private var playbackError: PlayerPlaybackError?
    private var errorHost: PlayerErrorHostController?
    /// Bounds the wait for FILE_LOADED: a source that accepts the connection but never delivers a
    /// playable file raises no mpv event at all.
    private var loadWatchdog: DispatchWorkItem?
    private static let loadTimeoutSec: TimeInterval = 30
    /// Where this load started playing (the resume target, else 0). An end of file within
    /// `earlyEndSec` of it — short of the duration — is a stream that failed right after opening,
    /// not the end of the episode.
    var loadStartPositionSec: Double = 0
    private static let earlyEndSec: Double = 10
    /// `eventQueue`-confined: this load attempt reached FILE_LOADED, and the last HTTP error status
    /// the core logged before it did (the likely reason for an END_FILE error).
    private var coreOpenedFile = false
    private var lastHttpErrorStatus: Int?
    /// The viewer is leaving the player from the card: nothing may present it again meanwhile.
    private var leavingFromErrorCard = false

    init(context: PlaybackContext, state: MPVPlaybackState, startPositionSec: Double? = nil) {
        self.context = context
        self.state = state
        self.startPositionSec = startPositionSec
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true

        metalLayer.contentsGravity = .resizeAspect
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        layoutMetalLayer()

        state.selectAudio = { [weak self] id in self?.selectAudio(id) }
        state.selectSubtitle = { [weak self] id in self?.selectSubtitle(id) }
        state.setSpeed = { [weak self] speed in self?.setSpeed(speed) }
        state.setSubtitleDelay = { [weak self] seconds in self?.setSubtitleDelay(seconds) }
        state.setAudioDelay = { [weak self] seconds in self?.setAudioDelay(seconds) }
        state.replay = { [weak self] in self?.replay() }
        state.reclaimFocus = { [weak self] in self?.becomeFirstResponder() }
        state.seekTo = { [weak self] seconds in
            guard let self else { return }
            let target = self.state.durationSec > 0 ? min(seconds, max(self.state.durationSec - 1, 0)) : seconds
            self.seekAbsolute(target, exact: true)
        }
        view.accessibilityIdentifier = "player.mpv"

        // Touch-surface swipes: down → the content tabs, up → the transport buttons (presses arrive
        // as `.downArrow` / `.upArrow`; real swipes don't).
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
        swipeDown.direction = .down
        view.addGestureRecognizer(swipeDown)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
        swipeUp.direction = .up
        view.addGestureRecognizer(swipeUp)

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.saveProgress(flush: true) }
        }
        observeLifecycle()
        nowPlaying = MPVNowPlaying(controller: self, context: context)

        setupMpv()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutMetalLayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if !didLoad {
            didLoad = true
            computeResumePosition()
            applyRequestHeaders(context.requestHeaders)
            // Re-assert the audio-language preference on the live handle right before the load —
            // the fallback for a `setupMpv()` that ran before the settings store had hydrated.
            applyAudioLanguagePreferences()
            command("loadfile", args: [context.url.absoluteString, "replace"])
            armLoadWatchdog()
            startPolling()
            flashControls()

            // Side-load subtitles fetched from installed subtitle addons (OpenSubtitles etc.). Not
            // once Up Next prefetches the NEXT episode's list into the same shared repository.
            subtitleWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.addonSubtitles) { [weak self] emitted in
                guard let self, !self.state.freezeAddonSubtitles, let subs = emitted as? [AddonSubtitle] else { return }
                self.addAddonSubtitles(subs)
            }
            subtitleLoadingWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.isLoading) { [weak self] emitted in
                guard let self, let loading = (emitted as? NSNumber)?.boolValue else { return }
                DispatchQueue.main.async {
                    self.state.subtitleSearchInFlight = loading
                    // A saved addon choice may have been waiting for this fetch to finish.
                    if !loading { self.resolveSubtitleSelection(subInfos: self.lastSubtitleInfos) }
                }
            }

            // Subtitle appearance from Settings (color/size/bold/outline/background). The watcher
            // emits the current value immediately; re-apply live if the style changes mid-playback.
            PlayerSettingsRepository.shared.ensureLoaded()
            playerSettingsWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
                guard let self, let settings = emitted as? PlayerSettingsUiState else { return }
                self.playerSettings = settings
                // Through `applySubtitleAppearance` so a mid-playback style change keeps the
                // viewer's system caption overrides on top.
                if self.fileLoaded { self.applySubtitleAppearance() }
            }
        } else if mpv != nil, pollTimer == nil, !state.isEnded {
            // PLY-2: back from a full-screen cover (the end screen) for "Play Again" (`replay()`
            // clears `isEnded` before the cover goes). Its presentation ran viewDidDisappear, which
            // stops the state timer and reverts the display mode; without this, the replay played on
            // with a frozen UI, no progress saves and no EOF detection. Still at the end = the cover
            // closed on the way out (Menu → back to details): no restart, and no display-mode switch
            // right before leaving. (Trakt restarts in `replay()` — only a real replay opens a new
            // session.)
            startPolling()
            if fileLoaded { applyDisplayCriteriaIfEnabled() }
        }
        // PLY-1: the load watchdog stands down while the player is covered; back on screen with the
        // file still not loaded, it runs again. An error that arrived meanwhile is shown now.
        if didLoad, mpv != nil, !fileLoaded, playbackError == nil, loadWatchdog == nil {
            armLoadWatchdog()
        }
        presentErrorCardIfNeeded()
        // On screen again (first appearance, or back from the end screen's cover): Control Center
        // and the iPhone Remote talk to this player.
        if mpv != nil, !state.isEnded { nowPlaying?.activate() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadWatchdog?.cancel()
        loadWatchdog = nil
        pollTimer?.invalidate()
        pollTimer = nil
        endSeek()
        saveProgress(flush: true)
        stopTraktScrobble()
        displaySwitchHoldActive = false
        clearDisplayCriteria()
        // Covered (end screen) or gone: no remote command may reach a player that isn't on screen.
        nowPlaying?.deactivate()
    }

    override var canBecomeFirstResponder: Bool { true }

    private func layoutMetalLayer() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = UIScreen.main.nativeScale
        let drawable = CGSize(
            width: (bounds.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (bounds.height * scale).rounded(.toNearestOrAwayFromZero)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        metalLayer.contentsScale = scale
        if drawable != lastDrawableSize {
            metalLayer.drawableSize = drawable
            lastDrawableSize = drawable
        }
        CATransaction.commit()
    }

    // MARK: - MPV setup (proven option set from the iOS player)

    private func setupMpv() {
        // On REAL tvOS hardware no audio routes to HDMI unless the AVAudioSession is active
        // BEFORE the audio unit initializes — and with audio-fallback-to-null=yes a failed
        // audiounit init silently plays video with no sound (the simulator doesn't enforce
        // this, which is why audio worked there). The app-startup activation is async on a
        // background queue, so re-activate synchronously here (idempotent, cheap) and LOG
        // failures instead of swallowing them.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("[MPV] AVAudioSession activation FAILED: \(error)")
        }

        mpv = mpv_create()
        guard mpv != nil else { print("[MPV] Failed to create mpv instance"); return }

        checkError(mpv_request_log_messages(mpv, "warn"))
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer))

        // Video output: default `gpu` (stable). On REAL Apple TV hardware the user can opt into
        // `gpu-next` (libplacebo) via Settings → Playback → Enhanced Video Renderer for better HDR
        // tone-mapping (dynamic peak detection, DV/HDR10+). Never on the simulator, where
        // libplacebo's vo asserts ("vo: hit program assert").
        var videoOutput = "gpu"
        #if !targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: PlayerTuning.enhancedRendererKey) {
            videoOutput = "gpu-next"
        }
        // PLY-A9 (decision D10): Dolby Vision Profile 5 has no HDR10/SDR base layer — without
        // libplacebo's RPU reshaping it plays green and purple. This session only.
        if forceDVReshape {
            videoOutput = "gpu-next"
            dvReshapeActive = true
            print("[MPV] DV Profile 5: vo=gpu-next for this session")
        }
        #endif

        let options: [(String, String)] = [
            ("vo", videoOutput),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            // On REAL Apple TV hardware ao_audiounit fails to init entirely: its channel-layout
            // query returns kAudioUnitErr_InvalidProperty (-10879) → ao=null → silence (the sim
            // worked because the Mac's stereo output answers the query). ao_avfoundation
            // (AVSampleBufferAudioRenderer, Apple-native) doesn't need that query — use it first,
            // fall back to audiounit. Requires MPVKit >= 0.41.0-n8.1.2 (PR #73 enabled the
            // avfoundation ao for tvOS; PROVEN working on Apple TV 4K 3rd gen 2026-07-02).
            ("ao", "avfoundation,audiounit"),
            ("audio-channels", "auto"),
            ("audio-fallback-to-null", "yes"),
            ("vulkan-swap-mode", "fifo"),
            ("vulkan-queue-count", "1"),
            ("vulkan-async-compute", "no"),
            ("vulkan-async-transfer", "no"),
            // `vulkan-disable-interop` was dropped 2026-09-07: it is not an mpv option and never was
            // (absent from `video/out/vulkan/context.c` in every tag from v0.34.0 through v0.41.0,
            // and from the bundled libmpv 0.41.0 / MPVKit 0.41.0-n8.1.2 binary). It came in with the
            // iOS bridge's option list (upstream 4476a3f5); libmpv rejected it on every launch, which
            // was the long-standing anonymous `[MPV] API error: option not found`. Nothing replaces
            // it: it never took effect, so the proven Apple TV vulkan/moltenvk behaviour is already
            // the behaviour without it. The four vulkan-* options above are still valid in 0.41.
            ("video-rotate", "no"),
            ("keep-open", "yes"),
            ("target-colorspace-hint", "yes"),
            ("tone-mapping", "auto"),
            ("hdr-compute-peak", "yes"),
            // LANG-02: no subtitle track unless the language plan picks one — `yes` turned on a
            // default track when nothing matched, so "Subtitles: Off" still showed subtitles.
            ("subs-fallback", "no"),
            // LANG-02: the app's language plan decides, not the tvOS UI language (mpv ≥ 0.38; an
            // older core rejects it and the loop below logs it).
            ("subs-match-os-language", "no"),
            // PLY-A8: an HTTP source that drops (sleep, the TV button, a debrid CDN hiccup)
            // reconnects instead of ending the file, which read as "stream dropped".
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5"),
        ]
        for (key, value) in options {
            let status = mpv_set_option_string(mpv, key, value)
            if status < 0 {
                print("[MPV] option rejected: \(key)=\(value) (\(String(cString: mpv_error_string(status))))")
            }
        }

        // Preferred audio language as an OPTION, before `mpv_initialize`: this is what makes mpv's
        // own first `aid=auto` resolution honor the preference, so the right track is playing from
        // the first frame instead of being switched into a beat later (the audible mid-playback
        // switch upstream 4f79bfe0 removed on mobile). The property re-apply in
        // `applyAudioLanguagePreferences()` just before `loadfile` is only the fallback for the case
        // where the settings store had not hydrated yet at this point.
        preferredAudioLanguages = resolvePreferredAudioLanguages()
        if !preferredAudioLanguages.isEmpty {
            let alangStatus = mpv_set_option_string(
                mpv, "alang", PlayerAudioLanguagePlan.alangValue(targets: preferredAudioLanguages)
            )
            if alangStatus < 0 {
                print("[MPV] option rejected: alang (\(String(cString: mpv_error_string(alangStatus))))")
            }
            didApplyAlang = true
        }
        alangTrace("targets=\(preferredAudioLanguages) applied=\(didApplyAlang)")

        // User-tunable streaming buffer (Settings > Playback > Streaming Buffer). 0 = mpv defaults.
        let bufferMB = UserDefaults.standard.integer(forKey: PlayerTuning.bufferMBKey)
        if bufferMB > 0 {
            checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "\(bufferMB)MiB"))
            checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", "\(max(bufferMB / 2, 16))MiB"))
        }
        let readaheadSec = UserDefaults.standard.integer(forKey: PlayerTuning.readaheadSecKey)
        if readaheadSec > 0 {
            checkError(mpv_set_option_string(mpv, "cache", "yes"))
            checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "\(readaheadSec)"))
            checkError(mpv_set_option_string(mpv, "cache-secs", "\(readaheadSec)"))
        }

        checkError(mpv_initialize(mpv))
        // Everything the UI needs is observed with a data payload so state flows to us on the
        // event queue — the main thread never issues a synchronous property read (see PropSnapshot).
        mpv_observe_property(mpv, ObservedProp.timePos.rawValue, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, ObservedProp.duration.rawValue, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, ObservedProp.pause.rawValue, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.coreIdle.rawValue, "core-idle", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.pausedForCache.rawValue, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.eofReached.rawValue, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, ObservedProp.trackCount.rawValue, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.videoW.rawValue, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.videoH.rawValue, "video-params/h", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, ObservedProp.aid.rawValue, "aid", MPV_FORMAT_INT64)

        mpv_set_wakeup_callback(mpv, { ctx in
            let vc = unsafeBitCast(ctx, to: MPVTVPlayerViewController.self)
            vc.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }


    // MARK: - Match content frame rate (AVDisplayManager)

    /// Window whose display criteria we set — cleared on teardown so the display mode reverts.
    private weak var displayCriteriaWindow: UIWindow?

    /// Ask tvOS to switch the display mode to the content's native frame rate (and dynamic range,
    /// when mpv reports BT.2020/PQ/HLG). Public-API path for non-AVAsset players: build a
    /// `CMVideoFormatDescription` from mpv's reported params and use
    /// `AVDisplayCriteria(refreshRate:formatDescription:)`. Requires the user's tvOS
    /// Settings > Video and Audio > Match Content to allow frame-rate matching.
    func applyDisplayCriteriaIfEnabled() {
        applyDisplayCriteriaIfEnabled(holdDuringSwitch: false)
    }

    /// `holdDuringSwitch`: the first frame's re-apply (PLY-A1) pauses playback while the TV changes
    /// mode, so the start of the episode isn't heard over a black screen.
    private func applyDisplayCriteriaIfEnabled(holdDuringSwitch: Bool) {
        guard UserDefaults.standard.bool(forKey: PlayerTuning.matchFrameRateKey) else { return }
        // Property reads off-main (this runs at file-load, when the core is busiest), then back
        // to main for the UIWindow / AVDisplayManager application.
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            var fps = self.getDouble("container-fps")
            // HLS and some MP4s carry no container rate: the decoder's estimate stands in.
            if fps <= 0 { fps = self.getDouble("estimated-vf-fps") }
            let width = self.getInt("video-params/w")
            let height = self.getInt("video-params/h")
            let codecName = (self.getString("video-codec") ?? "").lowercased()
            let primaries = (self.getString("video-params/primaries") ?? "").lowercased()
            let gamma = (self.getString("video-params/gamma") ?? "").lowercased()
            DispatchQueue.main.async {
                self.applyDisplayCriteria(
                    fps: fps, width: width, height: height,
                    codecName: codecName, primaries: primaries, gamma: gamma,
                    holdDuringSwitch: holdDuringSwitch
                )
            }
        }
    }

    /// Runs on `eventQueue` after a `video-params/w|h` change (PLY-A1). The criteria applied at
    /// FILE_LOADED usually found no video size yet (the first frame was still decoding) and gave
    /// up, so frame-rate and HDR matching never happened on mpv. Once per file.
    private func applyDisplayCriteriaOnFirstVideoSize() {
        guard displayCriteriaAwaitsVideoSize else { return }
        let snap = cachedProps()
        guard snap.videoW > 0, snap.videoH > 0 else { return }
        displayCriteriaAwaitsVideoSize = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.applyDisplayCriteriaIfEnabled(holdDuringSwitch: true)
        }
    }

    private func applyDisplayCriteria(
        fps: Double, width: Int, height: Int, codecName: String, primaries: String, gamma: String,
        holdDuringSwitch: Bool = false
    ) {
        guard fps > 10, let window = view.window else { return }
        guard width > 0, height > 0 else { return }

        let codecType: CMVideoCodecType =
            (codecName.contains("hevc") || codecName.contains("265")) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        var extensions: [CFString: Any] = [:]
        if primaries.contains("2020") {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        }
        if gamma.contains("pq") {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        } else if gamma.contains("hlg") {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }

        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return }

        displayCriteriaWindow = window
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(fps),
            formatDescription: formatDescription
        )
        if holdDuringSwitch { holdPlaybackDuringDisplaySwitch() }
    }

    /// The mode switch starts a beat after the criteria are set; while it runs (a few seconds of
    /// black on most TVs) playback waits, for `displaySwitchHoldMaxSec` at most. Only a pause this
    /// hold made is undone — a viewer's own pause, or one for leaving the app, stays.
    private func holdPlaybackDuringDisplaySwitch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.mpv != nil, !self.displaySwitchHoldActive,
                  let window = self.displayCriteriaWindow,
                  window.avDisplayManager.isDisplayModeSwitchInProgress,
                  !self.cachedProps().paused, !self.state.isEnded, self.playbackError == nil else { return }
            self.displaySwitchHoldActive = true
            self.setPaused(true)
            print("[MPV] display mode switch in progress: playback held")
            let deadline = ProcessInfo.processInfo.systemUptime + Self.displaySwitchHoldMaxSec
            self.releaseDisplaySwitchHoldWhenDone(deadline: deadline)
        }
    }

    private func releaseDisplaySwitchHoldWhenDone(deadline: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.displaySwitchHoldActive else { return }
            let switching = self.displayCriteriaWindow?.avDisplayManager.isDisplayModeSwitchInProgress ?? false
            if switching, ProcessInfo.processInfo.systemUptime < deadline {
                self.releaseDisplaySwitchHoldWhenDone(deadline: deadline)
                return
            }
            self.displaySwitchHoldActive = false
            // Still paused (the viewer didn't press Play meanwhile): play on.
            if self.cachedProps().paused, self.playbackError == nil, !self.state.isEnded,
               UIApplication.shared.applicationState == .active {
                self.setPaused(false)
            }
        }
    }

    private func clearDisplayCriteria() {
        displayCriteriaWindow?.avDisplayManager.preferredDisplayCriteria = nil
        displayCriteriaWindow = nil
    }

    // MARK: - Leaving the app and audio interruptions (PLY-A8)

    /// The TV button, sleep, the screensaver's app switch and Siri all take the app out of the
    /// foreground. mpv played on there and the stream timed out behind the app ("stream dropped" on
    /// return). An audio interruption (Siri, an AirPlay take-over) pauses it too.
    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForSystem(.resignedActive) }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReturnToForeground() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let optionsRaw = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue
            MainActor.assumeIsolated { self?.handleAudioInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw) }
        })
    }

    private func pauseForSystem(_ reason: SystemPauseReason) {
        guard mpv != nil, !state.isEnded, playbackError == nil else { return }
        // A display-switch hold must not undo this pause when it ends.
        displaySwitchHoldActive = false
        if cachedProps().paused {
            // Already paused by the viewer: nothing to resume later. Leaving the app outranks an
            // interruption that paused first (back in the app, the viewer presses Play).
            if reason == .resignedActive, systemPauseReason != nil { systemPauseReason = .resignedActive }
            return
        }
        print("[MPV] paused: \(reason == .interruption ? "audio interruption" : "app left the foreground")")
        systemPauseReason = reason
        setPaused(true)
        state.controlsVisible = true
    }

    private func didReturnToForeground() {
        guard mpv != nil else { return }
        // The interruption that paused may have deactivated the session; audio needs it active
        // before playback resumes (see `setupMpv`).
        DispatchQueue.global(qos: .userInitiated).async {
            do { try AVAudioSession.sharedInstance().setActive(true) } catch {
                print("[MPV] AVAudioSession re-activation failed: \(error)")
            }
        }
        // The TV may have dropped back to its default mode meanwhile.
        if fileLoaded, view.window != nil, !state.isEnded, pollTimer != nil { applyDisplayCriteriaIfEnabled() }
        if systemPauseReason == .resignedActive { systemPauseReason = nil }
        if cachedProps().paused, fileLoaded { flashControls() }
    }

    private func handleAudioInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            pauseForSystem(.interruption)
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            let resume = systemPauseReason == .interruption && options.contains(.shouldResume)
                && UIApplication.shared.applicationState == .active && view.window != nil
            systemPauseReason = nil
            if resume, cachedProps().paused, playbackError == nil, !state.isEnded {
                print("[MPV] audio interruption ended: resuming")
                setPaused(false)
            }
        @unknown default:
            break
        }
    }

    /// Pause or play without a remote press (system pauses, the display-switch hold, Now Playing).
    /// Same path as the Siri-remote toggle: the cache flips at once, the core on `eventQueue`.
    func setPaused(_ paused: Bool) {
        guard mpv != nil, cachedProps().paused != paused else { return }
        if !paused { systemPauseReason = nil }
        updateProps { $0.paused = paused }
        eventQueue.async { [weak self] in self?.setFlag("pause", paused) }
        refreshState()
    }

    // MARK: - Now Playing commands (PLY-A7)
    //
    // Control Center, the iPhone Remote and Siri reach the player through `MPVNowPlaying`. The Siri
    // Remote's own buttons stay on `pressesBegan`.

    /// A toggle within this window of a pause flip — before or after it — is the Siri Remote press
    /// that flipped it, delivered twice (as a press and as a remote command). It runs once.
    private static let nowPlayingToggleDebounceSec: TimeInterval = 0.4

    func nowPlayingPlay() {
        guard fileLoaded, playbackError == nil, !state.isEnded else { return }
        NextEpisodeEngine.consecutiveAutoPlays = 0
        setPaused(false)
        flashControls()
    }

    func nowPlayingPause() {
        guard mpv != nil else { return }
        NextEpisodeEngine.consecutiveAutoPlays = 0
        setPaused(true)
        flashControls()
    }

    func nowPlayingTogglePause() {
        let arrival = ProcessInfo.processInfo.systemUptime
        guard arrival - lastPauseFlipUptime > Self.nowPlayingToggleDebounceSec else { return }
        // Wait a beat: the press may still be on its way to `pressesBegan`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.lastPauseFlipUptime < arrival - Self.nowPlayingToggleDebounceSec else { return }
            if self.cachedProps().paused { self.nowPlayingPlay() } else { self.nowPlayingPause() }
        }
    }

    func nowPlayingSkip(by seconds: Double) {
        guard mpv != nil, fileLoaded, playbackError == nil else { return }
        NextEpisodeEngine.consecutiveAutoPlays = 0
        // Going back means the viewer is still watching — same rule as the remote's left arrow.
        if seconds < 0 { state.upNextCancel?() }
        eventQueue.async { [weak self] in
            self?.command("seek", args: [String(format: "%.3f", seconds), "relative+exact"])
        }
        flashControls()
    }

    func nowPlayingSeek(to seconds: Double) {
        guard mpv != nil, fileLoaded, playbackError == nil else { return }
        NextEpisodeEngine.consecutiveAutoPlays = 0
        if seconds < state.positionSec { state.upNextCancel?() }
        let target = state.durationSec > 0 ? min(max(seconds, 0), state.durationSec - 0.5) : max(seconds, 0)
        eventQueue.async { [weak self] in
            self?.command("seek", args: [String(format: "%.3f", target), "absolute+exact"])
        }
        flashControls()
    }

    // MARK: - Trakt scrobbling
    //
    // Simplified vs. mobile: scrobble "start" once the file has loaded and its duration is known
    // (PLY-6), "stop" once with the final progress when the player goes away (Trakt marks the item
    // watched at >= 80%). The shared repo resolves IMDB/TMDB ids itself and silently no-ops when
    // Trakt isn't connected. The other connected trackers (Simkl) get the same start and stop
    // through the shared coordinator — see `otherTrackersOpen`.

    func startTraktScrobble() {
        guard !traktScrobbleRequested else { return }
        // Error/placeholder clips (debrid cache-sync stubs, error videos) must not
        // open a Trakt session — mirrors the shared short-placeholder guard.
        if WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(state.durationSec * 1000)) { return }
        traktScrobbleRequested = true
        // Not behind the Trakt item build below: it returns nil for ids Trakt can't address
        // (`kitsu:`, `mal:` …), which Simkl can. Never once the session is closed (the Trakt start
        // below is refused then too): nothing would stop it.
        if !otherTrackersOpen, !traktSessionClosed {
            otherTrackersOpen = true
            scrobbleOtherTrackers(TrackingScrobbleAction.start, percent: traktStartPercent())
        }
        TraktScrobbleRepository.shared.buildItem(
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.progressTitle,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: context.episodeTitle,
            releaseInfo: nil
        ) { [weak self] item, _ in
            // Suspend completions can land off-main; hop before touching controller state.
            DispatchQueue.main.async {
                guard let self, let item, !self.traktSessionClosed else { return }
                self.traktScrobbleItem = item
                TraktScrobbleRepository.shared.scrobbleStart(
                    profileId: ActiveProfileProvider.shared.activeProfileId,
                    item: item,
                    progressPercent: self.traktStartPercent()
                ) { _ in }
                self.resumeTargetSec = nil
            }
        }
    }

    private func stopTraktScrobble() {
        traktSessionClosed = true
        // A session can open before a placeholder's short duration is known; close
        // it at 0% so Trakt never marks the stub watched.
        let short = WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(state.durationSec * 1000))
        // A stream that stopped short of its duration is NOT watched — only a real end or a hand-off
        // (an autoplayed episode left during its credits closes at 100 %).
        let finished = (state.isEnded && state.endedNaturally) || state.completedByHandOff
        let percent: Float = short ? 0 : (finished ? 100 : currentProgressPercent())
        if otherTrackersOpen {
            otherTrackersOpen = false
            // Not for a placeholder clip, nor with the duration unknown (the percentage would read
            // 0): Simkl keeps one paused session per show, so a stop at 0 % would replace the
            // show's real resume point.
            if !short, state.durationSec > 0 { scrobbleOtherTrackers(TrackingScrobbleAction.stop, percent: percent) }
        }
        guard let item = traktScrobbleItem else { return }
        traktScrobbleItem = nil
        TraktScrobbleRepository.shared.scrobbleStop(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            item: item,
            progressPercent: percent
        ) { _ in }
    }

    /// Start/stop for every connected tracker but Trakt (Simkl). The shared coordinator catches every
    /// failure itself (nothing escapes into Swift) and no-ops when no such tracker is connected.
    private func scrobbleOtherTrackers(_ action: TrackingScrobbleAction, percent: Float) {
        TrackingScrobbleCoordinator.shared.scrobbleOtherTrackers(
            profileId: ActiveProfileProvider.shared.activeProfileId,
            action: action,
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            title: context.progressTitle,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: context.episodeTitle,
            progressPercent: Double(percent)
        ) { _ in }
    }

    private func currentProgressPercent() -> Float {
        let duration = state.durationSec
        guard duration > 0 else { return 0 }
        return Float(min(100, max(0, state.positionSec / duration * 100)))
    }

    /// The scrobble start's percentage: the playhead — or where the resume seek lands, while that
    /// seek is still in flight and the playhead still reads the start of the file.
    private func traktStartPercent() -> Float {
        let duration = state.durationSec
        guard duration > 0 else { return 0 }
        var position = state.positionSec
        if let target = resumeTargetSec, position + 5 < target { position = target }
        return Float(min(100, max(0, position / duration * 100)))
    }

    // MARK: - Stream info (diagnostics overlay)

    /// Runs on `eventQueue` (many synchronous property reads). `engine` is passed in because
    /// `state` is main-actor.
    private func buildStreamInfo(engine: String, subtitleDelaySec: Double) -> StreamInfoSnapshot {
        var info = StreamInfoSnapshot()
        // Append the active subtitle delay to the Engine row so a device pass can read it without
        // opening the panel (beta.15 §B2) — e.g. "mpv · subs +1.50 s".
        if subtitleDelaySec != 0 {
            let suffix = "subs " + LocalizedNumberFormat.signedSeconds(subtitleDelaySec)
            info.engine = engine.isEmpty ? suffix : "\(engine) \u{00B7} \(suffix)"
        } else {
            info.engine = engine
        }
        // PLY-A9: say why this session renders through libplacebo.
        if dvReshapeActive {
            let note = "DV P5 \u{00B7} gpu-next"
            info.engine = info.engine.isEmpty ? note : "\(info.engine) \u{00B7} \(note)"
        }
        let w = getInt("video-params/w"), h = getInt("video-params/h")
        if w > 0, h > 0 { info.resolution = "\(w)\u{00D7}\(h)" }
        info.videoCodec = getString("video-codec") ?? ""
        let fps = getDouble("container-fps")
        if fps > 0 { info.fps = LocalizedNumberFormat.frameRate(fps) }
        info.hwdec = getString("hwdec-current") ?? ""
        let vbr = getDouble("video-bitrate")
        if vbr > 0 { info.videoBitrate = LocalizedNumberFormat.bitrate(bitsPerSecond: vbr) }
        let audioCodec = getString("audio-codec-name") ?? ""
        let channels = getInt("audio-params/channel-count")
        let sampleRate = getInt("audio-params/samplerate")
        var audioParts = [audioCodec]
        if channels > 0 { audioParts.append("\(channels)ch") }
        if sampleRate > 0 { audioParts.append("\(sampleRate / 1000) kHz") }
        info.audio = audioParts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        var cacheParts: [String] = []
        let cacheSec = getDouble("demuxer-cache-duration")
        if cacheSec > 0 { cacheParts.append(String(format: "%.0fs buffered", cacheSec)) }
        let cacheSpeed = getDouble("cache-speed")
        if cacheSpeed > 0 { cacheParts.append(LocalizedNumberFormat.transferRate(bytesPerSecond: cacheSpeed)) }
        info.cache = cacheParts.joined(separator: " \u{00B7} ")
        return info
    }

    // MARK: - Watch progress (resume + save)

    private func computeResumePosition() {
        // A native → mpv fallback hands over where the native engine was: resume exactly there,
        // even when the saved entry already counts as completed (NE-7/PLY-8).
        if let startPositionSec, startPositionSec > 1 {
            pendingResumeSec = startPositionSec
            return
        }
        // PLY-A13 Start Over: from 0:00, whatever the saved progress says.
        if context.resumeFromStart { return }
        guard let entry = WatchProgressRepository.shared.progressForVideo(
            videoId: context.videoId,
            parentMetaId: context.parentMetaId,
            seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) }
        ), !entry.isCompleted else { return }
        let seconds = Double(entry.lastPositionMs) / 1000.0
        if seconds > 10 {
            pendingResumeSec = seconds
        } else if entry.lastPositionMs <= 0, entry.durationMs <= 0, entry.progressFraction > 0 {
            pendingResumeFraction = Double(entry.progressFraction)
        }
    }

    // CW-1: the series name + the episode's own name/still, never the "S1E3 · Pilot" header label
    // as the show's title (same record `PlaybackProgressRecorder` writes for the native engine).
    private lazy var session = WatchProgressPlaybackSession(
        profileId: ActiveProfileProvider.shared.activeProfileId,
        contentType: context.contentType,
        parentMetaId: context.parentMetaId,
        parentMetaType: context.contentType,
        videoId: context.videoId,
        title: context.progressTitle,
        logo: context.logo,
        poster: context.poster,
        background: context.background,
        seasonNumber: context.season.map { KotlinInt(int: Int32($0)) },
        episodeNumber: context.episode.map { KotlinInt(int: Int32($0)) },
        episodeTitle: context.episodeTitle,
        episodeThumbnail: context.episodeStill,
        providerName: context.providerName,
        providerAddonId: context.providerAddonId,
        lastStreamTitle: context.streamTitle,
        lastStreamSubtitle: context.streamSubtitle,
        pauseDescription: context.synopsis,
        lastSourceUrl: context.url.absoluteString
    )

    private func saveProgress(flush: Bool = false) {
        guard mpv != nil else { return }
        let duration = state.durationSec
        let position = state.positionSec
        guard duration > 0, position > 1 else { return }

        let snapshot = PlayerPlaybackSnapshot(
            isLoading: false,
            isPlaying: !state.isPaused,
            // The real end of the file, or an Up Next hand-off during the credits: recorded completed
            // whatever the watched fraction, so Continue Watching moves on to the next episode. A
            // stream that dropped mid-way keeps its position instead.
            isEnded: (state.isEnded && state.endedNaturally) || state.completedByHandOff,
            durationMs: Int64(duration * 1000),
            positionMs: Int64(position * 1000),
            bufferedPositionMs: Int64(position * 1000),
            playbackSpeed: Float(state.playbackSpeed),
            videoWidth: Int32(truncatingIfNeeded: cachedProps().videoW),
            videoHeight: Int32(truncatingIfNeeded: cachedProps().videoH)
        )
        if flush {
            // PLY-4: the end-of-file / teardown write reaches the Nuvio account (mobile
            // `flushWatchProgress` parity), and with it the watched mark of a finished episode.
            // The 5 s ticks below stay local; the push is deduplicated.
            WatchProgressRepository.shared.flushPlaybackProgress(session: session, snapshot: snapshot, syncRemote: true)
        } else {
            WatchProgressRepository.shared.upsertPlaybackProgress(session: session, snapshot: snapshot, syncRemote: false)
        }
    }

    // MARK: - State polling

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func refreshState() {
        guard mpv != nil else { return }
        // Cached values only — the mpv core is never touched from the main thread (BUG-2/BUG-3:
        // synchronous reads stall for seconds while the core fills its cache early in playback).
        let snap = cachedProps()

        state.durationSec = snap.duration
        state.positionSec = max(snap.position, 0)
        state.isPaused = snap.paused
        // A failed load leaves the core idle and unpaused — which reads as buffering forever (PLY-1).
        state.isBuffering = playbackError == nil && (snap.cacheWait || (snap.coreIdle && !snap.paused))

        // PLY-6: the first tick that knows the duration opens the Trakt session.
        if traktStartPending, snap.duration > 0 {
            traktStartPending = false
            startTraktScrobble()
        }
        if snap.paused != lastPausedFlag {
            lastPausedFlag = snap.paused
            lastPauseFlipUptime = ProcessInfo.processInfo.systemUptime
            if snap.paused, !snap.eof, !state.isEnded { saveProgress(flush: true) }   // PLY-4
        }

        // Rising-edge detection: eof-reached STAYS true while keep-open holds the last frame, so
        // only propagate transitions — otherwise a dismissed end screen re-presents each tick.
        if snap.eof != lastEofFlag {
            lastEofFlag = snap.eof
            // PLY-1: an end of file that is really a failed source — the stream dropped or is
            // truncated, or a placeholder clip stood in for the video — gets the error card (Retry,
            // another source) instead of the end-of-playback flow, and nothing is recorded as watched.
            if snap.eof, playbackError == nil, let failure = failedSourceAtEndOfFile(snap) {
                showPlaybackError(failure)
                return
            }
            // eof-reached also rises when a debrid/HTTP stream drops or expires mid-way: only an end
            // at the duration is the episode's real end (completed, Trakt 100 %, Up Next chaining).
            state.endedNaturally = !snap.eof
                || UpNextTrigger.isNaturalEnd(positionSec: snap.position, durationSec: snap.duration)
            state.isEnded = snap.eof
            // Record right away (Up Next may hand off at once): completed after a real end, the
            // position reached after a premature one.
            if snap.eof { saveProgress(flush: true) }
        }

        if state.showStreamInfo || state.panelOpen {
            refreshStreamInfoAsync()
        }

        let now = ProcessInfo.processInfo.systemUptime
        if !snap.paused, now - lastSaveUptime > 5 {
            lastSaveUptime = now
            saveProgress()
            logStartupStatsIfNeeded()
        }

        updateSkipPrompt(position: snap.position, durationSec: snap.duration)

        nowPlaying?.update(
            positionSec: state.positionSec,
            durationSec: snap.duration,
            isPlaying: !snap.paused && !state.isEnded && playbackError == nil,
            rate: state.playbackSpeed
        )
    }

    /// First-90s diagnostics for the beta "laggy at first" report: one `[MPVStats]` line per
    /// progress-save tick (~5s) covering cache fill, network draw, and dropped frames. Reads run
    /// on `eventQueue`; grep the sysdiagnose/console output for `[MPVStats]`.
    private func logStartupStatsIfNeeded() {
        guard fileLoadedUptime > 0 else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - fileLoadedUptime
        guard elapsed < 90 else { return }
        let underruns = cacheWaitCount
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let cacheSec = self.getDouble("demuxer-cache-duration")
            let cacheSpeed = self.getDouble("cache-speed")
            let voDropped = self.getInt("frame-drop-count")
            let decDropped = self.getInt("decoder-frame-drop-count")
            print(String(
                format: "[MPVStats] +%.0fs cache=%.1fs net=%.1f MB/s dropped=vo:%d dec:%d underruns=%d",
                elapsed, cacheSec, cacheSpeed / 1_000_000, voDropped, decDropped, underruns
            ))
        }
    }

    /// Rebuilds the Stream Info panel rows off-main (it reads a dozen mpv properties).
    private func refreshStreamInfoAsync() {
        let engine = state.routingNote
        let subtitleDelaySec = state.subtitleDelaySec
        eventQueue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let info = self.buildStreamInfo(engine: engine, subtitleDelaySec: subtitleDelaySec)
            DispatchQueue.main.async {
                if info != self.state.streamInfo { self.state.streamInfo = info }
            }
        }
    }

    // MARK: - Playback errors (PLY-1)

    /// A failed load used to look exactly like buffering: mpv logged the END_FILE error, went idle
    /// unpaused, and the spinner stayed up for good. The error card names the problem and offers
    /// another source, a retry, and — while a slow source is still being waited on — more waiting.
    private func showPlaybackError(_ error: PlayerPlaybackError) {
        guard mpv != nil else { return }
        loadWatchdog?.cancel()
        loadWatchdog = nil
        endSeek()
        playbackError = error
        state.playbackErrorShown = true
        state.isBuffering = false
        state.controlsVisible = false
        // A dead stream must not hold the screensaver off forever.
        UIApplication.shared.isIdleTimerDisabled = false
        presentErrorCardIfNeeded()
    }

    /// The end of file `snap` just reached, when it is a failed source rather than the end of the
    /// episode — except with the Up Next card up: the episode is in its credits there, and the engine's
    /// hand-off carries on as before.
    ///  - Right after this load started, short of the duration: truncated, or dropped at once — with no
    ///    duration known too (nothing real ends seconds after it started).
    ///  - Later, short of a known duration: the connection dropped or the link expired mid-way (FFmpeg
    ///    ends the file there rather than reporting an error). Unknown duration: nothing to be short of.
    ///  - A short error/placeholder clip (a debrid "not cached" video) that played to its end.
    private func failedSourceAtEndOfFile(_ snap: PropSnapshot) -> PlayerPlaybackError? {
        if state.upNextCardUp?() == true { return nil }
        if !UpNextTrigger.isNaturalEnd(positionSec: snap.position, durationSec: snap.duration) {
            if snap.position < loadStartPositionSec + Self.earlyEndSec {
                print("[MPV] end of file at \(Int(snap.position))s, right after the load started — failed stream")
                return PlayerPlaybackError(kind: .endedEarly)
            }
            guard snap.duration > 0 else { return nil }
            print("[MPV] end of file at \(Int(snap.position))s of \(Int(snap.duration))s — the stream dropped")
            return PlayerPlaybackError(kind: .dropped)
        }
        let placeholder = state.isPlaceholderClip?(snap.duration)
            ?? UpNextTrigger.isPlaceholder(durationSec: snap.duration, expectedRuntimeSec: nil)
        guard placeholder else { return nil }
        print("[MPV] a \(Int(snap.duration))s clip played to its end — a placeholder, not the video")
        return PlayerPlaybackError(kind: .placeholder)
    }

    /// Present (or refresh) the card. Presented from this controller like the top panel
    /// (`.overFullScreen`), so the player keeps its session for "Retry".
    private func presentErrorCardIfNeeded() {
        guard let error = playbackError, !leavingFromErrorCard else { return }
        if let host = errorHost {
            host.rootView = makeErrorScreen(error)
            return
        }
        // Something presented here is still animating in or out — the previous card going away after
        // Retry (straight into another refusal), the top panel: once it's done. An `.overFullScreen`
        // dismissal never brings `viewDidAppear` back to present it.
        if let presented = presentedViewController, presented.isBeingPresented || presented.isBeingDismissed {
            presentErrorCardShortly()
            return
        }
        // The top panel can be open over a stream that is still loading: close it first.
        if let panel = presentedViewController as? PlayerPanelPresenting {
            panel.close(animated: false)
            presentErrorCardShortly()
            return
        }
        // Covered by a full-screen cover (the end screen), or not on screen: `viewDidAppear` presents it.
        guard presentedViewController == nil, view.window != nil else { return }
        let host = PlayerErrorHostController(rootView: makeErrorScreen(error))
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        host.onMenu = { [weak self] in
            guard let self else { return }
            let leave = self.onExit
            self.leaveFromErrorCard { leave?() }
        }
        errorHost = host
        present(host, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func presentErrorCardShortly() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.presentErrorCardIfNeeded()
        }
    }

    private func makeErrorScreen(_ error: PlayerPlaybackError) -> PlayerErrorScreen {
        PlayerErrorScreen(
            error: error,
            title: context.title,
            canChooseSource: onChooseAnotherSource != nil,
            onChooseSource: { [weak self] in self?.chooseAnotherSource() },
            onRetry: { [weak self] in self?.retryLoad() },
            onKeepWaiting: { [weak self] in self?.keepWaiting() }
        )
    }

    private func clearPlaybackError() {
        playbackError = nil
        state.playbackErrorShown = false
        guard let host = errorHost else { return }
        errorHost = nil
        host.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            self?.becomeFirstResponder()     // libmpv's controller owns the remote again
            // An error that arrived while this card was going away (Retry straight into another
            // refusal) gets its card now.
            self?.presentErrorCardIfNeeded()
        }
    }

    /// Leave the player from the card (Menu, "Choose Another Source"): the card goes first, then
    /// `action` closes the player. The player sits in a SwiftUI cover, and closing that must not
    /// depend on UIKit also taking down this card, which SwiftUI doesn't own — only the card might go,
    /// stranding a dead player. `playbackError` stays set on the way out: no spinner, no end-of-file
    /// handling, and the Up Next countdown stays held.
    private func leaveFromErrorCard(_ action: @escaping () -> Void) {
        guard !leavingFromErrorCard else { return }
        leavingFromErrorCard = true
        guard let host = errorHost else {
            action()
            return
        }
        errorHost = nil
        guard host.presentingViewController != nil, !host.isBeingPresented, !host.isBeingDismissed else {
            action()
            return
        }
        host.dismiss(animated: false) { [weak self] in
            self?.becomeFirstResponder()
            action()
        }
    }

    /// SwiftUI is removing this player (a hand-off rebuilt it for the next episode, its cover
    /// closed): its card goes with it — never left over the next player, talking to a dead one.
    func tearDownErrorCard() {
        leavingFromErrorCard = true
        guard let host = errorHost else { return }
        errorHost = nil
        guard host.presentingViewController != nil, !host.isBeingDismissed else { return }
        if host.isBeingPresented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { host.dismiss(animated: false) }
        } else {
            host.dismiss(animated: false)
        }
    }

    /// FILE_LOADED reached the main thread: the watchdog stands down, and a "not responding" card
    /// that went up meanwhile goes away — the slow source came through after all.
    private func fileDidLoad() {
        loadWatchdog?.cancel()
        loadWatchdog = nil
        if playbackError?.kind == .timedOut {
            clearPlaybackError()
            UIApplication.shared.isIdleTimerDisabled = !state.isPaused
        }
    }

    private func armLoadWatchdog() {
        loadWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mpv != nil, !self.fileLoaded, self.playbackError == nil else { return }
            print("[MPV] nothing loaded after \(Int(Self.loadTimeoutSec)) s — the source isn't answering")
            self.showPlaybackError(PlayerPlaybackError(kind: .timedOut))
        }
        loadWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeoutSec, execute: work)
    }

    /// Card → "Retry": load the same stream again, from where it stopped (or the resume position,
    /// if it never loaded; where this load started, after a placeholder clip).
    private func retryLoad() {
        guard mpv != nil else { return }
        let resumeAt: Double?
        if !fileLoaded {
            resumeAt = pendingResumeSec
        } else if playbackError?.kind == .placeholder {
            resumeAt = loadStartPositionSec
        } else {
            resumeAt = max(state.positionSec, loadStartPositionSec)
        }
        clearPlaybackError()
        print("[MPV] retrying the stream" + (resumeAt.map { " at \(Int($0))s" } ?? ""))
        pendingResumeSec = (resumeAt ?? 0) > 1 ? resumeAt : nil
        // A fresh load of the file: its per-file setup (`onFileLoaded`) runs again — side-loaded
        // subtitles belong to the file that failed.
        fileLoaded = false
        addedSubtitleUrls.removeAll()
        sideLoadedAddonSubtitles.removeAll()
        didAutoSelectTracks = false
        // The subtitle choice is settled again for the new file (a pick made before the failure is
        // saved, so it comes back).
        subtitleSelectionResolved = false
        subtitleRestoreDeadline?.cancel()
        subtitleRestoreDeadline = nil
        subtitleRestoreDeadlinePassed = false
        traktStartPending = false
        lastEofFlag = false
        updateProps { $0.eof = false; $0.paused = false }
        state.isBuffering = true
        UIApplication.shared.isIdleTimerDisabled = true
        armLoadWatchdog()
        let url = context.url.absoluteString
        eventQueue.async { [weak self] in
            guard let self else { return }
            self.coreOpenedFile = false
            self.lastHttpErrorStatus = nil
            self.pendingSubtitleSelectURL = nil
            // An end of file left mpv paused (keep-open), and a new file would open paused too.
            self.setFlag("pause", false)
            self.displayCriteriaAwaitsVideoSize = true      // PLY-A1: a new file, new criteria
            self.command("loadfile", args: [url, "replace"])
        }
    }

    /// Card → "Keep Waiting" (a slow source): the spinner again, and another watchdog round.
    private func keepWaiting() {
        clearPlaybackError()
        UIApplication.shared.isIdleTimerDisabled = true
        armLoadWatchdog()
    }

    /// Card → "Choose Another Source": the presenter closes the player onto a stream list for this
    /// episode, once the card is down. No picker behind the player → just leave it.
    private func chooseAnotherSource() {
        let leave = onChooseAnotherSource ?? onExit
        leaveFromErrorCard { leave?() }
    }

    // MARK: - Teardown

    deinit {
        loadWatchdog?.cancel()
        subtitleRestoreDeadline?.cancel()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        pollTimer?.invalidate()
        seekTimer?.invalidate()
        subtitleWatcher?.cancel()
        subtitleLoadingWatcher?.cancel()
        playerSettingsWatcher?.cancel()
        // Idempotent final scrobble stop — normally a no-op after viewDidDisappear, but covers
        // teardown paths where the disappearance callback never ran (ME-004).
        stopTraktScrobble()
        // PLY-A10 (contract C2): only this episode's addon subtitles. Up Next prefetches the NEXT
        // episode into the same repository, and the old player's deinit runs after the new one
        // started — a plain `clear()` wiped the next episode's list.
        let subtitleKey = SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId)
        SubtitleRepository.shared.clearIfCurrent(key: subtitleKey)
        destroyPlayer()
    }

    private func destroyPlayer() {
        guard let ctx = mpv else { return }
        mpv = nil
        mpv_terminate_destroy(ctx)
    }

    // MARK: - Event loop

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            while true {
                guard let ev = mpv_wait_event(mpv, 0) else { break }
                let id = ev.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                if id == MPV_EVENT_SHUTDOWN { return }
                if id == MPV_EVENT_FILE_LOADED {
                    self.coreOpenedFile = true
                    self.fileLoadedUptime = ProcessInfo.processInfo.systemUptime
                    self.alangTrace("file-loaded alang=\(self.getString("alang") ?? "-") aid=\(self.getString("aid") ?? "-")")
                    DispatchQueue.main.async {
                        self.fileDidLoad()
                        self.applyPendingResume()
                        self.onFileLoaded()
                    }
                    self.refreshTracksAsync()
                }
                if id == MPV_EVENT_PROPERTY_CHANGE, let data = ev.pointee.data {
                    let prop = UnsafePointer<mpv_event_property>(OpaquePointer(data)).pointee
                    self.handlePropertyChange(userdata: ev.pointee.reply_userdata, prop: prop)
                }
                if id == MPV_EVENT_END_FILE, let data = ev.pointee.data {
                    let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                    if endFile.reason == MPV_END_FILE_REASON_ERROR {
                        let message = String(cString: mpv_error_string(endFile.error))
                        print("[MPV] End file error: \(message)")
                        // PLY-1: this print used to be the only trace of a failed load — the spinner
                        // stayed up for good. An HTTP status logged while opening names the reason.
                        let status = self.coreOpenedFile ? nil : self.lastHttpErrorStatus
                        DispatchQueue.main.async {
                            self.showPlaybackError(PlayerPlaybackError(
                                kind: .failed,
                                detail: PlayerPlaybackError.detail(httpStatus: status, mpvError: message)
                            ))
                        }
                    }
                }
                if id == MPV_EVENT_LOG_MESSAGE,
                   let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(ev.pointee.data)) {
                    let level = String(cString: msg.pointee.level!)
                    let text = String(cString: msg.pointee.text!)
                    if !self.coreOpenedFile, let status = PlayerPlaybackError.httpStatus(inLogLine: text) {
                        self.lastHttpErrorStatus = status
                    }
                    print("[MPV] \(level): \(text)", terminator: "")
                }
            }
        }
    }

    /// Runs on `eventQueue`. Folds a property-change payload into the snapshot; only a
    /// track-count change escalates to the (also off-main) track-list walk.
    private func handlePropertyChange(userdata: UInt64, prop: mpv_event_property) {
        guard let observed = ObservedProp(rawValue: userdata) else { return }

        func asDouble() -> Double? {
            guard prop.format == MPV_FORMAT_DOUBLE, let d = prop.data else { return nil }
            return d.assumingMemoryBound(to: Double.self).pointee
        }
        func asFlag() -> Bool? {
            guard prop.format == MPV_FORMAT_FLAG, let d = prop.data else { return nil }
            return d.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        func asInt() -> Int64? {
            guard prop.format == MPV_FORMAT_INT64, let d = prop.data else { return nil }
            return d.assumingMemoryBound(to: Int64.self).pointee
        }

        switch observed {
        case .timePos:
            if let v = asDouble() { updateProps { $0.position = v } }
        case .duration:
            if let v = asDouble() {
                updateProps { $0.duration = v }
                if v > 0 {
                    DispatchQueue.main.async { [weak self] in self?.applyPendingResumeFraction(duration: v) }
                }
            }
        case .pause:
            if let v = asFlag() { updateProps { $0.paused = v } }
        case .coreIdle:
            if let v = asFlag() { updateProps { $0.coreIdle = v } }
        case .pausedForCache:
            if let v = asFlag() {
                var rising = false
                updateProps { rising = v && !$0.cacheWait; $0.cacheWait = v }
                if rising { cacheWaitCount += 1 }
            }
        case .eofReached:
            if let v = asFlag() { updateProps { $0.eof = v } }
        case .trackCount:
            refreshTracksAsync()
        case .videoW:
            // Unavailable (between files) reads as 0, so a reload never sees the last file's size.
            let v = asInt() ?? 0
            updateProps { $0.videoW = v }
            applyDisplayCriteriaOnFirstVideoSize()
        case .videoH:
            let v = asInt() ?? 0
            updateProps { $0.videoH = v }
            applyDisplayCriteriaOnFirstVideoSize()
        case .aid:
            if let v = asInt() { alangTrace("aid changed -> \(v)") }
        }
    }

    private func applyPendingResume() {
        loadStartPositionSec = pendingResumeSec ?? 0
        if let seconds = pendingResumeSec {
            pendingResumeSec = nil
            // PLY-5: through `eventQueue` like every other seek. This runs at FILE_LOADED, the core's
            // busiest moment — a synchronous `mpv_command` here parked the main thread on the core
            // lock (the BUG-2/BUG-3 rule above `PropSnapshot`).
            resumeTargetSec = seconds
            seekAbsolute(seconds)
            return
        }
        guard pendingResumeFraction != nil else { return }
        resumeFractionAwaitsDuration = true
        applyPendingResumeFraction(duration: cachedProps().duration)
    }

    /// Main thread. Scales `pendingResumeFraction` by the file's duration once the file is loaded and
    /// mpv knows it (at file-loaded, or on the first `duration` change after it), behind the same
    /// 10 s floor as every other resume path. Dropped when playback already got past that floor.
    /// Reads the event-fed property cache and seeks through `eventQueue` (PLY-5, BUG-2/BUG-3: never
    /// a synchronous mpv call on the main thread).
    private func applyPendingResumeFraction(duration: Double) {
        guard resumeFractionAwaitsDuration, let fraction = pendingResumeFraction, duration > 0 else { return }
        resumeFractionAwaitsDuration = false
        pendingResumeFraction = nil
        let seconds = duration * fraction
        guard seconds > 10, cachedProps().position < 10 else { return }
        loadStartPositionSec = seconds
        resumeTargetSec = seconds
        seekAbsolute(seconds)
    }

    // MARK: - libmpv C-interop helpers

    func command(_ command: String, args: [String?] = []) {
        guard mpv != nil else { return }
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        checkError(mpv_command(mpv, &cargs))
    }

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
        let str = String(cString: cstr)
        mpv_free(cstr)
        return str
    }

    func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    func checkError(_ status: CInt) {
        if status < 0 {
            print("[MPV] API error: \(String(cString: mpv_error_string(status)))")
        }
    }
}
