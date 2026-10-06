import SharedCore
import SwiftUI

/// One label/value row of the Info tab's stream section.
struct NativeInfoRow: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

/// Static what's-playing header for the Info tab, captured once from the PlaybackContext.
struct NativeInfoHeader: Equatable {
    let title: String
    /// "S1 · E4 · Episode name" for series (falls back to the stream label when the episode list
    /// doesn't carry a name), else the stream's own label (release name / addon line).
    let subtitle: String?
    let synopsis: String?
    let poster: String?
    /// True when `poster` is an episode still (16:9) rather than a 2:3 poster.
    let landscapeArtwork: Bool
    /// Release name / addon line — shown as a secondary line under the synopsis when it isn't
    /// already the subtitle.
    let streamLabel: String?

    init(context: PlaybackContext) {
        // AES-8: the series heads an episode's header when the meta cache knows it — the launch
        // title ("S1E4 · Name") repeated the subtitle line below it. The episode's own name then
        // moves to the subtitle: from the episode list, else out of that launch title (a launch
        // path without the list), so it is never lost. Without the series, the launch title stays
        // the title and the subtitle is built as before.
        let names = PlaybackTitleParts(context: context)
        title = names.series ?? context.title
        var parts: [String] = []
        var usedStreamLabel = false
        if let s = context.season, let e = context.episode {
            parts.append(String(localized: "S\(s) · E\(e)"))
            let listedName = context.episodes.first { $0.season?.value == s && $0.episode?.value == e }?.title
            let episodeName = names.series != nil ? names.episodeName : listedName
            if let episodeName, !episodeName.isEmpty {
                parts.append(episodeName)
            } else if let st = context.streamTitle, !st.isEmpty {
                parts.append(st); usedStreamLabel = true
            }
        } else if let st = context.streamTitle, !st.isEmpty {
            parts.append(st); usedStreamLabel = true
        }
        subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        synopsis = context.synopsis.flatMap { $0.isEmpty ? nil : $0 }
        let still = context.episodeStill.flatMap { $0.isEmpty ? nil : $0 }
        poster = still ?? context.poster.flatMap { $0.isEmpty ? nil : $0 }
        landscapeArtwork = still != nil
        streamLabel = usedStreamLabel ? nil : context.streamTitle.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Info tab: what's-playing header (art · title · S/E · synopsis), a metadata chip row (Infuse-style:
/// runtime · year · size · codec · resolution class · audio · bitrate · fps · genres · rating), then
/// the live stream rows in two columns. Nothing here is focusable — it's a read-only tab.
struct PlayerInfoTab: View {
    let info: PlayerPanelInfo

    /// Header art height; poster (2:3) or episode still (16:9) scale into it.
    private static let artHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            headerView
            if !info.chips.isEmpty { chipRow }
            Divider().overlay(Theme.Palette.outline)
            rowsView
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            if info.header.poster != nil {
                CachedAsyncImage(string: info.header.poster, contentMode: .fill)
                    .frame(width: info.header.landscapeArtwork ? Self.artHeight * 16 / 9 : Self.artHeight * 2 / 3,
                           height: Self.artHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(info.header.title)
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle = info.header.subtitle {
                    Text(subtitle)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                if let synopsis = info.header.synopsis {
                    Text(synopsis)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let label = info.header.streamLabel {
                    Text(label)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(info.chips) { chip in
                    HStack(spacing: Theme.Spacing.xxs) {
                        if let symbol = chip.symbol { Image(systemName: symbol) }
                        Text(chip.text)
                    }
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
                    .background(Theme.Palette.textPrimary.opacity(0.12), in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(info.chips.map(\.text).joined(separator: ", "))
    }

    /// Two columns of label/value pairs (a dozen live diagnostics don't fit one column under the
    /// header). Non-lazy `Grid` so the panel measures its full height up front.
    private var rowsView: some View {
        let rows = info.rows
        let half = (rows.count + 1) / 2
        return Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.xl, verticalSpacing: Theme.Spacing.xs) {
            ForEach(0..<max(half, 1), id: \.self) { i in
                GridRow {
                    if i < rows.count { rowView(rows[i]) } else { Color.clear.frame(height: 1) }
                    if i + half < rows.count { rowView(rows[i + half]) } else { Color.clear.frame(height: 1) }
                }
            }
            if rows.isEmpty {
                GridRow {
                    Text("No stream details yet.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .gridCellColumns(2)
                }
            }
        }
    }

    private func rowView(_ row: NativeInfoRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(row.label)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 260, alignment: .leading)
            Text(row.value)
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
