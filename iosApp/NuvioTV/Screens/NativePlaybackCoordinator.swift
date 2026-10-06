import AVFoundation
import AVKit
import Combine
import Foundation
import SharedCore

// Phase 3 of the hybrid player: ties Phase 2's remux + loopback server to an AVPlayer for one
// PlaybackContext. Starts the remux, begins playback progressively as soon as the first segment is
// available (rather than waiting for the whole file), and owns the AVPlayer lifecycle — resume seek,
// periodic watch-progress save, and Trakt scrobbling via the shared PlaybackProgressRecorder.
// See docs/tvos-hybrid-player-plan.md.

/// One entry of the native player's Audio menu (D4): a source audio track with a 10-foot display
/// name. `streamIndex` is the avformat stream index handed back to the rebuilt RemuxSession when the
/// user picks this track.
struct NativeAudioTrack: Identifiable, Equatable {
    let streamIndex: Int
    let name: String
    let playable: Bool
    let selected: Bool
    var id: Int { streamIndex }
}

/// Lock-guarded holder for the selected audio stream index (main-thread writes, server-queue reads).
nonisolated final class SelectedAudioBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int?
    var value: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

@MainActor
final class NativePlaybackCoordinator: ObservableObject {
    enum Phase: Equatable {
        case preparing            // remux spinning up / waiting for the first segment
        case playing
        case failed(String)       // pre-playback failure → dispatcher falls back to mpv
    }

    @Published private(set) var phase: Phase = .preparing
    /// Source audio tracks (Info tab rows) — populated once the remux inspects the streams; the
    /// `selected` flag follows the track the remux is producing (the system Audio tab drives
    /// switching — info-panel W3 — through the master's audio renditions).
    @Published private(set) var audioTracks: [NativeAudioTrack] = []
    /// Caption under the preparing spinner — only when the router actually sent a Dolby Vision
    /// file here (PLY-A12: an SDR/HDR10 file no longer claims "Preparing Dolby Vision…"). nil = a
    /// bare spinner.
    @Published private(set) var preparingLabel: String?
    /// Router decision label ("Native · DV P8.1"), from `EngineDecision.displayNote`.
    let engineNote: String?
    private(set) var player: AVPlayer?

    /// Fired ~every few seconds with (position, duration) while playing — the screen refreshes the
    /// Info panel from it.
    var onTick: ((Double, Double) -> Void)?
    /// Fired every 0.5 s with (position, duration) while playing — drives the Up Next trigger and
    /// the skip prompt, which the 3 s `onTick` cadence made land up to 3 s late (NE-2).
    var onPositionTick: ((Double, Double) -> Void)?
    /// The item played to its end (`AVPlayerItemDidPlayToEndTime`, NEXT-5/PLY-9). Cleared by
    /// `replay()` or when playback restarts from the end.
    @Published private(set) var isEnded = false
    /// That end was the episode's real end (`UpNextTrigger.isNaturalEnd`), not playback stopping
    /// short of the duration — only then is the episode recorded as completed. Set before `isEnded`.
    private(set) var endedNaturally = true
    /// Where playback stood when it ended (a restart from there is detected against it).
    private var endPositionSec: Double = 0
    /// "Play Again" rebuilt the session: start from 0 even if a saved position would resume it
    /// (an end short of the duration is not recorded as completed).
    private var resumeFromStart = false
    /// The viewer chose Start Over in the transport bar (PLY-A13): a resume still waiting for the
    /// item's duration must not move playback forward again.
    private var startedOver = false

    /// Last observed position/duration, used when falling back to mpv.
    private(set) var lastPositionSec: Double = 0
    var lastDurationSec: Double = 0
    /// The episode counts as finished (end of file, or an Up Next hand-off during the credits):
    /// the teardown flush records it completed, whatever the last observed position.
    private var completed = false
    private var endObserver: NSObjectProtocol?
    private var positionTask: Task<Void, Never>?

    let context: PlaybackContext
    private let recorder: PlaybackProgressRecorder
    var remux: RemuxSession?
    private var server: LocalHLSServer?
    var playerItem: AVPlayerItem?
    private var pollTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private var servedURL: URL?
    /// 0 = full signaling (RFC 6381 + DV supplemental + range); 1 = minimal (bare sample-entry tag).
    /// A strict AVPlayer that rejects the full form at the master stage gets one retry at minimal.
    private var signalingAttempt = 0

    /// Language preferences (Settings → Playback → Preferred Audio/Subtitle Language + the
    /// forced/only-preferred subtitle options), resolved through the shared KMP helpers so the
    /// native and mpv engines agree. Drives AVPlayer's media-selection criteria, the master's
    /// AUTOSELECT/DEFAULT flags, and the panel's `allowedSubtitleOptionLanguages`.
    struct LanguagePlan: Equatable {
        var audioTargets: [String] = []
        var subtitleTargets: [String] = []
        /// The full preferred-subtitle list (primary + secondary + device), before the shared
        /// plan narrows it for forced-only auto-selection — this is what "Show only preferred
        /// languages" filters the panel's Subtitles list by.
        var subtitleFilterLanguages: [String] = []
        /// Preferred Subtitle Language is "none": never auto-enable subtitles.
        var subtitlesOff = false
        /// Shared plan says forced-only (audio already in a preferred language + "Use forced subtitles").
        var forcedOnly = false
        /// "Use forced subtitles" is on but the audio language is unknown: the shared plan returns
        /// nil to leave player defaults untouched (mpv parity) — no DEFAULT rendition, no legible
        /// criteria; the system's own behaviour + the user decide.
        var leaveToPlayer = false
        /// "Show only preferred languages" — restrict the panel's Subtitles list.
        var onlyPreferredLanguages = false
    }
    @Published var languagePlan = LanguagePlan()
    /// Shared player settings snapshot behind the plan (also drives the "show only preferred
    /// languages" addon-subtitle filter).
    var playerSettings: PlayerSettingsUiState?
    /// The current item's legible selection group, cached async after readyToPlay (Info tab row +
    /// the top panel's Subtitles tab).
    @Published var legibleGroup: AVMediaSelectionGroup?
    /// Bumped whenever AVPlayer's media selection may have changed (notification, tick sync, or a
    /// panel pick) so the top panel recomputes its checkmarks — the notification alone proved
    /// unreliable in the sim.
    @Published var selectionVersion = 0
    /// Subtitle renditions of the current session keyed by NAME (source, forced, SDH) — the top
    /// panel's Subtitles tab groups/labels its rows from this.
    private(set) var subtitleRenditionsByName: [String: SubtitleRendition] = [:]

    // MARK: - Subtitle delay (B3)

    // The native engine re-times subtitles by RE-SERVING the rendition's WebVTT body with every cue
    // shifted. Measured on the tvOS 26.5 simulator (see docs, B3):
    //   • AVPlayer caches a subtitle rendition's MEDIA PLAYLIST for the life of the item — a second
    //     selection of a rendition never refetches `sub-N.m3u8`, so the body URL it names is frozen.
    //   • AVPlayer DOES refetch the VTT BODY on every (re)selection of a legible option, including
    //     one it has loaded before (our responses carry `Cache-Control: no-store`).
    // So the forcing function is simply Off → same option again; the server answers the refetch with
    // the current offset. Six consecutive distinct delays landed, each visible on the very next cue.

    /// Fallback forcing function, OFF by default. If an AVFoundation build ever caches the VTT body
    /// too, publishing each rendition under N interchangeable EXT-X-MEDIA slots makes a delay change
    /// select a URI AVPlayer has never fetched. It costs duplicate entries in the SYSTEM subtitle
    /// popover and caps a session at N distinct delays (slot K is bound to the delay it first
    /// served), which is why the reselect path is preferred. >1 re-enables it.
    static let subtitleDelaySlots = 1
    /// Current subtitle delay in milliseconds (positive = subtitles appear later). Persisted per
    /// `context.videoId` through the shared `PlayerTrackPreferenceStorage`.
    @Published private(set) var subtitleDelayMs = 0
    /// Number of delay changes applied this session — the slot cursor for the fallback path.
    private var subtitleDelayChanges = 0
    /// Coalesces a burst of ±0.1 s presses into one reselect (each one costs AVPlayer a VTT reparse
    /// and blinks the caption off for a frame).
    private var subtitleDelayApplyTask: Task<Void, Never>?
    /// The deferred "same option again" half of a delay refetch; cancelled by any explicit
    /// subtitle selection so a viewer's pick during the window is never overwritten.
    var subtitleRefetchRestoreTask: Task<Void, Never>?
    /// True for the ~60 ms Off→restore hop of a delay refetch, so the panel keeps the Timing row
    /// mounted (unmounting the focused chip would throw tvOS focus — Codex review).
    @Published var isRefetchingSubtitles = false
    /// Paused per `timeControlStatus` (drives the swipe-down hint re-show).
    @Published private(set) var isPaused = false
    private var hasStartedPlaying = false
    private var timeControlObserver: NSKeyValueObservation?
    /// The audio track (stream index) AVPlayer's audible media selection currently names — the
    /// server honours rendition-file requests only for THIS track (info-panel W3), so an in-flight
    /// request for the previous rendition can't switch the worker back. Written on the media-
    /// selection notification, read from the server's connection queue.
    let selectedAudioBox = SelectedAudioBox()
    var mediaSelectionObserver: NSObjectProtocol?
    /// The current item's audible selection group, cached once loaded so every playback tick can
    /// read the selected option synchronously (the notification alone proved unreliable in the sim).
    @Published var audibleGroup: AVMediaSelectionGroup?
    /// Master audio renditions of the current session (option display name → stream index).
    var audioRenditionsByName: [String: Int] = [:]
    /// Trakt scrobble session — start once, stop once.
    private var traktStarted = false
    /// Subtitles fetched from installed subtitle addons (OpenSubtitles etc.) — the same source the
    /// mpv player side-loads. Fetched at start(); playback start is gated (briefly, capped) on the
    /// fetch completing, because the VOD master is rendered exactly once — renditions that arrive
    /// after it are invisible to AVPlayer. Streams rarely attach their own subtitles.
    var addonSubtitles: [SubtitleFile] = []
    private var addonSubsWatcher: FlowWatcher?
    /// Fetch lifecycle: done ONLY when the repo's `completedRequest` state matches this content's
    /// request key (state, not an edge — a fetch that finished before we looked, or was
    /// deduplicated against the stream picker's prefetch, still reads as complete). Addon results
    /// now arrive incrementally (per addon, as each finishes), so a non-empty `addonSubtitles`
    /// list is NOT a completion signal by itself — only `subsFetchCompleted()`'s poll sets this.
    var subsFetchDone = false
    var subsRequestKey = ""
    /// Embedded text tracks offered as renditions this session (Info tab row).
    private var embeddedSubtitleCount = 0

    // MARK: Subtitle choice memory (upstream c9d6f5f63 — `PlayerSubtitleMemory`)

    /// The subtitle choice saved for this title (series-wide), restored on each item once its
    /// legible group has loaded.
    lazy var persistedTrackPreference: PersistedPlayerTrackPreference? =
        PlayerSubtitleMemory.load(parentMetaId: context.parentMetaId)
    /// The addon subtitles as last filtered (raw — the renditions keep only url/language/name), and
    /// the ones the master offers, in order and by URL.
    private var keptAddonSubtitles: [AddonSubtitle] = []
    var masterAddonSubtitles: [AddonSubtitle] = []
    var masterAddonSubtitlesByURL: [String: AddonSubtitle] = [:]
    /// The item the saved choice was applied to (a signaling retry's new item gets it again).
    weak var subtitleRestoreItem: AVPlayerItem?
    /// Once the initial selection has settled, a legible change is the viewer's own (the panel, or
    /// the system Subtitles menu) and is remembered.
    var subtitleChoiceTrackingArmed = false
    var lastSubtitleChoiceName: String?
    var lastAudioChoiceName: String?
    var subtitleChoiceTrackTask: Task<Void, Never>?

    /// An in-player source switch's start position (c69b643a6): used once, at the first
    /// readyToPlay, instead of the saved progress.
    private var explicitStartSec: Double?

    // MARK: Segment resume (PLY-A5)

    /// Kill switch for the segment-aligned resume (defaults on; a Developer toggle can set it off).
    /// Off = the old path: produce from segment 1, start at zero, seek at readyToPlay.
    static let segmentResumeKey = "player.native.segmentResume"
    static var segmentResumeEnabled: Bool {
        UserDefaults.standard.object(forKey: segmentResumeKey) as? Bool ?? true
    }
    /// How long startup waits for the resume segment after the one reposition, before starting
    /// anyway (the JIT server then blocks on it as on any seek).
    private static let resumeSegmentWaitSec: TimeInterval = 20
    /// The resume position planned against the segment map (published as `EXT-X-START`), consumed
    /// at the first readyToPlay.
    private var plannedResumeSec: Double?
    /// Startup clock for the time-to-first-frame log line.
    private var launchStartedAt: Date?
    private var loggedFirstFrame = false

    // MARK: Late addon subtitles (LANG-08)

    /// Addon subtitles that arrived after the master was rendered (the system menu can't show them
    /// this session). Drives the Info row and the panel's "N found after playback started".
    @Published private(set) var lateAddonSubtitleCount = 0
    /// URL keys of every addon subtitle known when the master was rendered.
    private var masterTimeAddonURLKeys: Set<String> = []
    /// Follow-up poll of the addon fetch after playback started.
    private var lateSubsTask: Task<Void, Never>?

    // MARK: Audio choice memory (LANG-09 / STAB-05)

    /// Set once the first audible selection of an item has been relayed: a later change is the
    /// viewer's (system Audio popover or the panel) and is remembered for the show.
    var didRelayInitialAudio = false
    /// Stream index last saved, so the panel pick and the relay that follows it save once.
    var lastSavedAudioStream: Int?

    // MARK: Now Playing metadata (PLY-A7 native half)

    /// Artwork bytes for `externalMetadata`, fetched once per session (the retry item reuses them).
    private var artworkData: Data?
    private var artworkTask: Task<Void, Never>?

    init(context: PlaybackContext, engineNote: String? = nil) {
        self.context = context
        self.recorder = PlaybackProgressRecorder(context: context)
        self.explicitStartSec = context.startPositionSec.flatMap { $0 > 1 ? $0 : nil }
        self.engineNote = engineNote
        // `EngineDecision.reason` for a DV file starts with "DV " ("DV P8.1", "DV P7 FEL → 8.1").
        let isDolbyVision = engineNote?.contains("DV ") ?? false
        self.preparingLabel = isDolbyVision ? String(localized: "Preparing Dolby Vision\u{2026}") : nil
    }

    // MARK: - Lifecycle

    func start() {
        guard remux == nil else { return }
        launchStartedAt = Date()
        loggedFirstFrame = false
        // Addon-subtitle results. The completion signal is polled from `completedRequest` in
        // pollForFirstSegment — no watcher races; this watcher only mirrors the list (its
        // StateFlow replay also delivers results prefetched before this coordinator existed).
        // Settings first: the addon-subtitle watcher below filters by them.
        resolveLanguagePlan(selectedAudioTrack: nil)
        // Persisted subtitle delay for this title/episode (profile-scoped, shared with mobile).
        // Loaded before the server exists, so the very first VTT body is already re-timed.
        subtitleDelayMs = Self.clampSubtitleDelay(
            PlayerTrackPreferenceStorage.shared.loadSubtitleDelayMs(videoId: context.videoId)?.intValue ?? 0)
        if subtitleDelayMs != 0 { print("[NativePlayer] subtitle delay restored: \(subtitleDelayMs)ms") }
        subsRequestKey = SubtitleRepository.shared.requestKey(type: context.contentType, videoId: context.videoId)
        addonSubsWatcher = FlowWatcherKt.watch(SubtitleRepository.shared.addonSubtitles) { [weak self] emitted in
            guard let subs = emitted as? [AddonSubtitle] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // "Show only preferred languages" (shared subtitle-style setting, cloud-synced from
                // mobile): drop non-preferred renditions at the source with the same shared filter
                // the mobile runtime and the mpv screen apply.
                let kept = self.playerSettings.map {
                    PlayerTrackSelectionKt.filterAddonSubtitlesForSettings(subtitles: subs, settings: $0)
                } ?? subs
                self.keptAddonSubtitles = kept
                self.addonSubtitles = kept.map {
                    SubtitleFile(url: $0.url, language: $0.language, name: $0.display)
                }
                if !subs.isEmpty {
                    // Incremental emission: this may be just one addon's results, not the whole
                    // fetch — completion is decided solely by `subsFetchCompleted()` polling
                    // `completedRequest` against `subsRequestKey`, not by this arriving non-empty.
                    print("[NativePlayer] addon subtitles updated: \(subs.count)\(self.server == nil ? "" : " (after master — too late this session)")")
                }
                if self.server != nil { self.updateLateAddonSubtitleCount() }
            }
        }
        SubtitleRepository.shared.fetchAddonSubtitles(type: context.contentType, videoId: context.videoId)
        launchRemux()
    }

    /// Spin up the remux session and the first-segment poll.
    private func launchRemux() {
        // Initial track: let the worker start on the first playable track in a preferred language
        // (Settings → Playback → Preferred Audio Language). Only the active track's rendition is
        // produced, so starting on the right one avoids an immediate switch (the master marks it
        // DEFAULT and the audible criteria agree).
        let audioTargets = languagePlan.audioTargets
        var config = RemuxSession.Config(url: context.url, segmentDurationSec: 6,
                                         requestHeaders: context.requestHeaders)
        // SDH stripping, native path — the mpv path sets `sub-filter-sdh` and reapplies it live in
        // applySubtitleStyle; here the flag is sampled once (embedded cues filter at VTT-segment
        // write, addon files at VTT conversion), so a mid-playback toggle flip deliberately applies
        // from the next playback session — no invalidation machinery.
        config.stripSdh = playerSettings?.subtitleStyle.stripSdh ?? false
        if !audioTargets.isEmpty {
            config.preferredAudioPicker = { tracks in Self.preferredAudioStream(in: tracks, targets: audioTargets) }
        }
        let remux = RemuxSession(config: config)
        self.remux = remux
        remux.start { state in
            guard case .failed(let stage) = state else { return }
            Task { @MainActor [weak self] in self?.failIfPreplayback(stage) }
        }
        pollForFirstSegment(remux: remux)
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        observeTask?.cancel(); observeTask = nil
        positionTask?.cancel(); positionTask = nil
        subtitleDelayApplyTask?.cancel(); subtitleDelayApplyTask = nil
        subtitleRefetchRestoreTask?.cancel(); subtitleRefetchRestoreTask = nil
        subtitleChoiceTrackTask?.cancel(); subtitleChoiceTrackTask = nil
        subtitleChoiceTrackingArmed = false
        lateSubsTask?.cancel(); lateSubsTask = nil
        artworkTask?.cancel(); artworkTask = nil
        if let o = mediaSelectionObserver { NotificationCenter.default.removeObserver(o); mediaSelectionObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        timeControlObserver?.invalidate(); timeControlObserver = nil
        addonSubsWatcher?.cancel(); addonSubsWatcher = nil
        // A finished episode is flushed as completed (position = duration), so a late tick near the
        // end — or the system player restarting the file under the end screen — can't downgrade it.
        let finalPositionSec = completed && lastDurationSec > 0 ? lastDurationSec : lastPositionSec
        if lastDurationSec > 0 {
            recorder.record(positionSec: finalPositionSec, durationSec: lastDurationSec, isPaused: true, speed: 1,
                            flush: true, isEnded: completed)
        }
        recorder.stopTrakt(positionSec: finalPositionSec, durationSec: lastDurationSec)
        player?.pause()
        server?.stop(); server = nil
        remux?.stop()
        // debug.keepRemuxOutput=1 preserves the emitted files so they can be pulled off the device
        // (devicectl copy from the app container) and inspected with ffprobe on a Mac. Cleanup is
        // scheduled on the remux worker's own queue so it runs strictly AFTER the worker exits —
        // a direct removal here can race a final in-flight segment write.
        if let remux {
            if UserDefaults.standard.bool(forKey: "debug.keepRemuxOutput") {
                print("[NativePlayer] kept remux output at \(remux.outputDir.path)")
            } else {
                remux.scheduleCleanup()
            }
        }
        remux = nil
        player = nil
        playerItem = nil
        // The screen re-installs these on appear; dropping them here also breaks the
        // screen ↔ coordinator reference cycle the tick closures form.
        onTick = nil
        onPositionTick = nil
    }

    // MARK: - Progressive startup

    /// Poll the remux output until playback can start: the segment map exists (else the source has no
    /// usable keyframe index → mpv), the init segment is written, and the first media segment is ready
    /// so AVPlayer's opening requests are instant. The playlist is a COMPLETE VOD list from the first
    /// fetch (the JIT server synthesizes it from the map), so there is no EVENT ≥3-segment join rule
    /// anymore; later segments simply block briefly on the JIT server until the remux produces them.
    ///
    /// Resume (PLY-A5): as soon as the map exists, the resume time is mapped to its segment and the
    /// remux is repositioned there ONCE, so "the first media segment" is the resume segment — not
    /// segment 1 followed by a seek that throws that work away.
    private func pollForFirstSegment(remux: RemuxSession) {
        // Subtitle gate (PLY-A6), decided once up front.
        let subsGateSec = subtitleGateSeconds()
        pollTask = Task { @MainActor [weak self] in
            let dir = remux.outputDir
            // The VOD master is rendered exactly once — subtitle renditions must exist by then. Give
            // the addon fetch a short, bounded head start; never hold startup longer.
            let pollStart = Date()
            let subsDeadline = pollStart.addingTimeInterval(subsGateSec)
            if subsGateSec == 0 { print("[NativePlayer] subs gate skipped (subtitles off, no saved addon subtitle)") }
            var resumePlanned = false
            var firstSegment = 1
            var resumeWaitDeadline = Date.distantFuture
            var resumeWaitLapsed = false
            for _ in 0..<240 {                          // ~60s ceiling
                if Task.isCancelled { return }
                if case .failed(let stage) = remux.state { self?.failIfPreplayback(stage); return }
                let map = remux.segmentMap
                if !resumePlanned, let map, let self {
                    resumePlanned = true
                    if let segment = self.planSegmentResume(map: map, remux: remux), segment > 1 {
                        firstSegment = segment
                        resumeWaitDeadline = Date().addingTimeInterval(Self.resumeSegmentWaitSec)
                    }
                }
                let hasMap = map != nil
                let hasInit = Self.fileSize(dir, "init.mp4") > 0
                // A finished remux (short clip that is a single segment) finalizes seg-00001 only at EOF.
                var hasFirst = Self.fileSize(dir, RemuxSession.segmentName(firstSegment)) > 0 || remux.state == .ready
                if !hasFirst, firstSegment > 1, Date() >= resumeWaitDeadline {
                    // Fallback: start anyway. The item still opens at the resume offset and the JIT
                    // server holds that segment's request until the remux produces it.
                    if !resumeWaitLapsed {
                        resumeWaitLapsed = true
                        print("[NativePlayer] resume segment \(firstSegment) not ready after \(Int(Self.resumeSegmentWaitSec))s — starting anyway")
                    }
                    hasFirst = true
                }
                if hasMap && hasInit && hasFirst {
                    if let self, !self.subsFetchCompleted(), Date() < subsDeadline {
                        try? await Task.sleep(nanoseconds: 250_000_000)   // waiting only on subtitles now
                        continue
                    }
                    if let self, !self.subsFetchDone {
                        print("[NativePlayer] subs gate lapsed after \(String(format: "%.1f", Date().timeIntervalSince(pollStart)))s — late addon subtitles are counted, not offered")
                    }
                    self?.beginPlayback(remux: remux)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.failIfPreplayback("no segments produced")
        }
    }

    /// Map the resume position onto the segment map and reposition the remux there (once). Returns
    /// the segment startup should wait for, or nil to start at zero (no resume, flag off, Play Again).
    private func planSegmentResume(map: SegmentMap, remux: RemuxSession) -> Int? {
        plannedResumeSec = nil
        guard Self.segmentResumeEnabled, !resumeFromStart,
              let resume = explicitStartSec ?? recorder.resumePositionSec(durationSec: map.totalDurationSec),
              resume.isFinite, resume > 0, resume < map.totalDurationSec - 1,
              let segment = map.segmentNumber(containing: resume) else { return nil }
        plannedResumeSec = resume
        // A target inside the worker's opening window is simply produced in order (reposition drops it).
        remux.reposition(toSegment: segment)
        print("[NativePlayer] resume \(String(format: "%.1f", resume))s → segment \(segment)/\(map.count)")
        return segment
    }

    /// How long startup may wait for the addon subtitle fetch (PLY-A6). Zero when subtitles are off
    /// and no addon subtitle is the saved choice (nothing would be shown anyway); a little longer
    /// when the saved choice IS an addon subtitle (it can only be restored if it is in the master).
    private func subtitleGateSeconds() -> TimeInterval {
        let savedAddon = persistedTrackPreference?.subtitleType == PersistedSubtitleSelectionType.shared.ADDON
        if languagePlan.subtitlesOff && !savedAddon { return 0 }
        return savedAddon ? 4 : 2.5
    }

    private static func fileSize(_ dir: URL, _ name: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? Int) ?? 0
    }

    private func beginPlayback(remux: RemuxSession) {
        guard phase == .preparing, player == nil else { return }
        guard let map = remux.segmentMap else { failIfPreplayback("no segment map"); return }
        // Audio menu data (D4): the worker published the full track list with its selection when it
        // inspected the streams — always before the map exists, so it's complete here.
        audioTracks = remux.audioTracks.map {
            NativeAudioTrack(streamIndex: $0.streamIndex, name: Self.audioTrackDisplayName($0),
                             playable: $0.playable, selected: $0.selected)
        }
        // External subtitles (D5): stream-attached files plus the addon-fetched list (the same
        // source the mpv player side-loads — streams rarely attach their own), offered as WebVTT
        // renditions in the synthesized master. The server downloads/converts on first selection.
        // Embedded text tracks (info-panel W2) come first — they're the file's own — then the
        // stream's attached files, then addon files ranked by language (LANG-05: preferred targets,
        // then the audio language; at most 4 per language, 24 in all). Language codes are
        // normalized for names and LANGUAGE (LANG-07: "fre" → "fr", "Français").
        let labels = subtitleLanguageLabels(rawLanguages:
            remux.subtitleTracks.compactMap(\.language)
            + context.externalSubtitles.map(\.language)
            + keptAddonSubtitles.map(\.language))
        let embeddedRenditions = SubtitleVTT.embeddedRenditions(tracks: remux.subtitleTracks,
                                                                availableSinks: remux.subtitleSinkIndices, after: [],
                                                                labels: labels)
        let rankedAddon = rankedAddonSubtitles(keptAddonSubtitles,
                                               audioLanguage: remux.audioTracks.first(where: \.selected)?.language)
        let addonFiles = rankedAddon.map { SubtitleFile(url: $0.url, language: $0.language, name: $0.display) }
        let addonRenditions = SubtitleVTT.renditions(from: context.externalSubtitles + addonFiles, labels: labels)
            .map { r in SubtitleRendition(index: r.index + embeddedRenditions.count, name: r.name,
                                          language: r.language, source: r.source) }
        var subtitleRenditions = embeddedRenditions + addonRenditions
        // Names must be unique within the group (AVPlayer keys options by name) — addon names are
        // deduped among themselves; dedupe them against the embedded ones too.
        var seen = Set<String>()
        subtitleRenditions = subtitleRenditions.map { r in
            var name = r.name, n = 2
            while !seen.insert(name).inserted { name = "\(r.name) \(n)"; n += 1 }
            return name == r.name ? r : SubtitleRendition(index: r.index, name: name, language: r.language,
                                                          source: r.source, forced: r.forced, hearingImpaired: r.hearingImpaired)
        }
        embeddedSubtitleCount = embeddedRenditions.count
        subtitleRenditionsByName = Dictionary(subtitleRenditions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // The addon subtitles behind those renditions (subtitle choice memory, c9d6f5f63) — only the
        // ones the master actually offers, so a saved choice is matched among playable entries.
        let offeredURLs = Set(addonRenditions.compactMap { $0.sourceURL?.absoluteString })
        masterAddonSubtitles = rankedAddon.filter { offeredURLs.contains(Self.subtitleURLKey($0.url)) }
        masterAddonSubtitlesByURL = Dictionary(masterAddonSubtitles.map { (Self.subtitleURLKey($0.url), $0) },
                                               uniquingKeysWith: { a, _ in a })
        // Everything known now; whatever the fetch adds later is "late" (LANG-08).
        masterTimeAddonURLKeys = Set(keptAddonSubtitles.map { Self.subtitleURLKey($0.url) })
        lateAddonSubtitleCount = 0
        print("[NativePlayer] subtitle renditions: \(subtitleRenditions.count) (\(embeddedRenditions.count) embedded)"
              + (subtitleRenditions.isEmpty ? "" : " — \(subtitleRenditions.prefix(6).map(\.name).joined(separator: ", "))\(subtitleRenditions.count > 6 ? ", …" : "")"))
        // A device that already fell back to the reduced master form keeps it across an
        // audio-switch rebuild (same video stream — the full form would just fail again).
        var signaling = remux.videoSignaling ?? VideoSignaling(codecs: "")
        if signalingAttempt > 0 { signaling.supplementalCodecs = nil }
        let selectedAudio = remux.audioTracks.first(where: \.selected)
        // Audio renditions (info-panel W3): every playable track, the initially produced one DEFAULT.
        var audioNames = Set<String>()
        let audioRenditions = remux.audioTracks.filter(\.playable).map { track -> AudioRendition in
            // NAME must be unique within the group (two untitled tracks with the same language,
            // codec and layout otherwise collide) — suffix duplicates.
            let base = Self.audioTrackDisplayName(track)
            var name = base, n = 2
            while !audioNames.insert(name).inserted { name = "\(base) \(n)"; n += 1 }
            // LANGUAGE in BCP 47 form (LANG-07): "fre" → "fr", so AVPlayer's criteria and the
            // system Audio popover read it.
            return AudioRendition(streamIndex: track.streamIndex, name: name,
                                  language: TrackLabelFormatter.normalizedTag(track.language) ?? track.language,
                                  channels: track.channels,
                                  codecToken: track.codecToken, isDefault: track.selected)
        }
        audioRenditionsByName = Dictionary(uniqueKeysWithValues: audioRenditions.map { ($0.name, $0.streamIndex) })
        selectedAudioBox.value = selectedAudio?.streamIndex
        // The forced-only decision needs the audio the viewer will hear (shared plan semantics).
        resolveLanguagePlan(selectedAudioTrack: selectedAudio.map { track in
            AudioTrack(
                index: 0, id: String(track.streamIndex),
                label: track.title ?? track.language ?? "",
                language: track.language, isSelected: true)
        })
        let server = LocalHLSServer(rootDir: remux.outputDir, map: map,
                                    signaling: signaling,
                                    audioRenditions: audioRenditions,
                                    activeAudio: { remux.activeAudioStream },
                                    selectedAudio: { [box = selectedAudioBox] in box.value },
                                    requestAudioTrack: { remux.selectAudio(streamIndex: $0, atSegment: $1) },
                                    bandwidth: remux.estimatedBandwidth,
                                    subtitles: subtitleRenditions,
                                    subtitleFlags: subtitleFlags(for: subtitleRenditions),
                                    // SDH stripping, native path (mpv sets sub-filter-sdh instead) —
                                    // applies to the addon-VTT conversions this server performs.
                                    stripSdh: playerSettings?.subtitleStyle.stripSdh ?? false,
                                    producingInfo: { remux.producingInfo },
                                    requestReposition: { remux.reposition(toSegment: $0) },
                                    // Resume (PLY-A5): the item opens at the segment the remux was
                                    // repositioned to — no segment-1 fetch, no first-frame flash.
                                    startOffsetSec: plannedResumeSec)
        self.server = server
        // Subtitle delay (B3): publish each addon rendition under N interchangeable slots so a delay
        // change can be forced past AVPlayer's per-item playlist cache, and bake the restored delay
        // into generation 0 — the first body AVPlayer ever fetches is already re-timed.
        if subtitleRenditions.contains(where: { !$0.isEmbedded }) {
            server.setSubtitleSlots(Self.subtitleDelaySlots)
        }
        if subtitleDelayMs != 0 { server.setSubtitleDelay(ms: subtitleDelayMs) }
        server.start(masterName: remux.masterPlaylistName) { [weak self] url in
            guard let self else { return }
            guard let url else { self.failIfPreplayback("server bind failed"); return }
            print("[NativePlayer] serving \(url.absoluteString)")
            self.servedURL = url
            let item = AVPlayerItem(url: url)
            // Bound how far ahead AVPlayer prefetches: over the infinite-bandwidth loopback origin it
            // would otherwise race minutes past the ~realtime remux frontier and block on segments that
            // don't exist yet, tripping CFNetwork's request timeout.
            item.preferredForwardBufferDuration = 24
            self.prepareItem(item)
            let player = AVPlayer(playerItem: item)
            self.applyLanguagePlan(to: player)
            self.playerItem = item
            self.player = player
            self.audibleGroup = nil
            self.didRelayInitialAudio = false
            // `isPaused` means a pause DURING playback: the pre-playback `.paused` state a fresh
            // player reports before it ever plays is ignored (it would masquerade as a user pause).
            self.hasStartedPlaying = false
            self.timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if status == .playing { self.hasStartedPlaying = true; self.logFirstFrameIfNeeded() }
                    guard self.hasStartedPlaying else { return }
                    let paused = status == .paused
                    if self.isPaused != paused { self.isPaused = paused }
                }
            }
            self.observeMediaSelection(item: item, player: player)
            self.phase = .playing
            self.observePlayback(player: player, item: item)
            #if DEBUG
            self.startSubtitleDelaySpike()
            #endif
            self.startLateSubtitlePoll()
        }
    }

    // MARK: - Startup helpers

    /// Per-item setup shared by the first item and the signaling retry's item: Now Playing /
    /// title-view metadata (PLY-A7) and the subtitle appearance (LANG-06).
    private func prepareItem(_ item: AVPlayerItem) {
        applyExternalMetadata(to: item)
        applySubtitleAppearance(to: item)
    }

    /// Time to first frame, logged once per session (PLY-A5 acceptance: compare with/without the
    /// segment resume — `player.native.segmentResume`).
    private func logFirstFrameIfNeeded() {
        guard !loggedFirstFrame, let launchStartedAt else { return }
        loggedFirstFrame = true
        // `lastPositionSec` holds the resume point here (set at readyToPlay, before play()).
        let resume = lastPositionSec > 0 ? String(format: ", at %.1fs", lastPositionSec) : ""
        print("[NativePlayer] first frame after \(String(format: "%.2f", Date().timeIntervalSince(launchStartedAt)))s"
              + "\(resume)\(Self.segmentResumeEnabled ? "" : " (segment resume off)")")
    }

    /// LANG-08: after the master is rendered, keep watching the addon fetch so the Info row and the
    /// panel can say how many subtitles arrived too late for this session (the VOD master is
    /// rendered once; AVPlayer never re-reads it). Never shows a spinner: the panel's searching
    /// state ends at playback start.
    private func startLateSubtitlePoll() {
        lateSubsTask?.cancel()
        updateLateAddonSubtitleCount()
        guard !subsFetchDone else { return }
        lateSubsTask = Task { @MainActor [weak self] in
            for _ in 0..<90 {                           // ~90 s, then give up quietly
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.updateLateAddonSubtitleCount()
                if self.subsFetchCompleted() {
                    if self.lateAddonSubtitleCount > 0 {
                        print("[NativePlayer] \(self.lateAddonSubtitleCount) addon subtitle(s) arrived after playback started")
                    }
                    return
                }
            }
        }
    }

    func updateLateAddonSubtitleCount() {
        guard server != nil else { return }
        let late = keptAddonSubtitles.filter { !masterTimeAddonURLKeys.contains(Self.subtitleURLKey($0.url)) }.count
        if late != lateAddonSubtitleCount { lateAddonSubtitleCount = late }
    }

    // MARK: - Now Playing / title view metadata (PLY-A7 native half, VIS-06)

    /// `externalMetadata` drives the transport bar's title view, the Info tab, and Now Playing
    /// (Control Center, the iPhone remote). Text items now; the artwork joins when it has loaded.
    private func applyExternalMetadata(to item: AVPlayerItem) {
        let header = NativeInfoHeader(context: context)
        var items: [AVMetadataItem] = [Self.metadataItem(.commonIdentifierTitle, header.title)]
        // "S1 · E4 · Name" — series only (a movie's header subtitle is the release name).
        if context.season != nil, let subtitle = header.subtitle, !subtitle.isEmpty {
            items.append(Self.metadataItem(.iTunesMetadataTrackSubTitle, subtitle))
        }
        if let synopsis = header.synopsis, !synopsis.isEmpty {
            items.append(Self.metadataItem(.commonIdentifierDescription, synopsis))
        }
        if let rating = context.meta?.ageRating, !rating.isEmpty {
            items.append(Self.metadataItem(.iTunesMetadataContentRating, rating))
        }
        if let genres = context.meta?.genres, !genres.isEmpty {
            items.append(Self.metadataItem(.quickTimeMetadataGenre, genres.prefix(3).joined(separator: ", ")))
        }
        if let artworkData { items.append(Self.artworkItem(artworkData)) }
        item.externalMetadata = items
        if artworkData == nil { loadArtwork() }
    }

    /// Fetch the poster once (async), then add it to the current item's metadata.
    private func loadArtwork() {
        guard artworkTask == nil else { return }
        let candidates = [context.poster, context.episodeStill, context.background]
        guard let urlString = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }),
              let url = URL(string: urlString) else { return }
        artworkTask = Task { @MainActor [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let result = try? await URLSession.shared.data(for: request)
            guard let self, !Task.isCancelled else { return }
            guard let result, !result.0.isEmpty,
                  ((result.1 as? HTTPURLResponse)?.statusCode ?? 200) < 400 else {
                print("[NativePlayer] artwork fetch failed (\(url.host ?? "?"))")
                return
            }
            let data = result.0
            self.artworkData = data
            guard let item = self.playerItem else { return }
            item.externalMetadata = item.externalMetadata.filter { $0.identifier != .commonIdentifierArtwork }
                + [Self.artworkItem(data)]
        }
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    private static func artworkItem(_ data: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierArtwork
        item.value = data as NSData
        // PNG magic (0x89 'P' 'N' 'G'); anything else is served as JPEG (TMDB/metahub posters).
        let isPNG = data.count > 4 && data.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47])
        item.dataType = (isPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String
        item.extendedLanguageTag = "und"
        return item
    }

    /// Item failed before playback ever started. Attempt 0 → retry once with minimal signaling
    /// (some AVPlayer builds reject the full CODECS/SUPPLEMENTAL form at the master stage);
    /// attempt 1 → give up and hand the context to mpv.
    private func handlePrePlaybackItemFailure(player: AVPlayer) {
        for name in ["master.m3u8", "media.m3u8"] {
            guard let playlist = server?.renderedPlaylist(named: name) else { continue }
            // Prefix every line so console filters on "NativePlayer" keep the playlist content. The
            // media playlist can be long (one line per segment) — cap the dump.
            let prefixed = playlist.components(separatedBy: "\n").prefix(40)
                .map { "[NativePlayer] | \($0)" }.joined(separator: "\n")
            print("[NativePlayer] served \(name) (\(playlist.count) chars):\n\(prefixed)")
        }
        if let dir = remux?.outputDir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let listing = names.sorted().prefix(24).map { "\($0)=\(Self.fileSize(dir, $0))b" }.joined(separator: " ")
            print("[NativePlayer] output dir: \(listing)")
        }
        guard signalingAttempt == 0, let servedURL else {
            print("[NativePlayer] failing over to mpv (item failed before playback started)")
            phase = .failed("item failed before start")
            return
        }
        signalingAttempt = 1
        // Retry once with reduced signaling: drop only SUPPLEMENTAL-CODECS (some AVPlayer builds
        // reject the DV supplemental form at the master stage). The full RFC 6381 CODECS token and
        // VIDEO-RANGE MUST stay — bare tags are non-compliant, and PQ media without a declared
        // VIDEO-RANGE is itself rejected on tvOS 27 (the retry would fail for the wrong reason).
        var reduced = remux?.videoSignaling ?? VideoSignaling(codecs: "hvc1")
        reduced.supplementalCodecs = nil
        server?.setSignaling(reduced)
        print("[NativePlayer] retrying without SUPPLEMENTAL-CODECS (CODECS=\(reduced.codecs) RANGE=\(reduced.videoRange ?? "-"))")
        observeTask?.cancel()
        // Cache-bust so AVPlayer refetches the master (the server ignores query strings).
        let retryURL = URL(string: servedURL.absoluteString + "?r=1") ?? servedURL
        let item = AVPlayerItem(url: retryURL)
        item.preferredForwardBufferDuration = 24
        prepareItem(item)
        playerItem = item
        legibleGroup = nil
        audibleGroup = nil            // per-item groups; the retry item gets its own observer too
        didRelayInitialAudio = false
        player.replaceCurrentItem(with: item)
        observeMediaSelection(item: item, player: player)
        observePlayback(player: player, item: item)
    }

    // MARK: - End of file + fine-grained position (Up Next)

    /// Observe the item's end (NEXT-5/PLY-9): the native path used to rest on the last frame with no
    /// end-of-playback handling at all. Re-armed per item (the signaling retry swaps items).
    private func observeEnd(item: AVPlayerItem) {
        if let old = endObserver { NotificationCenter.default.removeObserver(old) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handlePlayedToEnd(item: item) }
        }
    }

    private func handlePlayedToEnd(item: AVPlayerItem) {
        guard playerItem === item, phase == .playing, !isEnded else { return }
        let duration = CMTimeGetSeconds(item.duration)
        let current = player.map { CMTimeGetSeconds($0.currentTime()) } ?? duration
        let position = current.isFinite ? current : duration
        // Only an end at the duration is the episode's real end; one well short of it (a source that
        // stopped early) keeps its position and is never recorded — or scrobbled — as watched.
        let natural = UpNextTrigger.isNaturalEnd(positionSec: position, durationSec: duration)
        if duration.isFinite, duration > 0 { lastDurationSec = duration }
        print("[NativePlayer] played to end (\(String(format: "%.1f", position))/\(String(format: "%.1f", lastDurationSec))s)"
              + (natural ? "" : " — short of the duration, not recorded as watched"))
        if natural {
            if lastDurationSec > 0 { lastPositionSec = lastDurationSec }
            completed = true
            if lastDurationSec > 0 {
                recorder.record(positionSec: lastDurationSec, durationSec: lastDurationSec, isPaused: true, speed: 1,
                                flush: true, isEnded: true)
            }
        } else {
            if position.isFinite, position > 0 { lastPositionSec = position }
            if lastDurationSec > 0 {
                recorder.record(positionSec: lastPositionSec, durationSec: lastDurationSec, isPaused: true, speed: 1,
                                flush: true)
            }
        }
        endPositionSec = natural ? lastDurationSec : lastPositionSec
        endedNaturally = natural
        isEnded = true
    }

    /// 0.5 s position ticks for the Up Next trigger/countdown and the skip prompt. Deliberately does
    /// NOT touch `lastPositionSec`: the observe loop's seek detection compares against it at its own
    /// 3 s cadence.
    private func startPositionTicks(player: AVPlayer, item: AVPlayerItem) {
        positionTask?.cancel()
        positionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.player === player, self.playerItem === item else { return }
                guard item.status == .readyToPlay else { continue }
                let position = CMTimeGetSeconds(player.currentTime())
                let duration = CMTimeGetSeconds(item.duration)
                guard position.isFinite, duration.isFinite, duration > 0 else { continue }
                // The system player restarted the file from its end (Play on the last frame):
                // that's a replay, not a finished episode any more.
                if self.isEnded, position < self.endPositionSec - 5 {
                    self.completed = false
                    self.endedNaturally = true
                    self.isEnded = false
                }
                self.onPositionTick?(position, duration)
            }
        }
    }

    /// An Up Next hand-off is about to replace this player: record the episode as completed.
    func markCompleted() {
        completed = true
    }

    /// Start Over (PLY-A13) from the transport bar: back to 0:00, and no pending resume may move
    /// playback forward again. Progress ticks then overwrite the saved position as usual.
    func startOver() {
        startedOver = true
        explicitStartSec = nil
        plannedResumeSec = nil
        guard let player else {
            resumeFromStart = true
            return
        }
        player.seek(to: .zero)
        player.play()
    }

    /// "Play Again" from the end screen. Presenting that full-screen cover makes the player screen
    /// disappear, which stops this coordinator (progress flushed, Trakt closed, remux + server +
    /// player released) — so the replay is normally a fresh session, which the screen's `onAppear`
    /// starts once the cover is gone (resume skips the completed entry: it starts from 0, and opens
    /// a new Trakt scrobble). A pipeline that is still alive just rewinds.
    func replay() {
        completed = false
        endedNaturally = true
        endPositionSec = 0
        if let player {
            isEnded = false
            player.seek(to: .zero)
            player.play()
            return
        }
        phase = .preparing
        lastPositionSec = 0
        lastDurationSec = 0
        traktStarted = false
        hasStartedPlaying = false
        resumeFromStart = true
        if isPaused { isPaused = false }
        legibleGroup = nil
        audibleGroup = nil
        recorder.reopenTrakt()
        isEnded = false
    }

    // MARK: - AVPlayer observation (resume + progress + Trakt)

    private func observePlayback(player: AVPlayer, item: AVPlayerItem) {
        observeEnd(item: item)
        startPositionTicks(player: player, item: item)
        observeTask = Task { @MainActor [weak self] in
            var readied = false
            var waitingTicks = 0
            var notReadyTicks = 0
            var lastProducingSeg = 0
            // A percentage-only row (Simkl episode, Trakt playback) needs the file's duration, which
            // an HLS item may not know yet at readyToPlay: the first tick that knows it resumes it.
            var resumeAwaitsDuration = false
            while !Task.isCancelled {
                guard let self, self.player === player else { return }

                if !readied, item.status == .readyToPlay {
                    readied = true
                    print("[NativePlayer] item readyToPlay")
                    let duration = CMTimeGetSeconds(item.duration)
                    // The segment-aligned plan (PLY-A5) already opened the item at the resume point
                    // via EXT-X-START; the seek below is then a no-op guard (fallback when the
                    // offset was not honoured).
                    let resume = self.resumeFromStart
                        ? nil
                        : (self.plannedResumeSec ?? self.explicitStartSec
                            ?? self.recorder.resumePositionSec(durationSec: duration))
                    resumeAwaitsDuration = resume == nil && !self.resumeFromStart && !(duration.isFinite && duration > 0)
                    self.resumeFromStart = false
                    self.explicitStartSec = nil
                    self.plannedResumeSec = nil
                    let opened = CMTimeGetSeconds(player.currentTime())
                    if let resume, opened.isFinite, abs(opened - resume) <= 1 {
                        print("[NativePlayer] opened at the resume point (\(String(format: "%.1f", opened))s)")
                        self.lastPositionSec = resume
                    } else if let resume {
                        await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                        // The seek suspends this task, and the viewer may have left meanwhile
                        // (stop() cancels it and releases the player): no play() of a torn-down
                        // player, and no scrobble start that nothing would stop.
                        guard !Task.isCancelled, self.player === player else { return }
                        self.lastPositionSec = resume
                    }
                    player.play()
                    if !self.traktStarted {
                        self.traktStarted = true
                        self.recorder.startTrakt(positionSec: self.lastPositionSec, durationSec: duration.isFinite ? duration : 0)
                    }
                    self.loadLegibleSelection(item: item)
                } else if item.status == .failed {
                    print("[NativePlayer] item FAILED — \(item.error?.localizedDescription ?? "unknown")")
                    Self.dumpItemLogs(item)
                    // THIS item never became ready → retry with minimal signaling, then hand to mpv.
                    // (Keyed on the item, not lifetime state: after an audio-switch rebuild the
                    // coordinator has a duration from the previous item, but a pre-ready failure of
                    // the new one still belongs to the signaling retry path.)
                    if !readied {
                        self.handlePrePlaybackItemFailure(player: player)
                    } else {
                        // Failed AFTER playback started — e.g. a forward seek past the linear remux
                        // frontier that the JIT server fast-503'd until AVPlayer gave up. Hand to mpv
                        // (which seeks anywhere via its own demuxer) at the current/target position.
                        self.fallbackMidPlay("item failed mid-play")
                    }
                    return
                } else if !readied {
                    // Blind-spot coverage: the item can sit in .unknown forever (bad playlist, codec
                    // rejection) with no state change to observe. Surface why every ~10s.
                    notReadyTicks += 1
                    if notReadyTicks % 50 == 0 {          // 50 ticks × 200ms ≈ 10s
                        print("[NativePlayer] item still not ready after ~\(notReadyTicks / 5)s (status=\(item.status.rawValue))")
                        Self.dumpItemLogs(item)
                    }
                }

                if readied {
                    if resumeAwaitsDuration {
                        let knownDuration = CMTimeGetSeconds(item.duration)
                        if knownDuration.isFinite, knownDuration > 0 {
                            resumeAwaitsDuration = false
                            // Before this tick records a position over the saved row; dropped when
                            // playback already got past the 10 s resume floor.
                            let current = CMTimeGetSeconds(player.currentTime())
                            if current.isFinite, current < 10, !self.startedOver,
                               let resume = self.recorder.resumePositionSec(durationSec: knownDuration) {
                                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                                // As above: no tick of a player the viewer left during the seek.
                                guard !Task.isCancelled, self.player === player else { return }
                                self.lastPositionSec = resume
                            }
                        }
                    }
                    let pos = CMTimeGetSeconds(player.currentTime())
                    let dur = CMTimeGetSeconds(item.duration)
                    // A position jump = a user seek. Reset the stall budget so back-to-back scrubs
                    // (each costing a ~10s reposition) can't accumulate into a false mpv fallback.
                    if pos.isFinite, abs(pos - self.lastPositionSec) > 10 {
                        waitingTicks = 0
                    }
                    if pos.isFinite, dur.isFinite, dur > 0 {
                        let paused = player.timeControlStatus != .playing
                        self.lastPositionSec = pos
                        self.lastDurationSec = dur
                        self.recorder.record(positionSec: pos, durationSec: dur, isPaused: paused, speed: 1, flush: false,
                                             isBuffering: player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                        self.refreshActiveAudioTrack()
                        if self.audibleGroup == nil { self.handleMediaSelectionChange(item: item, player: player) }
                        else { self.syncAudioSelection(item: item, player: player) }
                        self.onTick?(pos, dur)
                    }

                    // Stall diagnostics: if the player sits in a waiting state across several ticks,
                    // dump why — the item's error log carries segment/format errors (decode
                    // rejections, 404s) that are otherwise invisible outside Xcode.
                    if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        waitingTicks += 1
                        // A stall with the remux still ADVANCING is a seek being refilled at source
                        // speed, not a dead session — reset the budget on every producing-segment
                        // advance. Only a frozen remux (dead source) runs the clock out.
                        let producing = self.remux?.producingInfo.producing ?? 0
                        if producing != lastProducingSeg {
                            lastProducingSeg = producing
                            waitingTicks = 1
                        }
                        if waitingTicks == 3 || waitingTicks % 10 == 3 {
                            let reason = player.reasonForWaitingToPlay?.rawValue ?? "?"
                            print("[NativePlayer] waiting (\(reason)) at \(String(format: "%.1f", CMTimeGetSeconds(player.currentTime())))s")
                            Self.dumpItemLogs(item)
                        }
                        // Sustained stall (~30s at 3s/tick) with NO remux progress: dead/stalled
                        // source. Hand to mpv at the current position rather than spin forever.
                        if waitingTicks >= 10 {
                            self.fallbackMidPlay("stalled ~30s with no remux progress")
                            return
                        }
                    } else {
                        waitingTicks = 0
                    }
                }
                try? await Task.sleep(nanoseconds: readied ? 3_000_000_000 : 200_000_000)
            }
        }
    }

    // MARK: - Subtitle delay

    /// The rendition NAME without the delay-slot suffix the master's twin entries carry.
    static func canonicalSubtitleName(_ name: String) -> String {
        guard let r = name.range(of: LocalHLSServer.slotNameSuffix) else { return name }
        return String(name[..<r.lowerBound])
    }

    /// Which delay slot an option's NAME belongs to (0 = the primary entry shown in the panel).
    static func subtitleSlot(ofName name: String) -> Int {
        guard let r = name.range(of: LocalHLSServer.slotNameSuffix) else { return 0 }
        return Int(name[r.upperBound...]) ?? 0
    }

    static func clampSubtitleDelay(_ ms: Int) -> Int {
        let step = Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_STEP_MS)
        let minMs = Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MIN_MS)
        let maxMs = Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MAX_MS)
        let snapped = step > 0 ? Int((Double(ms) / Double(step)).rounded()) * step : ms
        return max(minMs, min(maxMs, snapped))
    }

    /// Apply a new subtitle delay: persist it immediately, re-time the VTT bodies the local server
    /// hands out, and — when an addon rendition is showing — nudge AVPlayer into refetching that
    /// body. Coalesced, because a viewer walks the value in 0.1 s steps.
    func setSubtitleDelay(ms: Int) {
        let clamped = Self.clampSubtitleDelay(ms)
        guard clamped != subtitleDelayMs else { return }
        subtitleDelayMs = clamped
        PlayerTrackPreferenceStorage.shared.saveSubtitleDelayMs(videoId: context.videoId, delayMs: Int32(clamped))
        server?.setSubtitleDelay(ms: clamped)
        subtitleDelayApplyTask?.cancel()
        subtitleDelayApplyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.forceSubtitleRefetch()
        }
    }

    /// Reset the delay to zero (panel's Reset chip). Writes 0 rather than deleting the key, so a
    /// deliberate reset survives a relaunch instead of falling back to a stale value.
    func resetSubtitleDelay() { setSubtitleDelay(ms: 0) }

    /// Make AVPlayer re-read the selected subtitle rendition's body at the current delay.
    private func forceSubtitleRefetch() {
        guard let item = playerItem, let group = legibleGroup,
              let current = item.currentMediaSelection.selectedMediaOption(in: group) else {
            print("[NativePlayer] subtitle delay \(subtitleDelayMs)ms staged (no rendition showing)")
            return
        }
        let currentName = Self.renditionName(of: current)
        let canonical = Self.canonicalSubtitleName(currentName)
        // Embedded text tracks are per-segment VTTs written by the remux worker as it produces the
        // timeline; they are NOT re-timed by this mechanism (documented gap — B3).
        guard subtitleRenditionsByName[canonical]?.isEmbedded != true else {
            print("[NativePlayer] subtitle delay \(subtitleDelayMs)ms — embedded track, not re-timed")
            return
        }
        subtitleDelayChanges += 1
        // Fallback forcing function (off by default): hop to the next twin slot, a URI AVPlayer has
        // never fetched.
        if Self.subtitleDelaySlots > 1 {
            let nextSlot = subtitleDelayChanges % Self.subtitleDelaySlots
            let targetName = nextSlot == 0 ? canonical : canonical + LocalHLSServer.slotNameSuffix + String(nextSlot)
            if let target = group.options.first(where: { Self.renditionName(of: $0) == targetName }), target != current {
                item.select(target, in: group)
                selectionVersion &+= 1
                print("[NativePlayer] subtitle delay \(subtitleDelayMs)ms applied (slot \(nextSlot))")
                return
            }
        }
        // Off → the same option again. AVPlayer keeps the cached media playlist but refetches the
        // body, which is where the new cue times live.
        isRefetchingSubtitles = true
        item.select(nil, in: group)
        subtitleRefetchRestoreTask?.cancel()
        subtitleRefetchRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            defer { self?.isRefetchingSubtitles = false }
            guard !Task.isCancelled, let self, self.playerItem === item, self.legibleGroup === group else { return }
            // Codex review: a viewer pick during the window wins. Panel picks go through
            // `select(subtitle:)`, which cancels this task; a system-popover pick shows up as a
            // non-nil selection here. (`selectionVersion` can't be the token — our own
            // `select(nil)` bumps it asynchronously.)
            guard item.currentMediaSelection.selectedMediaOption(in: group) == nil else {
                print("[NativePlayer] subtitle delay reselect skipped — selection changed")
                return
            }
            item.select(current, in: group)
            self.selectionVersion &+= 1
            print("[NativePlayer] subtitle delay \(self.subtitleDelayMs)ms applied (reselect ‘\(currentName)’)")
        }
    }

    #if DEBUG
    /// B3 measurement harness. `debug.subDelaySpike` = "6:1500,12:-2000,18:3500" — at T seconds of
    /// wall clock after playback starts, apply a delay of N ms. The first entry is preceded by an
    /// explicit selection of the first addon rendition (the headless smoke run has no UI to pick
    /// one). Read the `[HLS]` request log to see whether AVPlayer refetched playlist + body.
    private func startSubtitleDelaySpike() {
        guard let spec = UserDefaults.standard.string(forKey: "debug.subDelaySpike"), !spec.isEmpty else { return }
        let steps: [(Double, Int)] = spec.split(separator: ",").compactMap {
            let parts = $0.split(separator: ":")
            guard parts.count == 2, let at = Double(parts[0]), let ms = Int(parts[1]) else { return nil }
            return (at, ms)
        }
        guard !steps.isEmpty else { return }
        print("[SubDelaySpike] armed: \(steps.map { "\($0.0)s→\($0.1)ms" }.joined(separator: " "))")
        Task { @MainActor [weak self] in
            // Wait for the legible group, then select the first slot-0 addon rendition.
            for _ in 0..<40 {
                if let self, let group = self.legibleGroup,
                   let first = group.options.first(where: {
                       let name = Self.renditionName(of: $0)
                       return Self.subtitleSlot(ofName: name) == 0
                           && self.subtitleRenditionsByName[Self.canonicalSubtitleName(name)]?.isEmbedded == false
                   }) {
                    self.select(subtitle: first)
                    print("[SubDelaySpike] selected ‘\(Self.renditionName(of: first))’ "
                          + "(group has \(group.options.count) options)")
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            var elapsed = 0.0
            for (at, ms) in steps.sorted(by: { $0.0 < $1.0 }) {
                let wait = max(0, at - elapsed)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                elapsed = at
                guard let self else { return }
                print("[SubDelaySpike] t=\(at)s applying \(ms)ms")
                self.setSubtitleDelay(ms: ms)
            }
            print("[SubDelaySpike] done")
        }
    }
    #endif

    // MARK: - Stream Info tab

    /// Rows for the native player's Stream Info tab: routing decision, remux signaling, segment-map
    /// shape, and live transfer stats from the item's access log. Called on playback ticks.
    /// Follow the remux's active track (the system Audio tab switches it — W3); the published list
    /// only changes when the active track does.
    private func refreshActiveAudioTrack() {
        guard let remux, remux.activeAudioStream != audioTracks.first(where: \.selected)?.streamIndex else { return }
        audioTracks = remux.audioTracks.map {
            NativeAudioTrack(streamIndex: $0.streamIndex, name: Self.audioTrackDisplayName($0),
                             playable: $0.playable, selected: $0.selected)
        }
    }

    func streamInfoRows(routingNote: String?) -> [NativeInfoRow] {
        refreshActiveAudioTrack()
        var rows: [NativeInfoRow] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(NativeInfoRow(label: label, value: value)) }
        }
        var engine = routingNote ?? String(localized: "Native")
        if subtitleDelayMs != 0 {
            // Device-pass readout: the persisted/applied delay, mirroring the mpv Engine row.
            engine += " \u{00B7} subs " + LocalizedNumberFormat.signedSeconds(Double(subtitleDelayMs) / 1000)
        }
        add(String(localized: "Engine"), engine)
        if let s = remux?.videoSignaling {
            add(String(localized: "Video"), s.codecs)
            add("Dolby Vision", s.supplementalCodecs)
            add(String(localized: "Dynamic range"), s.videoRange)
            if s.width > 0, s.height > 0 {
                let fps = s.frameRate > 0 ? " \u{00B7} " + LocalizedNumberFormat.frameRate(Double(s.frameRate)) : ""
                add(String(localized: "Resolution"), "\(s.width)\u{00D7}\(s.height)\(fps)")
            }
        }
        // The display name already carries language · codec · layout · title; the RFC 6381 token
        // adds nothing a viewer needs and pushes the row onto a second line.
        add(String(localized: "Audio"), audioTracks.first(where: \.selected)?.name ?? remux?.audioCodecToken)
        if audioTracks.count == 1 {
            add(String(localized: "Audio tracks"), String(localized: "1 (this file has no alternate audio)"))
        } else if audioTracks.count > 1 {
            let unplayable = audioTracks.filter { !$0.playable }.count
            add(String(localized: "Audio tracks"), unplayable == 0
                ? String(localized: "\(audioTracks.count) · in the Audio tab")
                : String(localized: "\(audioTracks.count) · \(audioTracks.count - unplayable) in the Audio tab (\(unplayable) unsupported)"))
        }
        // What the viewer currently sees: the item's legible selection (system Subtitles tab).
        if let item = playerItem, let group = legibleGroup {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            add(String(localized: "Subtitles"), selected?.displayName ?? String(localized: "Off"))
        }
        // Same self-explanation for subtitles: an empty system menu should read as "the addons
        // had nothing for this title", not as a broken selector.
        if lateAddonSubtitleCount > 0 {
            // LANG-08: the master was rendered before these arrived; AVPlayer can't list them now.
            add(String(localized: "Addon subtitles"),
                String(localized: "player.subtitles.addon.late",
                       defaultValue: "\(masterAddonSubtitles.count) offered · \(lateAddonSubtitleCount) found after playback started",
                       comment: "Native player Info row: addon subtitles in the menu, then how many arrived too late to be offered."))
        } else if subsFetchDone {
            add(String(localized: "Addon subtitles"), addonSubtitles.isEmpty
                ? String(localized: "none found for this title")
                : String(localized: "\(addonSubtitles.count) found"))
        } else if server != nil {
            // Playback started first (PLY-A6 cap): no spinner — anything found now is counted above.
            add(String(localized: "Addon subtitles"),
                String(localized: "player.subtitles.addon.stillSearching",
                       defaultValue: "\(masterAddonSubtitles.count) offered · still searching",
                       comment: "Native player Info row: playback started before the addon subtitle search finished."))
        } else {
            add(String(localized: "Addon subtitles"), String(localized: "searching…"))
        }
        // Subtitle tracks inside the file. Text tracks are offered as renditions (Subtitles tab);
        // bitmap tracks (PGS/VobSub) can't be shown by the native player — say so rather than look
        // broken.
        if let subs = remux?.subtitleTracks, !subs.isEmpty {
            let text = subs.filter(\.isText).count, bitmap = subs.count - text
            if text > 0 {
                add(String(localized: "Embedded subtitles"), embeddedSubtitleCount == text
                    ? String(localized: "\(text) · in the Subtitles tab")
                    : String(localized: "\(embeddedSubtitleCount) of \(text) · in the Subtitles tab"))
            }
            if bitmap > 0 {
                add(String(localized: "Bitmap subtitles"),
                    String(localized: "\(bitmap) PGS/VobSub · not shown natively"))
            }
        }
        if let map = remux?.segmentMap {
            add(String(localized: "Segments"), "\(map.count) \u{00D7} \(map.targetDurationSec)s \u{00B7} \(Self.timeString(map.totalDurationSec))")
        }
        // Bandwidth + transfer stats share rows: the Info tab has a fixed panel height, and the
        // two-column grid fits ten rows, not twelve.
        let event = playerItem?.accessLog()?.events.last
        var bitrate: [String] = []
        if let event, event.indicatedBitrate > 0 {
            bitrate.append(LocalizedNumberFormat.bitrate(bitsPerSecond: event.indicatedBitrate))
        }
        if let bandwidth = remux?.estimatedBandwidth, bandwidth > 0 {
            let declared = LocalizedNumberFormat.decimal(Double(bandwidth) / 1_000_000, fractionDigits: 1)
            bitrate.append(String(localized: "declared \(declared) Mb/s"))
        }
        add(String(localized: "Bitrate"), bitrate.joined(separator: " \u{00B7} "))
        if let event, event.numberOfBytesTransferred > 0 {
            var transfer = LocalizedNumberFormat.fileSize(event.numberOfBytesTransferred)
            if event.numberOfStalls > 0 {
                transfer += " \u{00B7} " + String(localized: "\(event.numberOfStalls) stall(s)")
            }
            add(String(localized: "Transferred"), transfer)
        }
        return rows
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Error + access logs from the item — names the exact URI/status/comment AVPlayer choked on.
    private static func dumpItemLogs(_ item: AVPlayerItem) {
        for event in item.errorLog()?.events ?? [] {
            print("[NativePlayer] errorLog: status=\(event.errorStatusCode) \(event.errorComment ?? "") uri=\(event.uri ?? "")")
        }
        if let access = item.accessLog()?.events.last {
            print("[NativePlayer] accessLog: uri=\(access.uri ?? "?") bytes=\(access.numberOfBytesTransferred) stalls=\(access.numberOfStalls)")
        }
    }

    private func failIfPreplayback(_ stage: String) {
        guard phase != .playing else {
            // Mid-play remux failure (e.g. a truncated debrid source): the remaining segments will
            // never appear, so JIT requests would block until playback stalls. Hand to mpv now rather
            // than wait for the stall watchdog.
            print("[NativePlayer] remux failed MID-PLAY at \(stage) — handing to mpv")
            fallbackMidPlay("remux failed mid-play: \(stage)")
            return
        }
        if case .failed = phase { return }
        print("[NativePlayer] pre-playback failure: \(stage) — falling back to mpv")
        phase = .failed(stage)
    }

    /// Mid-play escalation to mpv: the native path started but can no longer make progress (a seek past
    /// the linear remux frontier, or the source truncated). Flipping `phase` to `.failed` makes
    /// `NativePlayerScreen` call `onFallback(lastPositionSec)`, which re-presents mpv at the same
    /// position — mpv seeks anywhere via its own demuxer. No-op unless we are actually playing.
    private func fallbackMidPlay(_ reason: String) {
        guard phase == .playing else { return }
        observeTask?.cancel()
        positionTask?.cancel()
        print("[NativePlayer] mid-play fallback to mpv at \(String(format: "%.1f", lastPositionSec))s — \(reason)")
        phase = .failed(reason)
    }
}
