import AVKit
import Combine
import SharedCore
import SwiftUI

// Phase 3 of the hybrid player (+ post-Phase-5 polish): the native AVPlayer playback screen, chosen
// by `PlayerScreen` for Dolby-Vision-eligible files. Shows the shared loading view while the
// on-device remux spins up, then a full AVPlayerViewController (native tvOS transport, scrubbing,
// Now Playing). Watch progress, resume, and Trakt live in `NativePlaybackCoordinator`;
// next-episode autoplay is the `NextEpisodeEngine` owned by `PlayerScreen` (shared with the mpv
// screen, so a fallback keeps its state). A pre-playback failure calls `onFallback` so the
// dispatcher can hand the same context to the mpv player. See docs/tvos-hybrid-player-plan.md.
//
// Unlike the mpv screen — which owns the remote and must draw its own chrome — this screen is the
// system player, extended only through AVKit's own hooks (spec §6.9.2, decision D3):
//  - Title view and the Info tab come from the item's `externalMetadata` (the coordinator).
//  - Content tabs under the scrubber: Episodes (series) and Stream Info, as
//    `customInfoViewControllers`; Chapters from the item's `navigationMarkerGroups` (intro, recap
//    and credits segments).
//  - Transport-bar menus: Sources, Playback Speed and, for an addon subtitle, Subtitle Timing, as
//    `transportBarCustomMenuItems`. Subtitles and Audio stay the system's own popovers (Enhance
//    Dialogue, Reduce Loud Sounds) — the app's swipe-down panel is gone on this engine (D3).
//  - Skip Intro/Outro/Recap ride `contextualActions` (segments from the shared
//    `SkipIntroRepository`, evaluated against playback ticks).
//  - The Up Next card (`UpNextCard`, shared with the mpv screen) is app-drawn and non-focusable; its
//    interactive twins are contextual actions ("Cancel" first, then "Play Now"). OK and Menu cancel
//    and leave for the details page (OK through the host's Select observer when no card action is
//    the focused one), Down plays at once — same as mpv. The system proposal UI is not used (D13).
//  - End of file (`AVPlayerItemDidPlayToEndTime`): the Up Next hand-off, the end screen
//    (`PlayerEndScreen`), or — for a movie or a finale — straight back to the details page.
struct NativePlayerScreen: View {
    let context: PlaybackContext
    /// Up Next orchestration, owned by `PlayerScreen` (survives a native → mpv fallback).
    @ObservedObject var upNext: NextEpisodeEngine
    /// Called with the last known position when the native path can't play — dispatcher → mpv.
    var onFallback: ((Double) -> Void)?
    /// Router decision label (e.g. "Native · DV P7 FEL → 8.1") for the Stream Info tab.
    var routingNote: String?
    /// Leave the player for the details page (the presenter closes its stream picker too).
    /// nil → just dismiss the player.
    var onExitToDetails: (() -> Void)?
    /// Open the stream picker for the next episode. nil → leave the player.
    var onPickNextSource: ((MetaVideo) -> Void)?
    /// True when the presenter can swap playback contexts: the Episodes tab then plays the picked
    /// episode in place (`NextEpisodeEngine.jumpToEpisode`) instead of opening its stream list.
    var canSwitchStreams: Bool
    /// The transport bar's "Sources" item: close the player onto this episode's stream list.
    /// nil → no Sources item.
    var onChooseAnotherSource: (() -> Void)?

    @StateObject private var coordinator: NativePlaybackCoordinator
    @StateObject private var panelModel: PlayerTopPanelModel
    @State private var panelAdapter: NativePlayerPanelAdapter?
    @State private var skipSegments: [SkipSegment] = []
    @State private var skipPrompt: SkipPrompt?
    /// Playback speed picked in the transport bar (1 = normal).
    @State private var playbackRate: Float = 1
    /// The end screen's cover was closed with Menu: leave for the details page once it's gone.
    @State private var endScreenClosedByMenu = false
    @Environment(\.dismiss) private var dismiss

    init(context: PlaybackContext,
         upNext: NextEpisodeEngine,
         onFallback: ((Double) -> Void)? = nil,
         routingNote: String? = nil,
         onExitToDetails: (() -> Void)? = nil,
         onPickNextSource: ((MetaVideo) -> Void)? = nil,
         canSwitchStreams: Bool = false,
         onChooseAnotherSource: (() -> Void)? = nil) {
        self.context = context
        _upNext = ObservedObject(wrappedValue: upNext)
        self.onFallback = onFallback
        self.routingNote = routingNote
        self.onExitToDetails = onExitToDetails
        self.onPickNextSource = onPickNextSource
        self.canSwitchStreams = canSwitchStreams
        self.onChooseAnotherSource = onChooseAnotherSource
        _coordinator = StateObject(wrappedValue: NativePlaybackCoordinator(context: context, engineNote: routingNote))
        // Still the source of the Stream Info rows and of the subtitle-timing support flag, now
        // that the swipe-down panel it used to feed is gone on this engine (D3).
        _panelModel = StateObject(wrappedValue: PlayerTopPanelModel(
            info: PlayerPanelInfo(header: NativeInfoHeader(context: context))))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch coordinator.phase {
            case .preparing:
                // The player's one loading view (PLY-A12): black, then a spinner, then the Dolby
                // Vision caption (`coordinator.preparingLabel`) on a long wait.
                PlayerLoadingView(caption: coordinator.preparingLabel)
            case .playing:
                if let player = coordinator.player {
                    AVPlayerContainer(
                        player: player,
                        // The card supersedes Skip Outro (its "Play Now" is the better skip).
                        skipPrompt: upNext.isCardVisible ? nil : skipPrompt,
                        upNextActions: upNextActions,
                        allowedSubtitleLanguages: coordinator.languagePlan.onlyPreferredLanguages
                            ? coordinator.languagePlan.subtitleFilterLanguages : nil,
                        menu: TransportMenuState(
                            canChooseSource: onChooseAnotherSource != nil,
                            rate: playbackRate,
                            supportsSubtitleDelay: panelModel.supportsSubtitleDelay,
                            subtitleDelayMs: coordinator.subtitleDelayMs),
                        chapters: skipSegments,
                        makeInfoViewControllers: makeInfoViewControllers,
                        onSkip: { [weak coordinator, weak upNext] prompt in
                            // Skip Outro on credits that run to the end of the file = the next
                            // episode now (Up Next), not a seek onto the last frame.
                            if prompt.isCredits, upNext?.skipCreditsToNext(creditsEndSec: prompt.targetSec) == true {
                                return
                            }
                            coordinator?.player?.seek(to: CMTime(seconds: prompt.targetSec, preferredTimescale: 600))
                        },
                        onUpNextAction: { [weak upNext] action in
                            guard let upNext else { return }
                            Self.perform(action, on: upNext)
                        },
                        onSetRate: { rate in setPlaybackRate(rate) },
                        onSetSubtitleDelay: { [weak coordinator] ms in coordinator?.setSubtitleDelay(ms: ms) },
                        onStartOver: { [weak coordinator] in coordinator?.startOver() },
                        onChooseSource: { [weak upNext] in
                            upNext?.cancelForSourceSwitch()
                            onChooseAnotherSource?()
                        },
                        onDownPress: { [weak upNext] in upNext?.handleDown() ?? false },
                        downPressClaimed: { [weak upNext] in (upNext?.phase ?? .hidden) != .hidden },
                        onMenuPress: { [weak upNext] in upNext?.handleMenu() ?? false },
                        onSelectPress: { [weak upNext] in upNext?.beginSystemSelect() },
                        onSelectSettled: { [weak upNext] token in upNext?.resolveSystemSelect(token: token) }
                    )
                    .ignoresSafeArea()
                }
            case .failed:
                // Hand back to the dispatcher, which re-presents the mpv player for this context.
                Color.clear.onAppear {
                    if let onFallback { onFallback(coordinator.lastPositionSec) } else { dismiss() }
                }
            }

            // Up Next card (visual only — the contextual actions above are its interactive twins).
            // Inset above the system's contextual-action pill; the extra bottom offset is
            // device-tuned for tvOS 26.
            if upNext.isCardVisible {
                UpNextCard(engine: upNext, fallbackArtwork: context.background ?? context.poster)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    .padding(.bottom, PlayerChipStyle.edgePadding + Self.contextualActionClearance)
                    .transition(.opacity)
            } else if let jump = upNext.episodeJumpInFlight {
                // An episode picked in the Episodes tab is finding its stream.
                EpisodeJumpStatus(video: jump)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    .padding(.bottom, PlayerChipStyle.edgePadding + Self.contextualActionClearance)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(PlayerChipStyle.animation, value: upNext.phase)
        .onChange(of: coordinator.isPaused) { _, paused in
            // The Up Next countdown pauses with the video.
            upNext.setPaused(paused)
        }
        .onChange(of: coordinator.isEnded) { _, ended in
            if ended {
                // Hand-off, card, end screen — or nothing to continue with: back to details.
                if upNext.playbackDidEnd(natural: coordinator.endedNaturally) == .exit { exitToDetails() }
            } else {
                // Off the last frame again (a seek back, the system player's own Play on the last
                // frame, or Play Again — which re-arms fully).
                upNext.playbackResumedFromEnd()
            }
        }
        .fullScreenCover(isPresented: endScreenPresented, onDismiss: { endScreenDidDismiss() }) {
            PlayerEndScreen(
                engine: upNext,
                title: context.title,
                artwork: context.episodeStill ?? context.background ?? context.poster,
                onNextEpisode: { upNext.playNextFromEndScreen() },
                onChooseSource: { upNext.pickSource() },
                onReplay: { replay() },
                onExit: { upNext.cancelAndExit() }
            )
        }
        .onAppear {
            let adapter = NativePlayerPanelAdapter(coordinator: coordinator, model: panelModel,
                                                   context: context, routingNote: routingNote)
            panelAdapter = adapter
            coordinator.onTick = { [weak adapter] _, _ in
                adapter?.onTick()
            }
            coordinator.onPositionTick = { [weak upNext] position, duration in
                upNext?.onProgress(positionSec: position, durationSec: duration)
                updateSkipPrompt(position: position, durationSec: duration)
            }
            upNext.playerAttached()
            upNext.setPaused(false)
            upNext.onExitRequested = exitAction
            upNext.onPickSourceRequested = pickSourceAction
            upNext.onWillHandOff = { [weak coordinator] in coordinator?.markCompleted() }
            // The end screen's full-screen cover makes this screen disappear (→ `coordinator.stop()`
            // below) and appear again when it closes. Rebuild the pipeline only for "Play Again"
            // (`replay()` cleared the end screen first) — never on the way out: Menu closed the
            // cover, or the engine is leaving (details, a source pick, a hand-off). Restarting there
            // relaunched this same episode (and its remux) right before exiting.
            guard !endScreenClosedByMenu, upNext.endScreen == nil, !upNext.isFinished else { return }
            coordinator.start()
            if skipSegments.isEmpty { fetchSkipSegments() }
        }
        .onDisappear {
            // Also when the end screen covers this screen: the pipeline is released there (progress
            // flushed as completed, Trakt closed) — "Play Again" starts a fresh session.
            coordinator.stop()
        }
    }

    /// Vertical room the system contextual-action pill occupies above the bottom inset on tvOS 26,
    /// so the card sits above it rather than on top of it. Device-tuned.
    private static let contextualActionClearance: CGFloat = 96

    // MARK: - Transport bar and content tabs

    /// Applies a transport-bar speed: `defaultRate` is what Play resumes at; a playing item
    /// switches at once.
    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        guard let player = coordinator.player else { return }
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    /// The content tabs under the scrubber, built once per player controller (their SwiftUI views
    /// observe the live models). Episodes only for a series with an episode list.
    private var makeInfoViewControllers: () -> [UIViewController] {
        let upNext = self.upNext
        let panelModel = self.panelModel
        let coordinator = self.coordinator
        let context = self.context
        let canSwitchStreams = self.canSwitchStreams
        let pickSource = pickSourceAction
        return {
            var tabs: [UIViewController] = []
            if context.season != nil, !upNext.episodes.isEmpty {
                let episodes = PlayerInfoTabHost(rootView: AnyView(
                    PlayerEpisodesTab(engine: upNext, season: context.season, episode: context.episode) { video in
                        if canSwitchStreams {
                            upNext.jumpToEpisode(video)
                        } else {
                            pickSource(video)
                        }
                    }))
                episodes.title = String(localized: "Episodes")
                episodes.preferredContentSize = CGSize(width: 0, height: PlayerEpisodesTab.tabHeight)
                tabs.append(episodes)
            }
            let info = PlayerInfoTabHost(rootView: AnyView(
                PlayerStreamInfoTab(model: panelModel) { [weak coordinator] in
                    coordinator?.remux?.audioTracks.first(where: \.selected).map {
                        AudioTranscoder.deliveredFormatDescription(codec: $0.codec, channels: $0.channels,
                                                                   transcodes: $0.transcodes)
                    }
                }))
            info.title = String(localized: "Stream Info")
            info.preferredContentSize = CGSize(width: 0, height: PlayerStreamInfoTab.tabHeight)
            tabs.append(info)
            return tabs
        }
    }

    // MARK: - Up Next

    /// The contextual actions mirroring the card. "Cancel" comes first: when the system gives the
    /// row focus, a plain Select then cancels (the card's "OK / Menu: cancel"); "Play Now" is one
    /// step right, and Down plays at once from anywhere (`onDownPress`).
    private var upNextActions: [UpNextAction] {
        switch upNext.phase {
        case .upNext: return [.cancel, .playNow]
        case .stillWatching: return [.continueWatching, .cancel]
        case .noStream: return [.cancel, .chooseSource]
        case .hidden: return []
        }
    }

    private static func perform(_ action: UpNextAction, on engine: NextEpisodeEngine) {
        switch action {
        case .cancel: engine.cancelAndExit()
        case .playNow, .continueWatching: engine.playNow()
        case .chooseSource: engine.pickSource()
        }
    }

    private var endScreenPresented: Binding<Bool> {
        Binding(
            get: { upNext.endScreen != nil },
            set: { presented in
                // Only a user dismissal (Menu) lands here while the engine still wants the screen.
                guard !presented, upNext.endScreen != nil else { return }
                endScreenClosedByMenu = true
                upNext.endScreenDismissedByUser()
            }
        )
    }

    /// Runs once the end-screen cover is gone, so leaving for details never races its dismissal.
    private func endScreenDidDismiss() {
        guard endScreenClosedByMenu else { return }
        endScreenClosedByMenu = false
        upNext.cancelAndExit()
    }

    private func replay() {
        upNext.resetForReplay()
        coordinator.replay()
    }

    /// Leave the player for the details page (the presenter's route, else just this player).
    /// Built from values, not from this view: the engine stores it, and capturing the view — which
    /// holds the engine — would retain the engine in a cycle.
    private var exitAction: () -> Void {
        let onExitToDetails = self.onExitToDetails
        let dismiss = self.dismiss
        return {
            if let onExitToDetails {
                onExitToDetails()
            } else {
                dismiss()
            }
        }
    }

    /// Open an episode's stream picker (the presenter's route, else leave the player).
    private var pickSourceAction: (MetaVideo) -> Void {
        let onPickNextSource = self.onPickNextSource
        let exit = exitAction
        return { video in
            if let onPickNextSource {
                onPickNextSource(video)
            } else {
                exit()
            }
        }
    }

    private func exitToDetails() {
        exitAction()
    }

    // MARK: - Skip intro/outro segments (shared repository, same rules as the mpv screen)

    /// Fetch intro/recap/outro segments for a series episode (no-op for movies / missing episode
    /// numbers). Respects the Settings > Playback "Skip Intro" toggle. The outro also times the Up
    /// Next card (credits-aware trigger), and the segments become the Chapters tab.
    private func fetchSkipSegments() {
        guard let season = context.season, let episode = context.episode else { return }
        SkipIntroRepository.shared.getSkipIntervalsForContentId(
            // Routes kitsu:/mal: anime ids to the anime providers (same rules as the mpv screen).
            contentId: context.parentMetaId,
            season: Int32(season),
            episode: Int32(episode),
            requireSkipIntroEnabled: true
        ) { intervals, _ in
            let segments = (intervals ?? []).map { SkipSegment(start: $0.startTime, end: $0.endTime, type: $0.type) }
            print("[NativePlayer] skip segments: \(segments.count)"
                  + (segments.isEmpty ? " (none in intro DB for this episode)" : ""))
            guard !segments.isEmpty else { return }
            DispatchQueue.main.async {
                self.skipSegments = segments
                self.upNext.setSkipSegments(segments)
            }
        }
    }

    /// Offer the skip while inside a segment; the last second is excluded so the action
    /// disappears cleanly at the end (same rule as the mpv screen).
    private func updateSkipPrompt(position: Double, durationSec: Double) {
        // Upstream 80860602f: an error/placeholder clip (shared short-placeholder rule) offers no skip.
        let placeholder = WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000))
        let active = placeholder ? nil
            : skipSegments.first(where: { position >= $0.start && position < $0.end - PlayerChipStyle.lastSecondExclusion })
        let prompt = active.map {
            SkipPrompt(label: Self.skipLabel(for: $0.type), targetSec: $0.end,
                       isCredits: UpNextTrigger.outroTypes.contains($0.type.lowercased()))
        }
        if prompt != skipPrompt { skipPrompt = prompt }
    }

    private static func skipLabel(for type: String) -> String {
        let type = type.lowercased()
        // Every credits type Up Next knows (AniSkip "ed"/"mixed-ed", IntroDB "outro", …).
        if UpNextTrigger.outroTypes.contains(type) { return String(localized: "Skip Outro") }
        return type == "recap"
            ? String(localized: "Skip Recap")
            : String(localized: "player.skip.intro", defaultValue: "Skip Intro",
                     comment: "Player skip button shown during an episode's intro (both engines).")
    }
}

/// Up Next contextual actions (static titles — the countdown lives in `UpNextCard`, because a
/// per-second UIAction title change re-animates the transport bar).
enum UpNextAction: String {
    case cancel, playNow, continueWatching, chooseSource

    var title: String {
        switch self {
        case .cancel: return String(localized: "Cancel")
        case .playNow: return String(localized: "Play Now")
        case .continueWatching: return String(localized: "Continue Watching")
        case .chooseSource: return String(localized: "Choose a Source")
        }
    }

    var symbol: String {
        switch self {
        case .cancel: return "xmark"
        case .playNow: return PlayerChipStyle.nextSymbol
        case .continueWatching: return "play.fill"
        case .chooseSource: return "list.bullet"
        }
    }
}

/// What the transport bar's custom menus show; a change rebuilds them.
private struct TransportMenuState: Equatable {
    var canChooseSource: Bool
    var rate: Float
    var supportsSubtitleDelay: Bool
    var subtitleDelayMs: Int

    // Choices, titles and symbols come from `PlayerTransportMenus` / `PlayerTransportItem`, the
    // description the mpv chrome draws from too.
}

/// Hosts a content tab's SwiftUI view inside the system player's info area.
private final class PlayerInfoTabHost: UIHostingController<AnyView> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}

private struct AVPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let skipPrompt: SkipPrompt?
    let upNextActions: [UpNextAction]
    /// "Show only preferred languages" (Settings → Playback → Subtitles): restrict the system
    /// Subtitles popover to these BCP-47 tags. nil = show every rendition.
    let allowedSubtitleLanguages: [String]?
    let menu: TransportMenuState
    /// Intro / recap / credits segments → the Chapters tab.
    let chapters: [SkipSegment]
    let makeInfoViewControllers: () -> [UIViewController]
    let onSkip: (SkipPrompt) -> Void
    let onUpNextAction: (UpNextAction) -> Void
    let onSetRate: (Float) -> Void
    let onSetSubtitleDelay: (Int) -> Void
    /// Start Over (PLY-A13): back to 0:00.
    let onStartOver: () -> Void
    let onChooseSource: () -> Void
    /// Down press while the Up Next card is up → play now (returns true).
    let onDownPress: () -> Bool
    /// True while the Up Next card is up and would take a Down press; otherwise Down and the down
    /// swipe are left to the system player's content tabs (D3).
    let downPressClaimed: () -> Bool
    /// Menu while the Up Next card is up → cancel and leave for details (returns true) instead of
    /// the plain exit.
    let onMenuPress: () -> Bool
    /// Select while the Up Next card may be up (OK cancels, as on mpv): a token now, settled a beat
    /// later — see `NativePlayerHostController.onSelectPress`.
    let onSelectPress: () -> Int?
    let onSelectSettled: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> NativePlayerHostController {
        let host = NativePlayerHostController()
        host.playerVC.player = player
        player.defaultRate = menu.rate
        // Decision D3: the system content tabs replace the app's swipe-down panel on this engine —
        // `onOpenPanel` stays nil, so Down and the down swipe belong to the system player (and to
        // the Up Next card first, through `onDownPress`).
        host.playerVC.customInfoViewControllers = makeInfoViewControllers()
        // Set once: the closures capture the stable engine weakly.
        host.onMenuPress = onMenuPress
        host.onDownPress = onDownPress
        host.claimsDownPress = downPressClaimed
        host.onSelectPress = onSelectPress
        host.onSelectSettled = onSelectSettled
        return host
    }

    static func dismantleUIViewController(_ host: NativePlayerHostController, coordinator: Coordinator) {
        host.closePanel(animated: false)
    }

    func updateUIViewController(_ host: NativePlayerHostController, context: Context) {
        let controller = host.playerVC
        if controller.player !== player {
            controller.player = player
            player.defaultRate = menu.rate
        }
        // Only assign on change — reassigning identical arrays each SwiftUI tick is pointless work.
        if context.coordinator.allowedSubtitleLanguages != allowedSubtitleLanguages {
            context.coordinator.allowedSubtitleLanguages = allowedSubtitleLanguages
            controller.allowedSubtitleOptionLanguages = allowedSubtitleLanguages
        }
        if context.coordinator.menu != menu {
            context.coordinator.menu = menu
            controller.transportBarCustomMenuItems = transportMenuItems()
        }
        updateChapters(context.coordinator)
        updateContextualActions(controller, context.coordinator)
    }

    // MARK: Transport-bar menus

    /// The app's transport-bar items, from the description both engines share
    /// (`PlayerTransportMenus.customItems` — the mpv chrome draws the same list, then Subtitles and
    /// Audio, which are the system's own buttons here).
    private func transportMenuItems() -> [UIMenuElement] {
        PlayerTransportMenus.customItems(canChooseSource: menu.canChooseSource,
                                         supportsSubtitleDelay: menu.supportsSubtitleDelay)
            .compactMap { menuElement(for: $0) }
    }

    private func menuElement(for item: PlayerTransportItem) -> UIMenuElement? {
        let image = UIImage(systemName: item.symbol)
        switch item {
        case .startOver:
            let startOver = onStartOver
            return UIAction(title: item.title, image: image) { _ in startOver() }
        case .sources:
            let choose = onChooseSource
            return UIAction(title: item.title, image: image) { _ in choose() }
        case .playbackSpeed:
            let setRate = onSetRate
            let current = menu.rate
            let speeds = PlayerTransportMenus.rates.map { rate in
                UIAction(title: PlayerTransportMenus.rateTitle(rate),
                         state: abs(rate - current) < 0.01 ? .on : .off) { _ in setRate(rate) }
            }
            return UIMenu(title: item.title, image: image, options: [.singleSelection], children: speeds)
        case .subtitleTiming:
            let setDelay = onSetSubtitleDelay
            let selected = menu.subtitleDelayMs
            let actions = PlayerTransportMenus.delayChoices(including: selected).map { ms in
                UIAction(title: PlayerTransportMenus.delayTitle(ms), state: ms == selected ? .on : .off) { _ in
                    setDelay(ms)
                }
            }
            return UIMenu(title: item.title, image: image, options: [.singleSelection], children: actions)
        case .subtitles, .audio:
            // The system player's own buttons.
            return nil
        }
    }

    // MARK: Chapters

    private func updateChapters(_ coordinator: Coordinator) {
        guard let item = player.currentItem else { return }
        let signature = "\(ObjectIdentifier(item))|" + chapters.map { "\($0.type)@\($0.start)-\($0.end)" }.joined(separator: ",")
        guard signature != coordinator.chapterSignature else { return }
        coordinator.chapterSignature = signature
        let duration = item.duration.isNumeric ? item.duration.seconds : nil
        item.navigationMarkerGroups = Self.chapterGroups(for: chapters, durationSec: duration)
    }

    /// Chapter markers from the skip segments (`PlayerChapters`, shared with the mpv Chapters tab):
    /// Beginning, Recap, Intro, the episode itself, Credits.
    static func chapterGroups(for segments: [SkipSegment], durationSec: Double?) -> [AVNavigationMarkersGroup] {
        let chapters = PlayerChapters.fromSegments(segments, durationSec: durationSec)
        guard !chapters.isEmpty else { return [] }
        let markers = chapters.map { chapter -> AVTimedMetadataGroup in
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = chapter.title as NSString
            title.extendedLanguageTag = "und"
            let range = CMTimeRange(start: CMTime(seconds: chapter.start, preferredTimescale: 600),
                                    duration: CMTime(seconds: max(chapter.end - chapter.start, 1), preferredTimescale: 600))
            return AVTimedMetadataGroup(items: [title], timeRange: range)
        }
        return [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
    }

    // MARK: Contextual actions

    private func updateContextualActions(_ controller: AVPlayerViewController, _ coordinator: Coordinator) {
        // Reinstall contextual actions only when their meaning changes — reassigning identical
        // actions every SwiftUI update makes the transport bar re-animate them. The skip target is
        // part of the signature so back-to-back segments with the same label still refresh the
        // captured seek position.
        let upNextSignature = upNextActions.map(\.rawValue).joined(separator: ",")
        let skipSignature = skipPrompt.map { "\($0.label)@\($0.targetSec)\($0.isCredits ? "c" : "")" } ?? "-"
        let signature = "\(skipSignature)|\(upNextSignature.isEmpty ? "-" : upNextSignature)"
        guard signature != coordinator.actionsSignature else { return }
        coordinator.actionsSignature = signature

        var actions: [UIAction] = []
        if let prompt = skipPrompt {
            let skip = onSkip
            actions.append(UIAction(title: prompt.label,
                                    image: UIImage(systemName: PlayerChipStyle.skipSymbol)) { _ in skip(prompt) })
        }
        let perform = onUpNextAction
        for upNextAction in upNextActions {
            actions.append(UIAction(title: upNextAction.title,
                                    image: UIImage(systemName: upNextAction.symbol)) { _ in perform(upNextAction) })
        }
        controller.contextualActions = actions
    }

    final class Coordinator {
        var actionsSignature = ""
        var chapterSignature = ""
        var menu: TransportMenuState?
        var allowedSubtitleLanguages: [String]?
    }
}
