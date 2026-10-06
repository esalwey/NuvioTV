import SharedCore
import SwiftUI
import UIKit

// The focusable half of the libmpv screen's system-player chrome. libmpv's controller owns the
// remote while the bar is passive (click ±10 s, swipe scrubbing, Select/Play, hold to fast-forward
// — `MPVPlayerView+Remote`); when focus moves INTO the bar, this layer is presented over the player
// (`.overFullScreen`, the video keeps playing underneath) and SwiftUI's focus engine takes over,
// exactly where AVPlayerViewController hands focus to its own controls:
//  - Up (or a swipe up) with the bar showing → the transport buttons: the app's items (Sources,
//    Playback Speed, Subtitle Timing — the native screen's `transportBarCustomMenuItems`, same
//    order, labels and symbols) then Subtitles and Audio, each a system menu with checkmarks.
//  - Down (or a swipe down) → the content tabs (Info, Episodes, Chapters, Stream Info), the
//    focused tab's content under the bar.
//  - Moving focus back onto the scrubber, or Back, hands the remote back to libmpv.
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
    static func items(panelModel: PlayerTopPanelModel, canChooseSource: Bool) -> [PlayerTransportItem] {
        let canRetime = panelModel.supportsSubtitleDelay
            && panelModel.subtitles.contains { $0.isSelected && $0.group != .off }
        return PlayerTransportMenus.items(canChooseSource: canChooseSource, supportsSubtitleDelay: canRetime)
    }

    /// The content tabs, in the native screen's order.
    static func tabs(hasEpisodes: Bool, hasChapters: Bool) -> [PlayerContentTab] {
        var tabs: [PlayerContentTab] = [.info]
        if hasEpisodes { tabs.append(.episodes) }
        if hasChapters { tabs.append(.chapters) }
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

    private enum Focus: Hashable {
        case item(PlayerTransportItem)
        case scrubber
        case tab(PlayerContentTab)
    }

    @FocusState private var focus: Focus?
    @State private var selectedTab: PlayerContentTab = .info
    /// A tab has focus, or focus went down into its content: the content shows under the bar.
    @State private var tabsEngaged = false
    /// The opening focus has landed: from then on, focus on the scrubber hands the remote back.
    @State private var armed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: MPVPlaybackState, panelModel: PlayerTopPanelModel, chromeModel: MPVChromeModel,
         upNext: NextEpisodeEngine, summary: PlayerInfoSummary, entry: PlayerChromeEntry,
         season: Int?, episode: Int?, actions: MPVChromeActions) {
        _state = ObservedObject(wrappedValue: state)
        _panelModel = ObservedObject(wrappedValue: panelModel)
        _chromeModel = ObservedObject(wrappedValue: chromeModel)
        _upNext = ObservedObject(wrappedValue: upNext)
        self.summary = summary
        self.entry = entry
        self.season = season
        self.episode = episode
        self.actions = actions
        _tabsEngaged = State(initialValue: entry == .tabs)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-screen clear layer so the hosting view fills the window (focus + gestures).
            Color.clear.ignoresSafeArea()
            PlayerChromeScrim(deep: tabsEngaged)
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                PlayerTransportBar(state: state, summary: summary, ticks: chromeModel.tickTimes) {
                    buttonRow
                } scrubberOverlay: {
                    scrubberProxy
                } tabs: {
                    tabRow
                }
                if tabsEngaged {
                    tabContent
                        .frame(height: contentHeight(selectedTab), alignment: .top)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .focusSection()
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, PlayerChromeLayout.barInset)
            .padding(.bottom, PlayerChromeLayout.barBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: tabsEngaged)
        .defaultFocus($focus, initialFocus, priority: .userInitiated)
        .onAppear {
            focus = initialFocus
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                armed = true
            }
        }
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
        .onExitCommand { actions.close() }
    }

    private var initialFocus: Focus {
        switch entry {
        case .transport: return .item(items.last ?? .audio)
        case .tabs: return .tab(tabs.first ?? .info)
        }
    }

    // MARK: - Transport buttons

    private var items: [PlayerTransportItem] {
        MPVChromeContent.items(panelModel: panelModel, canChooseSource: actions.chooseSource != nil)
    }

    private var buttonRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(items) { item in
                button(for: item)
                    .focused($focus, equals: .item(item))
                    .accessibilityLabel(Text(verbatim: item.title))
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private func button(for item: PlayerTransportItem) -> some View {
        switch item {
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
        case .subtitles:
            Menu {
                Picker(selection: subtitleBinding) {
                    ForEach(panelModel.subtitles) { option in
                        Text(verbatim: Self.menuTitle(option)).tag(option.id)
                    }
                } label: {
                    Text(verbatim: item.title)
                }
                .pickerStyle(.inline)
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
            } label: {
                Text(verbatim: item.title)
            }
            .menuStyle(.button)
            .buttonStyle(PlayerTransportButtonStyle(item: item))
        }
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

    private var subtitleBinding: Binding<String> {
        Binding(
            get: { panelModel.subtitles.first(where: \.isSelected)?.id ?? "off" },
            set: { id in
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

    /// The scrubber's place in the focus layout: reaching it gives the remote back to libmpv.
    private var scrubberProxy: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
            .focusable()
            .focused($focus, equals: .scrubber)
            .accessibilityHidden(true)
    }

    // MARK: - Content tabs

    private var tabs: [PlayerContentTab] {
        MPVChromeContent.tabs(hasEpisodes: season != nil && !upNext.episodes.isEmpty, hasChapters: !chapters.isEmpty)
    }

    private var chapters: [PlayerChapter] {
        chromeModel.chapters(durationSec: state.durationSec)
    }

    private var tabRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
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
        .focusSection()
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .info:
            PlayerInfoSummaryTab(summary: summary)
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

    private func contentHeight(_ tab: PlayerContentTab) -> CGFloat {
        switch tab {
        case .info: return PlayerInfoSummaryTab.tabHeight
        case .episodes: return PlayerEpisodesTab.tabHeight
        case .chapters: return PlayerChaptersTab.tabHeight
        case .streamInfo: return PlayerStreamInfoTab.tabHeight
        }
    }
}
