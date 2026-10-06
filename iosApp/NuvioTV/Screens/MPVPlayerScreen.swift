import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import MediaAccessibility
import CoreText
import SharedCore

private struct MPVPlayerRepresentable: UIViewControllerRepresentable {
    let context: PlaybackContext
    let state: MPVPlaybackState
    let panelModel: PlayerTopPanelModel
    /// Native → mpv fallback hand-over position (NE-7); nil = resume from saved progress.
    let startPositionSec: Double?
    /// Builds the engine-specific fourth tab at open time (its views observe live state).
    let makeExtraTab: () -> PlayerPanelExtraTab
    let onExit: () -> Void
    /// Error card's "Choose Another Source" (PLY-1); nil = no stream picker behind the player.
    let onChooseAnotherSource: (() -> Void)?
    /// DV Profile 5 forced onto mpv: the session renders through `gpu-next` (contract C1, PLY-A9).
    let forceDVReshape: Bool
    /// Chapter ticks for the transport bar (read from the file once it is loaded).
    let chromeModel: MPVChromeModel

    func makeCoordinator() -> MPVChromeCoordinator { MPVChromeCoordinator() }

    func makeUIViewController(context ctx: Context) -> MPVTVPlayerViewController {
        let controller = MPVTVPlayerViewController(context: context, state: state, startPositionSec: startPositionSec)
        controller.forceDVReshape = forceDVReshape
        controller.onExit = onExit
        controller.onChooseAnotherSource = onChooseAnotherSource
        let state = state, model = panelModel, makeExtraTab = makeExtraTab
        controller.onOpenPanel = { [weak controller] in
            guard let controller, controller.presentedViewController == nil else { return }
            let panel = PlayerPanelHostController(rootView: PlayerTopPanel(model: model, extraTab: makeExtraTab()))
            panel.modalPresentationStyle = .overFullScreen
            panel.modalTransitionStyle = .crossDissolve
            model.onClose = { [weak panel] in panel?.close(animated: true) }
            panel.onClosed = { [weak state] in
                state?.panelOpen = false
                state?.reclaimFocus?()     // libmpv's controller must be first responder again
            }
            state.panelOpen = true
            controller.present(panel, animated: !UIAccessibility.isReduceMotionEnabled)
        }
        ctx.coordinator.attach(controller: controller, state: state, chromeModel: chromeModel)
        return controller
    }

    func updateUIViewController(_ controller: MPVTVPlayerViewController, context: Context) {}

    /// The player is going away (a hand-off's rebuild, its cover closing): no error card outlives it.
    static func dismantleUIViewController(_ controller: MPVTVPlayerViewController, coordinator: MPVChromeCoordinator) {
        coordinator.detach()
        controller.tearDownErrorCard()
    }
}

/// SwiftUI host for the libmpv player + transport overlay; presented full-screen over the stream
/// picker. The `NextEpisodeEngine` (owned by `PlayerScreen`, shared with the native screen) drives
/// the Up Next card near the end of a series episode and the end screen after it.
///
/// NOTE for presenters: when swapping contexts for autoplay, apply `.id(context.id)` so SwiftUI
/// rebuilds this screen (and the libmpv controller) for the new episode.
struct MPVPlayerScreen: View {
    let context: PlaybackContext
    /// Up Next orchestration, owned by `PlayerScreen` (survives a native → mpv fallback).
    @ObservedObject var upNext: NextEpisodeEngine
    /// The presenter can swap playback contexts (episode jump / source switching in the panel).
    let canSwitchStreams: Bool
    /// Native → mpv fallback hand-over position (NE-7/PLY-8).
    let startPositionSec: Double?
    /// Phase 1 routing diagnostic (from `PlayerEngineRouter`) surfaced in Stream Info; playback is
    /// unaffected — this screen always renders via libmpv.
    var routingNote: String? = nil
    /// Leave the player for the details page (the presenter closes its stream picker too).
    /// nil → just dismiss the player.
    var onExitToDetails: (() -> Void)? = nil
    /// Open the stream picker for the next episode. nil → leave the player.
    var onPickNextSource: ((MetaVideo) -> Void)? = nil
    /// The stream failed (error card, PLY-1): close the player onto a stream list for this episode.
    /// nil → no picker behind the player; the card's button just leaves it.
    var onChooseAnotherSource: (() -> Void)? = nil
    /// DV Profile 5 forced onto mpv (contract C1): passed through to the libmpv controller.
    var forceDVReshape: Bool = false

    @StateObject private var state: MPVPlaybackState
    @Environment(\.dismiss) private var dismiss
    @State private var showPauseInfo = false
    @State private var pauseInfoTask: Task<Void, Never>?
    @StateObject private var panelModel: PlayerTopPanelModel
    @State private var panelAdapter: MPVPlayerPanelAdapter?
    /// The end screen's cover was closed with Menu: leave for the details page once it's gone.
    @State private var endScreenClosedByMenu = false
    /// Series · code · episode name for the transport bar and the pause card (AES-8/AES-9).
    private let titleParts: PlaybackTitleParts
    /// "Swipe down for info", flashed at the start of playback until the panel has been used once.
    @State private var showSwipeHint = false
    @State private var swipeHintTask: Task<Void, Never>?
    @State private var didFlashStartHint = false
    /// Measured height of the transport chrome's content (`promptBottomInset`).
    @State private var transportHeight: CGFloat = 0
    /// Chapter ticks for the scrubber (file chapters, else the skip segments).
    @StateObject private var chromeModel = MPVChromeModel()
    /// The first frame is on screen: until then the shared loading view stands in (PLY-A12).
    @State private var firstFrameShown = false

    init(context: PlaybackContext,
         upNext: NextEpisodeEngine,
         canSwitchStreams: Bool,
         startPositionSec: Double? = nil,
         routingNote: String? = nil,
         onExitToDetails: (() -> Void)? = nil,
         onPickNextSource: ((MetaVideo) -> Void)? = nil,
         onChooseAnotherSource: (() -> Void)? = nil,
         forceDVReshape: Bool = false) {
        self.context = context
        titleParts = PlaybackTitleParts(context: context)
        _upNext = ObservedObject(wrappedValue: upNext)
        self.canSwitchStreams = canSwitchStreams
        self.startPositionSec = startPositionSec
        self.routingNote = routingNote
        self.onExitToDetails = onExitToDetails
        self.onPickNextSource = onPickNextSource
        self.onChooseAnotherSource = onChooseAnotherSource
        self.forceDVReshape = forceDVReshape
        _state = StateObject(wrappedValue: MPVPlaybackState(title: context.title))
        _panelModel = StateObject(wrappedValue: PlayerTopPanelModel(
            info: PlayerPanelInfo(header: NativeInfoHeader(context: context))))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MPVPlayerRepresentable(
                context: context, state: state, panelModel: panelModel,
                startPositionSec: startPositionSec,
                makeExtraTab: { [state, upNext, canSwitchStreams, panelModel] in
                    PlayerPanelExtraTab {
                        MPVPlaybackTab(state: state, engine: upNext, canSwitchStreams: canSwitchStreams,
                                       onClose: { panelModel.onClose?() })
                    }
                },
                onExit: { dismiss() },
                onChooseAnotherSource: onChooseAnotherSource,
                forceDVReshape: forceDVReshape,
                chromeModel: chromeModel
            )
            .ignoresSafeArea()

            if !firstFrameShown, !state.playbackErrorShown {
                // Opening the file: the player's one loading view (black, then a spinner, PLY-A12).
                PlayerLoadingView()
                    .transition(.opacity)
            } else if state.isBuffering {
                // A stall mid-playback: the spinner alone, over the frozen frame.
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // System-player chrome (spec §6.9.3). A sustained pause grows its title block with the
            // synopsis (TV-app pause look) instead of a separate card, so nothing is named twice.
            PlayerControlsOverlay(
                state: state,
                titleParts: titleParts,
                pauseDetails: pauseCardVisible ? pauseDetails : nil,
                chapterTicks: chromeModel.tickTimes,
                tabs: PlayerPanelTab.allCases,
                highlightedTab: panelModel.lastTab,
                // Measured, not assumed: the prompts above it clear its real height (Larger Text,
                // a movie's one-line title, the pause details). They follow in step with the bar.
                onContentHeightChange: { height in
                    withAnimation(PlayerChipStyle.animation) { transportHeight = height }
                }
            )
            .opacity(chromeShown ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: chromeShown)

            // AES-9: the "Swipe down for info" hint flashes once playback starts (and rides the
            // pause card), instead of living in the transport bar; gone once the panel was opened.
            // Down opens the panel during a skip prompt too now (Select skips, F6).
            if showSwipeHint, !state.panelOpen, !upNext.isCardVisible, !state.isEnded {
                PlayerSwipeHint().transition(.opacity)
            }

            // Live diagnostics, toggled from the playback-settings panel.
            if state.showStreamInfo, let info = state.streamInfo {
                StreamInfoOverlayView(info: info)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(PlayerChipStyle.edgePadding)
                    .transition(.opacity)
            }

            // Transient prompts, bottom-trailing — same chip family as the native screen's
            // contextual actions (PlayerChipStyle). libmpv owns the remote, so these are drawn
            // non-focusable and act on the remote (see `pressesBegan`); Up Next wins over a skip.
            // The skip chip answers Select while playing (F6), so its Select hint shows only then.
            if upNext.isCardVisible {
                UpNextCard(engine: upNext, fallbackArtwork: context.background ?? context.poster)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    // Clear the transport bar while it's showing.
                    .padding(.bottom, promptBottomInset)
                    .transition(.opacity)
            } else if let prompt = state.skipPrompt {
                PlayerActionChip(label: prompt.label, symbol: PlayerChipStyle.skipSymbol, showsPressHint: !state.isPaused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    // Same clearance as the Up Next card: the chip used to sit on the bar's end.
                    .padding(.bottom, promptBottomInset)
                    .transition(.opacity)
            }
        }
        .animation(PlayerChipStyle.animation, value: state.skipPrompt)
        .animation(PlayerChipStyle.animation, value: upNext.phase)
        .animation(PlayerChipStyle.animation, value: state.controlsVisible)
        .animation(PlayerChipStyle.animation, value: showSwipeHint)
        .animation(.easeInOut(duration: 0.25), value: showPauseInfo)
        .animation(.easeInOut(duration: 0.25), value: state.pauseChromeDismissed)
        .animation(.easeInOut(duration: 0.25), value: state.showStreamInfo)
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
            if let routingNote { state.routingNote = routingNote }
            if panelAdapter == nil {
                panelAdapter = MPVPlayerPanelAdapter(state: state, model: panelModel, context: context)
            }
            wireUpNext()
            // libmpv renders into a bare Metal layer, so tvOS doesn't know video is playing and
            // its idle timer fires the screensaver mid-movie (device report). Hold the idle timer
            // while playback is active — mirroring AVPlayerViewController, which does this
            // automatically — and release it on pause (screen protection) and on dismiss.
            UIApplication.shared.isIdleTimerDisabled = !state.isPaused
        }
        .onChange(of: routingNote) { _, note in state.routingNote = note ?? "" }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            swipeHintTask?.cancel()
        }
        // First frames on screen: flash the swipe hint once (the native screen's start hint).
        .onChange(of: state.isBuffering) { _, buffering in
            guard !buffering, !didFlashStartHint else { return }
            didFlashStartHint = true
            withAnimation(.easeInOut(duration: 0.25)) { firstFrameShown = true }
            flashSwipeHint()
        }
        .onChange(of: state.positionSec) { _, position in
            upNext.onProgress(positionSec: position, durationSec: state.durationSec)
        }
        .onChange(of: state.isEnded) { _, ended in
            if ended {
                // Hand-off, card, end screen — or nothing to continue with: back to details.
                if upNext.playbackDidEnd(natural: state.endedNaturally) == .exit { exitToDetails() }
            } else {
                // Off the last frame again (a seek back, or Play Again — which re-arms fully).
                upNext.playbackResumedFromEnd()
            }
        }
        // The Up Next countdown waits while the top panel — or the error card (PLY-1) — is up: no
        // automatic hand-off may replace the player from under either.
        .onChange(of: state.panelOpen) { _, open in
            upNext.setPanelOpen(open || state.playbackErrorShown)
            // The viewer found the panel: the swipe hint has done its job (AES-9).
            if open {
                PlayerSwipeHint.markLearned()
                hideSwipeHint()
            }
        }
        .onChange(of: state.playbackErrorShown) { _, shown in upNext.setPanelOpen(shown || state.panelOpen) }
        .onChange(of: state.isPaused) { _, paused in
            // The Up Next countdown pauses with the video.
            upNext.setPaused(paused)
            // Paused → let the idle timer run again (a long-paused frame should be allowed to
            // hand off to the screensaver, same as the native player); playing → hold it.
            UIApplication.shared.isIdleTimerDisabled = !paused
            pauseInfoTask?.cancel()
            if paused {
                pauseInfoTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { return }
                    showPauseInfo = true
                }
            } else {
                showPauseInfo = false
            }
        }
    }

    /// The pause card is on screen: a sustained pause, not buffering, not the last frame, no Up
    /// Next card over it, and Back hasn't put the pause chrome away (F3).
    private var pauseCardVisible: Bool {
        showPauseInfo && state.isPaused && !state.isBuffering && !state.isEnded && !upNext.isCardVisible
            && !state.playbackErrorShown && !state.pauseChromeDismissed && !state.isScrubbing
    }

    /// The transport chrome is on screen: shown by the controller, or held by a sustained pause
    /// (spec §6.9.3: the chrome never hides while paused).
    private var chromeShown: Bool {
        firstFrameShown && !state.playbackErrorShown && (state.controlsVisible || pauseCardVisible)
    }

    /// What the sustained-pause title block adds: the synopsis, the time left and the source.
    private var pauseDetails: PlayerPauseDetails {
        PlayerPauseDetails(
            synopsis: CachedTitleArt.nonEmpty(context.synopsis),
            remaining: state.durationSec > 0
                ? String(localized: "\(Self.remainingString(state.durationSec - state.positionSec)) remaining")
                : nil,
            provider: CachedTitleArt.nonEmpty(context.providerName))
    }

    /// "42 min" / "1 h 12 min". Whole minutes, truncated, so 59:59 never rounds up to "60 min".
    private static func remainingString(_ remaining: Double) -> String {
        let clamped = max(remaining, 0)
        let seconds = clamped.isFinite ? (clamped / 60).rounded(.down) * 60 : 0
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: seconds) ?? ""
    }

    /// Bottom inset of the bottom-trailing prompts (Up Next card, skip chip): the screen-edge inset,
    /// or — while the transport chrome shows — its measured height plus a gap, so they sit just
    /// above it instead of on it.
    private var promptBottomInset: CGFloat {
        guard chromeShown else { return PlayerChipStyle.edgePadding }
        return max(PlayerChipStyle.edgePadding, transportHeight + Theme.Spacing.lg)
    }

    /// Shows the swipe hint for a few seconds after a beat — until the viewer has opened the panel
    /// once (`PlayerSwipeHint.isLearned`), same timing as the native screen.
    private func flashSwipeHint() {
        guard !PlayerSwipeHint.isLearned else { return }
        swipeHintTask?.cancel()
        swipeHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            showSwipeHint = true
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            showSwipeHint = false
        }
    }

    private func hideSwipeHint() {
        swipeHintTask?.cancel()
        showSwipeHint = false
    }

    /// Hooks between this screen, its libmpv controller (via `state`) and the shared engine.
    /// Re-installed on every appearance — after a native → mpv fallback they replace the native
    /// screen's.
    private func wireUpNext() {
        upNext.playerAttached()
        upNext.setPaused(state.isPaused)
        upNext.onExitRequested = exitAction
        upNext.onPickSourceRequested = pickSourceAction
        upNext.onWillHandOff = { [weak state] in state?.completedByHandOff = true }
        upNext.onPrefetchingNextSubtitles = { [weak state] in state?.freezeAddonSubtitles = true }
        state.upNextSelect = { [weak upNext] in upNext?.handleSelect() ?? false }
        state.upNextDown = { [weak upNext] in upNext?.handleDown() ?? false }
        state.upNextMenu = { [weak upNext] in upNext?.handleMenu() ?? false }
        state.upNextCancel = { [weak upNext] in upNext?.dismissForSession() }
        state.upNextSkipCredits = { [weak upNext] creditsEnd in
            upNext?.skipCreditsToNext(creditsEndSec: creditsEnd) ?? false
        }
        state.onSkipSegmentsLoaded = { [weak upNext, weak chromeModel] segments in
            upNext?.setSkipSegments(segments)
            // The scrubber marks the segments when the file has no chapters of its own.
            chromeModel?.segmentBounds = Array(Set(segments.flatMap { [$0.start, $0.end] })).sorted()
        }
        state.upNextCardUp = { [weak upNext] in upNext?.isCardVisible ?? false }
        state.isPlaceholderClip = { [weak upNext] durationSec in
            upNext?.isPlaceholderClip(durationSec: durationSec)
                ?? UpNextTrigger.isPlaceholder(durationSec: durationSec, expectedRuntimeSec: nil)
        }
        upNext.setPanelOpen(state.panelOpen || state.playbackErrorShown)
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
        if endScreenClosedByMenu {
            endScreenClosedByMenu = false
            upNext.cancelAndExit()
        } else {
            state.reclaimFocus?()      // libmpv's controller must be first responder again
        }
    }

    private func replay() {
        upNext.resetForReplay()
        state.replay?()
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

    /// Open the next episode's stream picker (the presenter's route, else leave the player).
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
}

// MARK: - Chrome data and subtitle look

/// Keeps the libmpv screen's chrome data and subtitle look in step with the open file: the file's
/// chapters for the scrubber ticks (spec §6.9.3), and the system caption style on top of the
/// Settings one (spec §8.3, gap 17), re-asserted whenever playback (re)starts and whenever the
/// viewer changes Settings › Accessibility › Subtitles & Captioning.
final class MPVChromeCoordinator {
    private weak var controller: MPVTVPlayerViewController?
    private weak var chromeModel: MPVChromeModel?
    private var cancellables: Set<AnyCancellable> = []
    private var captionObserver: NSObjectProtocol?
    private var chaptersRead = false

    func attach(controller: MPVTVPlayerViewController, state: MPVPlaybackState, chromeModel: MPVChromeModel) {
        self.controller = controller
        self.chromeModel = chromeModel
        // Playback (re)started after opening the file or a seek: the file is open by then.
        state.$isBuffering
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.playbackStarted() }
            .store(in: &cancellables)
        captionObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.controller?.applySubtitleAppearance() }
        }
    }

    func detach() {
        cancellables.removeAll()
        if let captionObserver { NotificationCenter.default.removeObserver(captionObserver) }
        captionObserver = nil
    }

    private func playbackStarted() {
        guard let controller, controller.fileLoaded else { return }
        controller.applySubtitleAppearance()
        if !chaptersRead {
            chaptersRead = true
            let chapters = controller.chapterTimes()
            if !chapters.isEmpty { chromeModel?.chapterTimes = chapters }
        }
    }
}

extension MPVTVPlayerViewController {
    /// The file's chapter starts in seconds (mpv `chapter-list`), the opening one left out.
    func chapterTimes() -> [Double] {
        guard mpv != nil else { return [] }
        let count = getInt("chapter-list/count")
        guard count > 1 else { return [] }
        return (0..<count)
            .compactMap { index -> Double? in
                guard let raw = getString("chapter-list/\(index)/time") else { return nil }
                return Double(raw)
            }
            .filter { $0 > 1 }
    }

    /// The Settings subtitle style, then the viewer's system caption choices on top (spec §8.3):
    /// the values marked to override video in Settings › Accessibility › Subtitles & Captioning
    /// win, and the system text size scales whatever size the app style picked. mpv then honours
    /// the same captions setting as every Apple player (the native engine does this by itself).
    func applySubtitleAppearance() {
        guard mpv != nil, fileLoaded else { return }
        applySubtitleStyle()
        SystemCaptionStyle.current().apply { name, value in
            guard let mpv = self.mpv else { return }
            self.checkError(mpv_set_property_string(mpv, name, value))
        }
    }
}

/// The system caption appearance (MediaAccessibility, user domain) mapped onto libmpv `sub-*`
/// properties. Only what the viewer explicitly set is carried over, except the relative text size,
/// which always applies (it is how the "Large Text" caption style works).
struct SystemCaptionStyle {
    /// mpv colours, "#AARRGGBB".
    var textColor: String?
    var backgroundColor: String?
    /// Relative character size (1 = the style's own size).
    var scale: Double = 1
    var edge: MACaptionAppearanceTextEdgeStyle?
    var fontFamily: String?

    static func current() -> SystemCaptionStyle {
        var style = SystemCaptionStyle()
        var behavior = MACaptionAppearanceBehavior.useContentIfAvailable

        let foreground = retained(MACaptionAppearanceCopyForegroundColor(.user, &behavior))
        let foregroundSet = behavior == .useValue
        behavior = .useContentIfAvailable
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(.user, &behavior)
        let foregroundOpacitySet = behavior == .useValue
        if foregroundSet || foregroundOpacitySet {
            style.textColor = mpvColor(foreground, opacity: foregroundOpacitySet ? foregroundOpacity : nil)
        }

        behavior = .useContentIfAvailable
        let background = retained(MACaptionAppearanceCopyBackgroundColor(.user, &behavior))
        let backgroundSet = behavior == .useValue
        behavior = .useContentIfAvailable
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(.user, &behavior)
        let backgroundOpacitySet = behavior == .useValue
        if backgroundSet || backgroundOpacitySet {
            style.backgroundColor = mpvColor(background, opacity: backgroundOpacitySet ? backgroundOpacity : nil)
        }

        behavior = .useContentIfAvailable
        let size = MACaptionAppearanceGetRelativeCharacterSize(.user, &behavior)
        if size.isFinite, size > 0 { style.scale = Double(min(max(size, 0.5), 2)) }

        behavior = .useContentIfAvailable
        let edge = MACaptionAppearanceGetTextEdgeStyle(.user, &behavior)
        if behavior == .useValue, edge != .undefined { style.edge = edge }

        behavior = .useContentIfAvailable
        let descriptor = retained(MACaptionAppearanceCopyFontDescriptorForStyle(.user, &behavior, .default))
        if behavior == .useValue,
           let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
           !family.isEmpty {
            style.fontFamily = family
        }
        return style
    }

    /// Writes the style through `set(property, value)`. Properties the app style never sets
    /// (scale, font, shadow) are always written, so a cleared system choice goes back to default.
    func apply(_ set: (String, String) -> Void) {
        if let textColor { set("sub-color", textColor) }
        if let backgroundColor {
            set("sub-back-color", backgroundColor)
            set("sub-border-style", "background-box")
        }
        set("sub-scale", String(format: "%.2f", scale))
        set("sub-font", fontFamily ?? "sans-serif")
        guard let edge else {
            set("sub-shadow-offset", "0")
            return
        }
        let plainBorder = backgroundColor == nil
        switch edge {
        case .none:
            set("sub-outline-size", "0")
            set("sub-shadow-offset", "0")
        case .uniform:
            if plainBorder { set("sub-border-style", "outline-and-shadow") }
            set("sub-outline-size", "3")
            set("sub-shadow-offset", "0")
        case .dropShadow:
            if plainBorder { set("sub-border-style", "outline-and-shadow") }
            set("sub-outline-size", "0")
            set("sub-shadow-color", "#B4000000")
            set("sub-shadow-offset", "2")
        case .raised, .depressed:
            if plainBorder { set("sub-border-style", "outline-and-shadow") }
            set("sub-outline-size", "1")
            set("sub-shadow-color", "#B4000000")
            set("sub-shadow-offset", "1.5")
        default:
            set("sub-shadow-offset", "0")
        }
    }

    // MediaAccessibility's Copy functions come back unmanaged (+1) or managed depending on the
    // SDK's annotations; these two overloads accept either.
    private static func retained<T: AnyObject>(_ value: Unmanaged<T>) -> T { value.takeRetainedValue() }
    private static func retained<T: AnyObject>(_ value: T) -> T { value }

    private static func mpvColor(_ color: CGColor, opacity: CGFloat?) -> String? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let rgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = rgb.components, components.count >= 3 else { return nil }
        let alpha = opacity ?? (components.count >= 4 ? components[3] : 1)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X",
                      byte(alpha), byte(components[0]), byte(components[1]), byte(components[2]))
    }
}
