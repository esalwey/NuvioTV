import SharedCore
import SwiftUI
import UIKit

// The focusable half of the libmpv screen's system-player chrome. libmpv's controller owns the
// remote while the bar is passive (click ±10 s, swipe scrubbing, Select/Play, hold to fast-forward
// — `MPVPlayerView+Remote`); when focus moves INTO the bar, this layer is presented over the player
// (`.overFullScreen`, the video keeps playing underneath) and SwiftUI's focus engine takes over,
// exactly where AVPlayerViewController hands focus to its own controls:
//  - Up (or a swipe up) with the bar showing → the transport buttons: the app's items (Sources,
//    Playback Speed, Aspect Ratio, Subtitle Timing — the native screen's `transportBarCustomMenuItems`, same
//    order, labels and symbols) then Subtitles and Audio, each a system menu with checkmarks.
//  - Down (or a swipe down) → the content tabs (Info, Chapters, Episodes, Stream Info): the tab view
//    of the system player, the pills and the focused tab's panel in the middle of the picture with
//    no transport bar (it slides up from the bottom edge; with the bar up, the bar's block of title,
//    bar and pills slides up with it, and slides back down when the view closes).
//  - Moving focus back onto the scrubber, Back, or an Up on the pills hands the remote back to libmpv.
// Both layers draw the same `PlayerTransportBar`, so nothing moves when focus changes hands.

/// Where focus lands when the focus layer opens.
enum PlayerChromeEntry {
    case transport
    case tabs
}

/// Closes the presented focus layer; an action that replaces playback (a source pick, an episode
/// jump) runs once it is gone, never under it.
@MainActor
final class PlayerChromeCloser {
    weak var host: PlayerPanelPresenting?
    /// The passive bar was on screen when the layer opened (the layer then starts from the bar's layout).
    var barWasShowing = false

    func close(then action: (() -> Void)? = nil) {
        guard let host else {
            action?()
            return
        }
        host.close(animated: action == nil, then: action)
    }
}

/// What the libmpv chrome offers — one rule for the passive bar and the focus layer, so the glyphs
/// drawn at rest are exactly the buttons and tabs focus then finds.
enum MPVChromeContent {
    /// The transport buttons. Subtitle Timing only with a subtitle showing (mpv can re-time any
    /// track; the native engine offers it for addon subtitles, the only ones it can re-time).
    static func items(panelModel: PlayerTopPanelModel, canChooseSource: Bool,
                      canSwitchEngine: Bool = false) -> [PlayerTransportItem] {
        let canRetime = panelModel.supportsSubtitleDelay
            && panelModel.subtitles.contains { $0.isSelected && $0.group != .off }
        return PlayerTransportMenus.items(canChooseSource: canChooseSource, supportsSubtitleDelay: canRetime,
                                          canSwitchEngine: canSwitchEngine,
                                          hasServerSubtitles: !panelModel.serverSubtitles.isEmpty,
                                          hasServerAudio: !panelModel.serverAudio.isEmpty)
    }

    /// The content tabs, in the native screen's order: the system's Info and Chapters, then the app's
    /// Episodes and Stream Info (Infos, Chapitres, Épisodes, Infos du stream in the owner's recording).
    static func tabs(hasEpisodes: Bool, hasChapters: Bool) -> [PlayerContentTab] {
        var tabs: [PlayerContentTab] = [.info]
        if hasChapters { tabs.append(.chapters) }
        if hasEpisodes { tabs.append(.episodes) }
        tabs.append(.streamInfo)
        return tabs
    }
}

/// What the focus layer can do to the player.
struct MPVChromeActions {
    let close: () -> Void
    /// "Sources": close the player onto this episode's stream list. nil = no Sources item.
    let chooseSource: (() -> Void)?
    /// An episode picked in the Episodes tab.
    let selectEpisode: (MetaVideo) -> Void
    /// A chapter picked in the Chapters tab (seconds).
    let seek: (Double) -> Void
    /// Start Over (PLY-A13): back to 0:00.
    let startOver: () -> Void
    /// "Player Engine": hand the stream to the other engine (the native one, from here). nil = no
    /// Player Engine item.
    var switchEngine: ((PlaybackEngine) -> Void)? = nil
}

struct MPVTransportFocusView: View {
    @ObservedObject var state: MPVPlaybackState
    @ObservedObject var panelModel: PlayerTopPanelModel
    @ObservedObject var chromeModel: MPVChromeModel
    @ObservedObject var upNext: NextEpisodeEngine
    let summary: PlayerInfoSummary
    let entry: PlayerChromeEntry
    let season: Int?
    let episode: Int?
    let actions: MPVChromeActions
    /// The passive bar was up when the layer opened: the tab view then grows out of the bar's layout.
    let startsFromBar: Bool

    private enum Focus: Hashable {
        case item(PlayerTransportItem)
        case scrubber
        case tab(PlayerContentTab)
    }

    /// The Subtitles menu's "Automatic" row (the system popover's "Auto"): its own choice id.
    private static let automaticSubtitleID = "subtitles.automatic"

    @FocusState private var focus: Focus?
    @State private var selectedTab: PlayerContentTab = .info
    /// The tab view is open: the pills and the focused tab's panel in the middle of the picture, with
    /// the title, the bar and the buttons gone (faded out where they are).
    @State private var tabsEngaged: Bool
    /// The layer's own slide-in, for a tab view that opens with the bar away.
    @State private var entered: Bool
    /// The opening focus has landed: from then on, focus on the scrubber hands the remote back.
    @State private var armed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: MPVPlaybackState, panelModel: PlayerTopPanelModel, chromeModel: MPVChromeModel,
         upNext: NextEpisodeEngine, summary: PlayerInfoSummary, entry: PlayerChromeEntry,
         season: Int?, episode: Int?, actions: MPVChromeActions, startsFromBar: Bool = false) {
        _state = ObservedObject(wrappedValue: state)
        _panelModel = ObservedObject(wrappedValue: panelModel)
        _chromeModel = ObservedObject(wrappedValue: chromeModel)
        _upNext = ObservedObject(wrappedValue: upNext)
        self.summary = summary
        self.entry = entry
        self.season = season
        self.episode = episode
        self.actions = actions
        self.startsFromBar = startsFromBar
        // From nothing the tab view comes in as it is, sliding up; from the bar it grows out of it.
        let fromNothing = entry == .tabs && !startsFromBar
        _tabsEngaged = State(initialValue: fromNothing)
        _entered = State(initialValue: !fromNothing)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-screen clear layer so the hosting view fills the window (focus + gestures).
            Color.clear.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                PlayerTransportBar(state: state, summary: summary,
                                   parts: parts, barDimmed: barDimmed) {
                    buttonRow
                } scrubberOverlay: {
                    scrubberProxy
                } tabs: {
                    tabRow
                }
                if tabsEngaged {
                    tabContent
                        .id(selectedTab)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: PlayerSpec.Layout.tabContentHeight, alignment: .top)
                        .padding(.horizontal, PlayerSpec.Layout.sideInset)
                        .padding(.top, PlayerSpec.Layout.tabPillsToContent)
                        .focusSection()
                }
            }
            .padding(.bottom, tabsEngaged ? PlayerSpec.Layout.tabContentBottom : PlayerSpec.Layout.bottomInset)
            .offset(y: entered ? 0 : PlayerSpec.Layout.tabSlideDistance)
            .opacity(entered ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? nil : .easeOut(duration: PlayerSpec.Tabs.closeSec), value: tabsEngaged)
        .animation(reduceMotion ? nil : .easeOut(duration: PlayerSpec.Tabs.swapSec), value: selectedTab)
        .animation(reduceMotion ? nil : .easeOut(duration: PlayerSpec.Tabs.openSec), value: entered)
        .defaultFocus($focus, initialFocus, priority: .userInitiated)
        .onAppear {
            focus = initialFocus
            state.tabViewOpen = tabsEngaged
            entered = true
            // A tab view that opens over the bar grows out of it.
            if entry == .tabs, !tabsEngaged { tabsEngaged = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                armed = true
            }
        }
        .onDisappear { state.tabViewOpen = false }
        .onChange(of: tabsEngaged) { _, engaged in state.tabViewOpen = engaged }
        .onChange(of: focus) { oldValue, newValue in
            switch newValue {
            case .scrubber:
                // Back on the scrubber: libmpv takes the remote again (seek, scrub, play/pause).
                if armed {
                    actions.close()
                } else {
                    focus = initialFocus
                }
            case .tab(let tab):
                if oldValue == nil, tabsEngaged, tab != selectedTab {
                    // Focus came back UP from the tab's content: land on that tab (the focus engine
                    // picks the geometrically nearest one, which would silently switch tabs).
                    focus = .tab(selectedTab)
                } else {
                    selectedTab = tab
                    tabsEngaged = true
                }
            case .item:
                tabsEngaged = false
            case nil:
                // Inside a tab's content (its own focus state), or a menu is open: unchanged.
                break
            }
        }
        .onExitCommand { closeRequested() }
        // Play/Pause always plays or pauses, wherever focus sits in the bar or in a tab — the system
        // player never lets a focused button swallow it. Answered here, at once, rather than left to
        // bubble up to libmpv's controller or to arrive as a (debounced) Now Playing command.
        .onPlayPauseCommand { state.togglePlayPause?() }
    }

    /// Which parts of the bar are drawn: all of them in the transport layout, only the pills in the
    /// tab view (the title, the bar and the buttons fade out where they are, and come back as the
    /// block slides down again).
    private var parts: PlayerBarParts {
        PlayerBarParts(bar: !tabsEngaged, title: !tabsEngaged, buttons: !tabsEngaged, pills: true)
    }

    /// Focus sits on a transport button: the bar and its labels dim (64.867 s of the owner's recording).
    private var barDimmed: Bool {
        if case .item = focus { return true }
        return false
    }

    /// Back, or an Up on the pills: from the tab view, the block of pills (with the title and the bar
    /// behind them) slides back down to the transport layout while the panel fades, then the layer
    /// lets go (39.2 to 39.6 s of the owner's recording).
    private func closeRequested() {
        guard tabsEngaged, !reduceMotion else {
            actions.close()
            return
        }
        withAnimation(.easeOut(duration: PlayerSpec.Tabs.closeSec)) { tabsEngaged = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerSpec.Tabs.closeSec) { actions.close() }
    }

    private var initialFocus: Focus {
        switch entry {
        case .transport: return .item(items.last ?? .audio)
        case .tabs: return .tab(tabs.first ?? .info)
        }
    }

    // MARK: - Transport buttons

    private var items: [PlayerTransportItem] {
        MPVChromeContent.items(panelModel: panelModel, canChooseSource: actions.chooseSource != nil,
                               canSwitchEngine: actions.switchEngine != nil)
    }

    private var buttonRow: some View {
        GlassEffectContainer(spacing: PlayerSpec.Layout.buttonSpacing) {
            HStack(spacing: PlayerSpec.Layout.buttonSpacing) {
                ForEach(items) { item in
                    button(for: item)
                        .focused($focus, equals: .item(item))
                        .accessibilityLabel(Text(verbatim: item.title))
                }
            }
        }
        .focusSection()
        // Out of the focus chain while the tab view is open (the buttons are faded out there).
        .disabled(tabsEngaged)
    }

    @ViewBuilder
    private func button(for item: PlayerTransportItem) -> some View {
        switch item {
        case .startOver:
            Button {
                actions.startOver()
            } label: {
                Text(verbatim: item.title)
            }
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        case .sources:
            Button {
                actions.chooseSource?()
            } label: {
                Text(verbatim: item.title)
            }
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        case .playbackSpeed:
            Menu {
                Picker(selection: speedBinding) {
                    ForEach(PlayerTransportMenus.rates, id: \.self) { rate in
                        Text(verbatim: PlayerTransportMenus.rateTitle(rate)).tag(rate)
                    }
                } label: {
                    Text(verbatim: item.title)
                }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: item.title)
            }
            .menuStyle(.button)
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        case .aspect:
            Menu {
                Picker(selection: aspectBinding) {
                    ForEach(PlayerAspectMode.allCases) { mode in
                        Text(verbatim: mode.title).tag(mode)
                    }
                } label: {
                    Text(verbatim: item.title)
                }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: item.title)
            }
            .menuStyle(.button)
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        case .subtitleTiming:
            Menu {
                Picker(selection: subtitleDelayBinding) {
                    ForEach(PlayerTransportMenus.delayChoices(including: panelModel.subtitleDelayMs), id: \.self) { ms in
                        Text(verbatim: PlayerTransportMenus.delayTitle(ms)).tag(ms)
                    }
                } label: {
                    Text(verbatim: item.title)
                }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: item.title)
            }
            .menuStyle(.button)
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        case .serverSubtitles:
            Menu {
                Picker(selection: serverSubtitleBinding) {
                    ForEach(panelModel.serverSubtitles) { option in
                        Text(verbatim: option.title).tag(option.id)
                    }
                } label: {
                    Text(verbatim: item.title)
                }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: item.title)
            }
            .menuStyle(.button)
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        case .serverAudio:
            Menu {
                Picker(selection: serverAudioBinding) {
                    ForEach(panelModel.serverAudio) { option in
                        Text(verbatim: option.title).tag(option.id)
                    }
                } label: {
                    Text(verbatim: item.title)
                }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: item.title)
            }
            .menuStyle(.button)
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        case .engine:
            Menu {
                Picker(selection: engineBinding) {
                    ForEach([PlaybackEngine.native, .mpv], id: \.self) { engine in
                        Text(verbatim: engine.menuTitle).tag(engine)
                    }
                } label: {
                    Text(verbatim: item.title)
                }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: item.title)
            }
            .menuStyle(.button)
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        case .subtitles:
            Menu {
                subtitleRows(title: item.title)
                if panelModel.subtitlesSearching {
                    Text(verbatim: String(localized: "Searching addon subtitles…"))
                }
            } label: {
                Text(verbatim: item.title)
            }
            .menuStyle(.button)
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        case .audio:
            Menu {
                Picker(selection: audioBinding) {
                    ForEach(panelModel.audio) { option in
                        Text(verbatim: Self.menuTitle(option)).tag(option.id)
                    }
                } label: {
                    Text(verbatim: item.title)
                }
                .pickerStyle(.inline)
                if panelModel.supportsAudioDelay {
                    Section {
                        Picker(selection: audioDelayBinding) {
                            ForEach(PlayerTransportMenus.delayChoices(including: panelModel.audioDelayMs), id: \.self) { ms in
                                Text(verbatim: PlayerTransportMenus.delayTitle(ms)).tag(ms)
                            }
                        } label: {
                            Text(verbatim: String(localized: "Audio Delay"))
                        }
                        .pickerStyle(.inline)
                    } header: {
                        Text(verbatim: String(localized: "Audio Delay"))
                    }
                }
                // Volume Boost and Dialogue Boost: the mpv engine's counterparts of the system
                // player's Enhance Dialogue, as submenus so the track list stays short. Dialogue
                // Boost mixes down to stereo, so it is offered only on a stereo output.
                Menu {
                    Picker(selection: audioGainBinding) {
                        ForEach(MPVAudioSettings.gainChoices, id: \.self) { db in
                            Text(verbatim: MPVAudioBoostTitle.gain(db)).tag(db)
                        }
                    } label: {
                        Text(verbatim: String(localized: "Volume Boost"))
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(verbatim: String(localized: "Volume Boost"))
                }
                if MPVAudioSettings.isStereoOutput(.current) {
                    Menu {
                        Picker(selection: dialogueBoostBinding) {
                            ForEach(MPVAudioSettings.dialogueChoices, id: \.self) { db in
                                Text(verbatim: MPVAudioBoostTitle.dialogue(db)).tag(db)
                            }
                        } label: {
                            Text(verbatim: String(localized: "Dialogue Boost"))
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(verbatim: String(localized: "Dialogue Boost"))
                    }
                }
            } label: {
                Text(verbatim: item.title)
            }
            .menuStyle(.button)
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        }
    }

    /// The Subtitles menu's rows: one list, or — Settings > Playback > Subtitle List — blocks under a
    /// header per language or per add-on. The checkmark follows the same selection in every block.
    @ViewBuilder
    private func subtitleRows(title: String) -> some View {
        let sections = panelModel.subtitleSections(SubtitleOrganization.current)
        if sections.count <= 1 {
            Picker(selection: subtitleBinding) {
                if !panelModel.subtitles.isEmpty {
                    Text(verbatim: String(localized: "Automatic")).tag(Self.automaticSubtitleID)
                }
                ForEach(panelModel.subtitles) { option in
                    Text(verbatim: Self.menuTitle(option)).tag(option.id)
                }
            } label: {
                Text(verbatim: title)
            }
            .pickerStyle(.inline)
        } else {
            Picker(selection: subtitleBinding) {
                Text(verbatim: String(localized: "Automatic")).tag(Self.automaticSubtitleID)
            } label: {
                Text(verbatim: title)
            }
            .pickerStyle(.inline)
            ForEach(sections) { section in
                if let header = section.title {
                    Section {
                        subtitlePicker(section.options, title: title)
                    } header: {
                        Text(verbatim: header)
                    }
                } else {
                    subtitlePicker(section.options, title: title)
                }
            }
        }
    }

    private func subtitlePicker(_ options: [PlayerPanelOption], title: String) -> some View {
        Picker(selection: subtitleBinding) {
            ForEach(options) { option in
                Text(verbatim: Self.menuTitle(option)).tag(option.id)
            }
        } label: {
            Text(verbatim: title)
        }
        .pickerStyle(.inline)
    }

    /// One menu row: the track's name, then its descriptor ("Français · Dolby Digital+ 5.1").
    private static func menuTitle(_ option: PlayerPanelOption) -> String {
        guard let detail = option.detail, !detail.isEmpty else { return option.title }
        return "\(option.title) \u{00B7} \(detail)"
    }

    private var speedBinding: Binding<Float> {
        Binding(
            get: { Float(state.playbackSpeed) },
            set: { rate in state.setSpeed?(Double(rate)) })
    }

    private var aspectBinding: Binding<PlayerAspectMode> {
        Binding(
            get: { state.aspectMode },
            set: { mode in state.setAspectMode?(mode) })
    }

    /// The engine playing here is mpv; picking Native hands the stream over.
    private var engineBinding: Binding<PlaybackEngine> {
        Binding(
            get: { .mpv },
            set: { engine in
                if engine != .mpv { actions.switchEngine?(engine) }
            })
    }

    private var subtitleDelayBinding: Binding<Int> {
        Binding(
            get: { panelModel.subtitleDelayMs },
            set: { ms in panelModel.onSubtitleDelayChange?(ms) })
    }

    private var audioDelayBinding: Binding<Int> {
        Binding(
            get: { panelModel.audioDelayMs },
            set: { ms in panelModel.onAudioDelayChange?(ms) })
    }

    private var audioGainBinding: Binding<Int> {
        Binding(
            get: { state.audioGainDb },
            set: { db in state.setAudioGain?(db) })
    }

    private var dialogueBoostBinding: Binding<Int> {
        Binding(
            get: { state.dialogueBoostDb },
            set: { db in state.setDialogueBoost?(db) })
    }

    private var serverAudioBinding: Binding<String> {
        Binding(
            get: { panelModel.serverAudio.first(where: \.isSelected)?.id ?? "" },
            set: { id in
                guard let option = panelModel.serverAudio.first(where: { $0.id == id }) else { return }
                panelModel.onSelectServerAudio?(option)
            })
    }

    private var serverSubtitleBinding: Binding<String> {
        Binding(
            get: { panelModel.serverSubtitles.first(where: \.isSelected)?.id ?? "off" },
            set: { id in
                guard let option = panelModel.serverSubtitles.first(where: { $0.id == id }) else { return }
                panelModel.onSelectServerSubtitle?(option.group == .off ? nil : option)
            })
    }

    private var subtitleBinding: Binding<String> {
        Binding(
            get: {
                state.subtitlesAutomatic
                    ? Self.automaticSubtitleID
                    : (panelModel.subtitles.first(where: \.isSelected)?.id ?? "off")
            },
            set: { id in
                if id == Self.automaticSubtitleID {
                    state.selectAutoSubtitles?()
                    return
                }
                guard let option = panelModel.subtitles.first(where: { $0.id == id }) else { return }
                panelModel.onSelectSubtitle?(option.group == .off ? nil : option)
            })
    }

    private var audioBinding: Binding<String> {
        Binding(
            get: { panelModel.audio.first(where: \.isSelected)?.id ?? "" },
            set: { id in
                guard let option = panelModel.audio.first(where: { $0.id == id }) else { return }
                panelModel.onSelectAudio?(option)
            })
    }

    // MARK: - Scrubber

    /// The scrubber's place in the focus layout: reaching it gives the remote back to libmpv. Out of
    /// the focus chain while the tab view is open.
    private var scrubberProxy: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
            .focusable()
            .focused($focus, equals: .scrubber)
            .disabled(tabsEngaged)
            .accessibilityHidden(true)
    }

    // MARK: - Content tabs

    private var tabs: [PlayerContentTab] {
        MPVChromeContent.tabs(hasEpisodes: season != nil && !upNext.episodes.isEmpty, hasChapters: !chapters.isEmpty)
    }

    private var chapters: [PlayerChapter] {
        chromeModel.chapters(durationSec: state.durationSec)
    }

    /// "HD" or "4K" beside the runtime of the Info card, from the stream's own size.
    private var resolutionBadge: String? {
        guard let resolution = state.streamInfo?.resolution else { return nil }
        let sizes = resolution.split(separator: "\u{00D7}").compactMap { Int($0) }
        guard sizes.count == 2 else { return nil }
        if sizes[0] >= 3000 || sizes[1] >= 2000 { return "4K" }
        return max(sizes[0], sizes[1]) >= 1280 ? "HD" : nil
    }

    private var tabRow: some View {
        GlassEffectContainer(spacing: PlayerSpec.Layout.pillSpacing) {
            HStack(spacing: PlayerSpec.Layout.pillSpacing) {
                ForEach(tabs) { tab in
                    Button {
                        selectedTab = tab
                        tabsEngaged = true
                    } label: {
                        Text(verbatim: tab.title)
                    }
                    .buttonStyle(PlayerTabPillButtonStyle(title: tab.title,
                                                          selected: tabsEngaged && selectedTab == tab))
                    .focused($focus, equals: .tab(tab))
                    .accessibilityLabel(Text(verbatim: tab.title))
                }
            }
        }
        .focusSection()
        // Up on the pills of the tab view closes it (nothing is above them).
        .onMoveCommand { direction in
            if direction == .up, tabsEngaged { closeRequested() }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .info:
            PlayerInfoSummaryTab(summary: summary, runtimeSec: state.durationSec,
                                 resolutionBadge: resolutionBadge) {
                actions.startOver()
            }
        case .episodes:
            PlayerEpisodesTab(engine: upNext, season: season, episode: episode) { video in
                actions.selectEpisode(video)
            }
        case .chapters:
            PlayerChaptersTab(chapters: chapters, positionSec: state.positionSec) { chapter in
                actions.seek(chapter.start)
            }
        case .streamInfo:
            PlayerStreamInfoTab(model: panelModel) { nil }
        }
    }
}
