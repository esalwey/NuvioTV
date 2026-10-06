import SharedCore
import SwiftUI

/// Horizontal "Upcoming" row under Continue Watching: one landscape card per followed show for
/// its next episode airing within the next two weeks (`UpcomingEpisodesRepository`, shared). Each
/// card carries the episode still, an `S02E05` badge and a `TODAY` / `IN 4 DAYS` pill; the
/// caption is the show's title over its year. Selecting a card pushes the show's Detail page —
/// there is nothing to play yet.
///
/// Structural twin of `ContinueWatchingRow` (HomeView.swift): the same reach/focus/pinned-title
/// conventions, because Home's focus engine and the pinned Nuvio-style hero depend on every row
/// laying out identically. Keep the two in step.
struct UpcomingRow: View {
    let items: [UpcomingEpisodeItem]
    /// UX-7: reports the focused card's item (or nil) so Home can drive the hero from it.
    var onItemFocusChange: ((UpcomingEpisodeItem?) -> Void)? = nil
    @FocusState private var focusedKey: String?
    /// Pinned-hero card reach — see `rowCardTopReach` / `rowCardBottomReach` in BrowseComponents.
    /// 0 (no-op) outside pinned Home.
    @Environment(\.rowCardTopReach) private var cardTopReach
    @Environment(\.rowCardBottomReach) private var cardBottomReach
    /// BUG-87/89 (rc11): see `EnvironmentValues.rowCardLinkFrameFloor`. 0 for every row but Home's
    /// last.
    @Environment(\.rowCardLinkFrameFloor) private var cardLinkFrameFloor

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Pinned mode overlays the title inside the shelf's reach band instead (see
            // CatalogRowView's structural comment — all paddings must stay positive).
            if cardTopReach == 0 {
                Text("Upcoming")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Spacing.rowGap) {
                    // Keyed by show (one card per show) so a re-sort moves cards instead of
                    // swapping contents under the focused position.
                    ForEach(items, id: \.showKey) { item in
                        NavigationLink(value: TitleRoute(preview: item.toMetaPreview())) {
                            LandscapeCard(
                                title: item.showTitle,
                                imageURL: item.imageUrl,
                                subtitle: item.showYear,
                                overlayLeading: Self.episodeCode(item),
                                overlayTrailing: Self.airDateLabel(daysUntilAir: Int(item.daysUntilAir))
                            )
                            .padding(.top, cardTopReach)
                            .padding(.bottom, cardBottomReach)
                            // BUG-87/89 (rc11): transparent floor on the REVEALED frame — 0 for
                            // every row but Home's last. `.top` so the artwork and caption do not
                            // move a point.
                            .frame(minHeight: cardLinkFrameFloor > 0 ? cardLinkFrameFloor : nil,
                                   alignment: .top)
                        }
                        .cardFocusButtonStyle()
                        .posterButtonShape()
                        .focused($focusedKey, equals: item.showKey)
                        .id(item.showKey)
                    }
                }
                // Always positive — the reach lives inside the buttons (see CatalogRowView).
                .padding(.vertical, Theme.Spacing.lg)
            }
            // BUG-37: pinned title rides down to the viewport's clip edge like every other row.
            .overlay(alignment: .topLeading) {
                if cardTopReach > 0 {
                    Text("Upcoming")
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                        // Wave 4 item 5: a fixed-height LandscapeCard shelf can state its artwork
                        // height directly — Theme.Size.landscapeHeight is LandscapeCard's own
                        // default `height` param, which this row never overrides. Cosmetically
                        // this only makes the probe's `cap=`/`intr=` readings truthful for this
                        // row (the cap itself stays PROBE-ONLY — see `PinnedRowTitle.slide`).
                        // Codex r7 P2: `isFocused` picks which clearance the belt judges this row
                        // by — only a FOCUSED row's cards are raised by the focus treatment.
                        .pinnedRowTitleTracking(rowKey: "upcoming",
                                                artworkHeight: Theme.Size.landscapeHeight,
                                                isFocused: focusedKey != nil)
                        .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                        .allowsHitTesting(false)
                }
            }
            .scrollClipDisabled()
        }
        .focusSection()
        // Settle re-reveal (2026-08-30) — one line, same as every other pinned row; see
        // `pinnedRowSettleTracking` in BrowseComponents for the mechanism and its guarantees.
        .pinnedRowSettleTracking(rowKey: "upcoming", isFocused: focusedKey != nil)
        // BUG-112 (Item A)
        .pinnedRowUpFallbackTarget(rowKey: "upcoming",
                                   firstId: items.first?.showKey,
                                   focus: $focusedKey)
        .onChange(of: focusedKey) { _, newKey in
            onItemFocusChange?(newKey.flatMap { key in items.first { $0.showKey == key } })
        }
    }

    /// `S02E05` — zero-padded like the reference design; not localized (a code, not a phrase).
    static func episodeCode(_ item: UpcomingEpisodeItem) -> String {
        String(format: "S%02dE%02d", Int(item.season), Int(item.episode))
    }

    /// Countdown pill copy. Explicit branches rather than a plural rule set — the app's
    /// convention (see StreamPickerView) and `daysUntilAir >= 2` in the last branch.
    static func airDateLabel(daysUntilAir: Int) -> String {
        switch daysUntilAir {
        case ...0: return String(localized: "TODAY")
        case 1: return String(localized: "TOMORROW")
        default: return String(localized: "IN \(daysUntilAir) DAYS")
        }
    }
}
