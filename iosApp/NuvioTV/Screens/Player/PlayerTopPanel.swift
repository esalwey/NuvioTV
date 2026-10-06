import SwiftUI

enum PlayerPanelTab: String, CaseIterable, Identifiable {
    case info, subtitles, audio
    /// Engine-specific fourth tab (the mpv player's Playback: speed · timing · episodes · sources).
    case playback
    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return String(localized: "Info")
        case .subtitles: return String(localized: "Subtitles")
        case .audio: return String(localized: "Audio")
        case .playback: return String(localized: "Playback")
        }
    }
}

/// Content for the optional fourth tab; supplied by the engine that has one.
struct PlayerPanelExtraTab {
    let content: AnyView
    init<V: View>(@ViewBuilder content: () -> V) { self.content = AnyView(content()) }
}

/// The app-drawn swipe-down top panel (Infuse-style rendition of the classic tvOS player panel):
/// full width, anchored to the top, glass over the live video, a centred tab row (Info · Subtitles ·
/// Audio) whose selection follows focus, and the tab's content below. Presented by
/// `NativePlayerHostController` (which also owns Menu-to-close); playback continues underneath.
///
/// Focus: the tab row and the content are separate focus sections, so Down from a tab enters the
/// content list and Up returns to the tabs. Left/Right on the tab row switches tabs. Everything
/// uses system focus (docs/design/hig-hybrid-contract.md) — no custom rings.
struct PlayerTopPanel: View {
    @ObservedObject var model: PlayerTopPanelModel
    var extraTab: PlayerPanelExtraTab? = nil
    /// Starts on the tab the viewer last had open this session (F16, `PlayerTopPanelModel.lastTab`).
    @State private var tab: PlayerPanelTab
    @State private var shown = false
    @FocusState private var focusedTab: PlayerPanelTab?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: PlayerTopPanelModel, extraTab: PlayerPanelExtraTab? = nil) {
        _model = ObservedObject(wrappedValue: model)
        self.extraTab = extraTab
        // The engine-specific tab only exists when this engine supplies one.
        let remembered = model.lastTab
        _tab = State(initialValue: remembered == .playback && extraTab == nil ? .info : remembered)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Full-screen clear layer so the hosting view fills the window (focus + gestures).
            Color.clear.ignoresSafeArea()
            if shown {
                panel
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(reduceMotion ? nil : PlayerChipStyle.animation) { shown = true }
            focusedTab = tab
        }
        .onChange(of: focusedTab) { oldValue, newValue in
            guard let newValue else { return }
            if oldValue == nil, newValue != tab {
                // Focus came back UP from the content list: land on the current tab (the focus
                // engine picks the geometrically nearest one, which would silently switch tabs).
                focusedTab = tab
            } else {
                tab = newValue
            }
        }
        .onChange(of: tab) { _, newValue in model.lastTab = newValue }
        .onExitCommand { model.onClose?() }
    }

    private var panel: some View {
        VStack(spacing: Theme.Spacing.md) {
            tabRow
                .focusSection()
            content
                .focusSection()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .top)
        // Same recipe as every player panel (`playerPanelGlass()`, AES-7): dark-tinted glass keeps text
        // legible over bright scenes; only the bottom corners are rounded (the top edge is the screen edge).
        .glassEffect(.regular.tint(PlayerChipStyle.glassTint),
                     in: UnevenRoundedRectangle(bottomLeadingRadius: Theme.Radius.panel,
                                                bottomTrailingRadius: Theme.Radius.panel, style: .continuous))
        .playerPanelShadow()
    }

    private var tabRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(tabs) { item in
                Button(item.title) { tab = item }
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(item == tab ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .focused($focusedTab, equals: item)
                    .accessibilityIdentifier("player.panel.tab.\(item.rawValue)")
                    .accessibilityValue(Text(verbatim: item == tab ? "selected" : ""))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tabs: [PlayerPanelTab] {
        extraTab == nil ? [.info, .subtitles, .audio] : PlayerPanelTab.allCases
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .info:
            PlayerInfoTab(info: model.info)
        case .subtitles:
            PlayerSubtitlesTab(model: model)
        case .audio:
            PlayerAudioTab(model: model)
        case .playback:
            if let extraTab { extraTab.content } else { EmptyView() }
        }
    }
}

/// One checkmark row of the Subtitles / Audio tab. DEFAULT tvOS button style on purpose: it draws
/// the white focus platter (the classic panel's focused-row look) and recolors the label itself.
/// `.borderless` would only brighten the label — invisible on an already-bright label (BUG-58
/// lesson) — and no explicit foreground color is set here so the platter's dark text wins.
struct PlayerPanelOptionRow: View {
    let option: PlayerPanelOption
    let identifierPrefix: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Image(systemName: "checkmark")
                    .font(Theme.Font.body.weight(.semibold))
                    .opacity(option.isSelected ? 1 : 0)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(Theme.Font.body)
                        .lineLimit(1)
                    if let detail = option.detail {
                        Text(detail)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("\(identifierPrefix).\(option.id)")
        .accessibilityValue(Text(verbatim: option.isSelected ? "selected" : ""))
    }
}

/// A delay nudger for the panel's right-hand columns (subtitle delay, audio delay): title and
/// current value on one line, step buttons below, then Reset. Plain focusable buttons in a row, so
/// Left/Right moves between steps and Left from the first step goes back to the track list (an
/// `onMoveCommand` stepper would trap Left/Right). Default tvOS button style, like every panel row.
struct PlayerPanelDelayControl: View {
    struct Step: Hashable {
        /// Signed step in milliseconds.
        let ms: Int
        /// Accessibility identifier suffix ("minus1", "plus"…), kept stable for UI tests.
        let id: String
    }

    let title: String
    let valueMs: Int
    let steps: [Step]
    let range: ClosedRange<Int>
    let identifierPrefix: String
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(title)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.sm)
                Text(String(format: "%+.2f s", Double(valueMs) / 1000.0))
                    .font(Theme.Font.body.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityIdentifier("\(identifierPrefix).value")
            }
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(steps, id: \.self) { step in
                    Button { apply(valueMs + step.ms) } label: {
                        Text(Self.label(for: step.ms)).font(Theme.Font.meta)
                    }
                    .accessibilityIdentifier("\(identifierPrefix).\(step.id)")
                }
            }
            // Always laid out (disabled at 0) so the column keeps its height under focus.
            Button(String(localized: "Reset")) { apply(0) }
                .font(Theme.Font.meta)
                .disabled(valueMs == 0)
                .accessibilityIdentifier("\(identifierPrefix).reset")
        }
    }

    private func apply(_ ms: Int) {
        onChange(min(range.upperBound, max(range.lowerBound, ms)))
    }

    /// "−1 s", "+0.1 s": locale decimal separator, true minus sign like the old labels.
    private static func label(for ms: Int) -> String {
        let amount = (Double(abs(ms)) / 1000.0).formatted(.number.precision(.fractionLength(0...2)))
        return (ms < 0 ? "\u{2212}" : "+") + amount + " s"
    }
}

/// Small uppercase column/section caption ("LANGUAGE", "SPEAKERS & HEADPHONES") — the classic
/// tvOS panel's column headers.
struct PlayerPanelSectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.bottom, Theme.Spacing.xxs)
    }
}
