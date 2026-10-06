import SharedCore
import SwiftUI

/// Subtitles tab, two columns (LANG-12):
/// - left: Off, then the file's embedded text tracks, then addon-fetched subtitles, one checkmark
///   row each. Addon rows are grouped by language under collapsible headers when they carry a
///   language and span more than one. Sections are labelled only when both embedded and addon
///   rows exist.
/// - right (only when the engine can re-time subtitles): "Timing", the subtitle delay control, in
///   its own focus section so it is one Right press away from the track list.
///
/// Focus: Down from the tab row lands on the CURRENT track (spec §8.2), via `.defaultFocus` with
/// `.userInitiated` priority so it wins over the focus engine's nearest-row pick.
struct PlayerSubtitlesTab: View {
    @ObservedObject var model: PlayerTopPanelModel
    /// Expanded addon language groups (by `AddonGroup.key`). Seeded once groups exist: the group
    /// holding the current pick plus the first (best-ranked) group.
    @State private var expandedGroups: Set<String> = []
    @State private var didSeedExpansion = false
    @FocusState private var focusedRow: String?

    private static let timingColumnWidth: CGFloat = 600

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.screen) {
            trackColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            if model.supportsSubtitleDelay {
                timingColumn
                    .frame(width: Self.timingColumnWidth, alignment: .leading)
                    .focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .topLeading)
        .defaultFocus($focusedRow, selectedRowID, priority: .userInitiated)
        .onAppear { seedExpansion() }
        .onChange(of: model.subtitles) { _, _ in seedExpansion() }
    }

    // MARK: - Tracks

    private var trackColumn: some View {
        let options = model.subtitles
        let embedded = options.filter { $0.group == .embedded }
        let addon = options.filter { $0.group == .addon }
        let off = options.first { $0.group == .off }
        let labelled = !embedded.isEmpty && !addon.isEmpty
        let groups = Self.addonGroups(addon)

        // Scrolls with focus (addon lists can run to a dozen+ rows).
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                PlayerPanelSectionCaption(text: String(localized: "Subtitles"))
                if let off { row(off) }
                if labelled { PlayerPanelSectionCaption(text: String(localized: "Embedded")).padding(.top, Theme.Spacing.sm) }
                ForEach(embedded) { row($0) }
                if labelled { PlayerPanelSectionCaption(text: String(localized: "From addons")).padding(.top, Theme.Spacing.sm) }
                if let groups {
                    ForEach(groups) { group in
                        groupHeader(group)
                        if expandedGroups.contains(group.key) {
                            ForEach(group.options) { row($0) }
                        }
                    }
                } else {
                    ForEach(addon) { row($0) }
                }
                statusRows(isEmpty: embedded.isEmpty && addon.isEmpty)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ option: PlayerPanelOption) -> some View {
        PlayerPanelOptionRow(option: option, identifierPrefix: "player.panel.subtitle") {
            model.onSelectSubtitle?(option.group == .off ? nil : option)
        }
        .focused($focusedRow, equals: option.id)
    }

    /// Empty, searching and late states (LANG-08, UI half). Appended under the list so rows that
    /// arrive late never move the row that has focus.
    @ViewBuilder
    private func statusRows(isEmpty: Bool) -> some View {
        if isEmpty {
            HStack(spacing: Theme.Spacing.xs) {
                if model.subtitlesSearching { ProgressView().scaleEffect(0.6) }
                Text(model.subtitlesSearching
                     ? String(localized: "Searching addon subtitles…")
                     : String(localized: "No subtitles for this title"))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.top, Theme.Spacing.xs)
        } else if model.subtitlesSearching {
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().scaleEffect(0.6)
                Text(String(localized: "Searching addon subtitles…"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.top, Theme.Spacing.xs)
        }
        if model.lateAddonSubtitleCount > 0 {
            Text(String(localized: "player.subtitles.lateFound",
                        defaultValue: "\(model.lateAddonSubtitleCount) found after playback started",
                        comment: "Subtitles tab footnote: number of addon subtitles that arrived after playback had started."))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.top, Theme.Spacing.xs)
                .accessibilityIdentifier("player.panel.subtitle.lateFound")
        }
    }

    /// The row to focus when the list is entered: the checked one (Off when subtitles are off).
    private var selectedRowID: String? {
        model.subtitles.first(where: \.isSelected)?.id
    }

    // MARK: - Addon language groups

    private struct AddonGroup: Identifiable {
        let key: String
        let title: String
        var options: [PlayerPanelOption]
        var id: String { key }
        var containsSelection: Bool { options.contains(where: \.isSelected) }
    }

    private static let otherGroupKey = "~other"

    /// Groups addon rows by language, keeping the engine's ranking (a group sits where its first
    /// row was). nil = show the flat list: no row carries a language, or everything is one group.
    private static func addonGroups(_ addon: [PlayerPanelOption]) -> [AddonGroup]? {
        guard addon.contains(where: { !($0.language ?? "").isEmpty }) else { return nil }
        var groups: [AddonGroup] = []
        var indexByKey: [String: Int] = [:]
        for option in addon {
            let code = option.language.flatMap { $0.isEmpty ? nil : $0 }
            let key = code.map { TrackLabelFormatter.normalizedTag($0) ?? $0.lowercased() } ?? otherGroupKey
            if let index = indexByKey[key] {
                groups[index].options.append(option)
            } else {
                let title = code.map { TrackLabelFormatter.languageName($0) ?? $0 }
                    ?? String(localized: "player.subtitles.otherLanguages",
                              defaultValue: "Other Languages",
                              comment: "Subtitles tab: header of the addon subtitles whose language is unknown.")
                indexByKey[key] = groups.count
                groups.append(AddonGroup(key: key, title: title, options: [option]))
            }
        }
        return groups.count > 1 ? groups : nil
    }

    private func groupHeader(_ group: AddonGroup) -> some View {
        let expanded = expandedGroups.contains(group.key)
        return Button {
            if expanded { expandedGroups.remove(group.key) } else { expandedGroups.insert(group.key) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(Theme.Font.body.weight(.semibold))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(Theme.Font.body)
                        .lineLimit(1)
                    // Collapsed over the current pick: say which one, so the checkmark isn't lost.
                    if !expanded, let picked = group.options.first(where: \.isSelected) {
                        Text(picked.title)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(group.options.count.formatted())
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .focused($focusedRow, equals: "group:" + group.key)
        .accessibilityIdentifier("player.panel.subtitle.group.\(group.key)")
        .accessibilityValue(Text(expanded
                                 ? String(localized: "player.subtitles.group.expanded", defaultValue: "Expanded",
                                          comment: "Accessibility value of an expanded subtitle language group.")
                                 : String(localized: "player.subtitles.group.collapsed", defaultValue: "Collapsed",
                                          comment: "Accessibility value of a collapsed subtitle language group.")))
    }

    /// Opens the group holding the current pick and the best-ranked group, once. Rows that
    /// arrive later (late addon fetch) don't re-open groups the viewer closed.
    private func seedExpansion() {
        guard !didSeedExpansion else { return }
        let addon = model.subtitles.filter { $0.group == .addon }
        guard let groups = Self.addonGroups(addon) else { return }
        didSeedExpansion = true
        var keys: Set<String> = [groups[0].key]
        if let selected = groups.first(where: \.containsSelection) { keys.insert(selected.key) }
        expandedGroups.formUnion(keys)
    }

    // MARK: - Timing (subtitle delay)

    private var timingColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            PlayerPanelSectionCaption(text: String(localized: "Timing"))
            PlayerPanelDelayControl(
                title: String(localized: "Subtitle Delay"),
                valueMs: model.subtitleDelayMs,
                // Mobile's 100 ms step plus ±1 s jumps for the remote.
                steps: [.init(ms: -1000, id: "minus1"), .init(ms: -100, id: "minus"),
                        .init(ms: 100, id: "plus"), .init(ms: 1000, id: "plus1")],
                range: Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MIN_MS)...Int(SubtitleAudioModelsKt.SUBTITLE_DELAY_MAX_MS),
                identifierPrefix: "player.panel.subtitleDelay"
            ) { model.onSubtitleDelayChange?($0) }
            Text(String(localized: "player.subtitles.delay.hint",
                        defaultValue: "Positive values show subtitles later.",
                        comment: "Subtitles tab: explanation under the subtitle delay control."))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Spacing.xxs)
        }
    }
}
