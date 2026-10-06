import Combine
import Foundation
import SwiftUI
import SharedCore

/// Studio / network browse page (TMDB discover-by-company/network), pushed from the Detail
/// screen's company-logo chips via `EntityRoute`. Shows a header (logo, name, origin) plus
/// Popular / Top Rated / Recent rails per media type, each individually pageable.
///
/// TMDB-gated like `PersonDetailView`: the shared `fetchEntityBrowse` returns nil unless
/// TMDB is enabled with an API key, so `failed` drives a friendly empty state. Relies on the
/// ancestor `NavigationStack` (Home / Search / Library) to resolve `TitleRoute` pushes.

// MARK: - View model

@MainActor
final class EntityBrowseViewModel: ObservableObject {
    /// One rail's mutable paging state (shared `TmdbEntityRail` is immutable; we re-wrap it).
    struct RailState: Identifiable {
        let id: String
        let mediaType: TmdbEntityMediaType
        let railType: TmdbEntityRailType
        var items: [MetaPreview]
        var page: Int32
        var hasMore: Bool
        var isLoadingMore = false

        var title: String {
            // Kotlin enums are ObjC classes — compare with ==, don't switch-pattern-match.
            // Full phrases (not kind + media fragments) so word order can differ per locale.
            let isMovie = mediaType == .movie
            if railType == .popular {
                return isMovie ? String(localized: "Popular Movies") : String(localized: "Popular TV Shows")
            } else if railType == .topRated {
                return isMovie ? String(localized: "Top Rated Movies") : String(localized: "Top Rated TV Shows")
            } else {
                return isMovie ? String(localized: "Recent Movies") : String(localized: "Recent TV Shows")
            }
        }
    }

    @Published private(set) var header: TmdbEntityHeader?
    @Published private(set) var rails: [RailState] = []
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false

    private let entityKind: TmdbEntityKind
    private let entityId: Int32
    private let sourceType: String
    private let fallbackName: String
    private var didLoad = false
    /// Normalized TMDB language, captured once for rail paging (must match what
    /// `fetchEntityBrowse` used so the shared per-page cache keys line up).
    private var language = "en"

    init(route: EntityRoute) {
        self.entityKind = route.isNetwork ? TmdbEntityKind.network : TmdbEntityKind.company
        self.entityId = Int32(route.id)
        self.sourceType = route.sourceType
        self.fallbackName = route.name
    }

    func start() {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        language = TmdbMetadataServiceKt.normalizeTmdbLanguage(
            language: TmdbSettingsRepository.shared.snapshot().language
        )
        // suspend fun → Swift completion; may complete off-main, hop back. Uses the
        // `@Throws`-checked twin: an unchecked suspend function crossing to Swift SIGABRTs the
        // whole app on any non-cancellation failure instead of surfacing it here (see
        // `TmdbMetadataService.fetchPreviewEnrichmentChecked`'s KDoc, 2026-09-12).
        TmdbMetadataService.shared.fetchEntityBrowseChecked(
            entityKind: entityKind,
            entityId: entityId,
            sourceType: sourceType,
            fallbackName: fallbackName
        ) { [weak self] data, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                if let error {
                    NSLog("[EntityBrowseView] fetchEntityBrowseChecked failed: %@", String(describing: error))
                }
                guard let data else {
                    self.failed = true
                    return
                }
                self.header = data.header
                self.rails = data.rails.map { rail in
                    RailState(
                        id: "\(rail.mediaType.name)-\(rail.railType.name)",
                        mediaType: rail.mediaType,
                        railType: rail.railType,
                        items: rail.items,
                        page: rail.currentPage,
                        hasMore: rail.hasMore
                    )
                }
                self.failed = self.rails.isEmpty
            }
        }
    }

    /// Fires when a card near a rail's trailing edge appears; appends the next discover page.
    func itemAppeared(railId: String, index: Int) {
        guard let railIndex = rails.firstIndex(where: { $0.id == railId }) else { return }
        let rail = rails[railIndex]
        guard rail.hasMore, !rail.isLoadingMore, index >= rail.items.count - 5 else { return }
        rails[railIndex].isLoadingMore = true

        let nextPage = rail.page + 1
        // Uses the `@Throws`-checked twin — see the `start()` comment above.
        TmdbMetadataService.shared.fetchEntityRailPageChecked(
            entityKind: entityKind,
            entityId: entityId,
            mediaType: rail.mediaType,
            railType: rail.railType,
            language: language,
            page: nextPage
        ) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self,
                      let railIndex = self.rails.firstIndex(where: { $0.id == railId })
                else { return }
                self.rails[railIndex].isLoadingMore = false
                if let error {
                    NSLog("[EntityBrowseView] fetchEntityRailPageChecked failed: %@", String(describing: error))
                }
                guard let result else {
                    self.rails[railIndex].hasMore = false
                    return
                }
                // Discover pages can repeat titles across page boundaries — dedupe on id.
                var seen = Set(self.rails[railIndex].items.map { $0.id })
                let fresh = result.items.filter { seen.insert($0.id).inserted }
                self.rails[railIndex].items.append(contentsOf: fresh)
                self.rails[railIndex].page = nextPage
                self.rails[railIndex].hasMore = result.hasMore && !fresh.isEmpty
            }
        }
    }
}

// MARK: - View

struct EntityBrowseView: View {
    let route: EntityRoute

    @StateObject private var model: EntityBrowseViewModel

    /// BUG-34: anchors `.prefersDefaultFocus` on the header/description block so initial focus can
    /// never settle on a rail poster (see `topBlock`).
    @Namespace private var topFocusNamespace
    /// Drives the focus affordance on the otherwise non-interactive `topBlock`.
    @FocusState private var topFocused: Bool

    init(route: EntityRoute) {
        self.route = route
        _model = StateObject(wrappedValue: EntityBrowseViewModel(route: route))
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    topBlock

                    ForEach(model.rails) { rail in
                        // Each rail is its own focus region, so vertical D-pad moves land on the
                        // rail's nearest poster instead of geometrically skipping past it.
                        railRow(rail)
                            .focusSection()
                    }

                    if model.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.xl)
                    } else if model.failed {
                        Text("Couldn\u{2019}t load titles for \(route.name). A TMDB API key is required for studio and network pages.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Scope must wrap every focus candidate on the page (top block + all rails) for
                // `prefersDefaultFocus` on the top block to win.
                .focusScope(topFocusNamespace)
            }
        }
        .onAppear { model.start() }
    }

    // MARK: - Sections

    /// Header + description as ONE focusable — but non-interactive — region.
    ///
    /// Same shape (and same BUG-34 trap) as `PersonDetailView`: without this, the rail posters are
    /// the page's only focus candidates, so when the async rails land the focus engine claims the
    /// first poster, focus-scrolls the page down, and strands the header above the viewport with
    /// nothing above to move back to. This block renders from `route.name` on the very first frame,
    /// so it takes initial focus, holds it while the rails arrive, and gives D-pad Up out of the
    /// first rail a real destination. Select is inert; Menu still pops the screen.
    private var topBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            headerBlock

            if let description = model.header?.description_, !description.isEmpty {
                Text(description)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    // Keeps the focusable region shorter than the screen — a focus target taller
                    // than the viewport can only be scrolled to its nearest edge, which would put
                    // the header back off-screen when arrowing Up out of the rails.
                    .lineLimit(8)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        // Full-bleed width so an Up move from *any* poster (rails scroll horizontally) still finds
        // this block geometrically above it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { topFocusPlatter }
        .focusable()
        .focused($topFocused)
        .prefersDefaultFocus(true, in: topFocusNamespace)
        .accessibilityElement(children: .combine)
        .animation(.easeInOut(duration: 0.15), value: topFocused)
    }

    /// Focus affordance for `topBlock`. Drawn outside the block's bounds via negative padding so
    /// the unfocused layout is unchanged (no content shift on focus).
    private var topFocusPlatter: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.hero)
            .fill(Theme.Palette.surface.opacity(topFocused ? 0.9 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.hero)
                    .strokeBorder(Color.white.opacity(topFocused ? 0.55 : 0), lineWidth: 2) // neutral by design: the HIG contract bans accent focus rings (FEAT-14 is opt-in only)
            )
            .padding(-Theme.Spacing.md)
    }

    private var headerBlock: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            logoChip
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(model.header?.name ?? route.name)
                    .font(Theme.Font.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !subtitleLine.isEmpty {
                    Text(subtitleLine)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// TMDB logo art is mostly dark-on-transparent — same white capsule as Detail's logo strip.
    @ViewBuilder
    private var logoChip: some View {
        if let logo = model.header?.logo, !logo.isEmpty {
            AsyncImage(url: URL(string: logo)) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(model.header?.name ?? route.name)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.black)
                }
            }
            .frame(height: 64)
            .frame(minWidth: 80, maxWidth: 260)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
    }

    private var subtitleLine: String {
        var parts: [String] = []
        if let secondary = model.header?.secondaryLabel, !secondary.isEmpty { parts.append(secondary) }
        if let country = model.header?.originCountry, !country.isEmpty { parts.append(country) }
        parts.append(route.isNetwork ? String(localized: "Network") : String(localized: "Studio"))
        return parts.joined(separator: "  \u{00B7}  ")
    }

    @ViewBuilder
    private func railRow(_ rail: EntityBrowseViewModel.RailState) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(rail.title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                // HIG grid gap (40pt), the same as every other shelf.
                LazyHStack(spacing: Theme.Grid.spacing) {
                    ForEach(Array(rail.items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: TitleRoute(preview: item)) {
                            PosterCard(
                                title: item.name,
                                imageURL: item.poster,
                                width: Theme.Size.miniPosterWidth,
                                height: Theme.Size.miniPosterHeight
                            )
                        }
                        .cardFocusButtonStyle()
                        .posterButtonShape()
                        // F13: shared long-press menu (library, watched).
                        .posterContextMenu(item)
                        .onAppear { model.itemAppeared(railId: rail.id, index: index) }
                    }
                    if rail.isLoadingMore {
                        ProgressView()
                            .frame(width: Theme.Size.miniPosterWidth, height: Theme.Size.miniPosterHeight)
                    }
                }
                .padding(.vertical, Theme.Spacing.md)
            }
            .scrollClipDisabled()
        }
    }
}
