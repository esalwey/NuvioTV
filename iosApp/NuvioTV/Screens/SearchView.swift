import SwiftUI
import SharedCore

/// The Search tab (VIS-04, F11, spec gap 9, decision D2).
///
/// The system search experience: `MainTabView` declares this tab with `role: .search`, and the
/// screen uses `.searchable`, so tvOS draws its own search field and keyboard: the linear keyboard
/// for the Siri Remote, dictation, typing from an iPhone, and the grid keyboard for game
/// controllers. That replaces the custom on-screen `SearchKeyboard` (SRC-1) and the plain
/// `TextField`. Results still appear while typing (debounced in `SearchViewModel`), and a query
/// is saved to Recent Searches when it is submitted or when one of its results is opened, never
/// per keystroke.
///
/// While the query is empty the screen doubles as **Discover**: recent searches plus the shared
/// `SearchRepository.discoverUiState` browsing (type, catalog, genre, then a paginated grid).
///
/// D2 device check: earlier builds avoided `.searchable` because its keyboard panel stayed on
/// screen over results and pushed pages. Here the modifier sits on the stack's ROOT content, not
/// on the `NavigationStack` or the `TabView`, so a pushed Detail page does not inherit it. If the
/// bleed comes back on hardware, launch with `-debug.searchLegacyField YES` (or set it from a
/// debug build) to get the plain-field fallback below without a rebuild.
struct SearchView: View {
    @StateObject private var model = SearchViewModel()
    @State private var query = ""
    /// SRC-1: explicit so opening a result can record the query before pushing it.
    @State private var path = NavigationPath()
    @Environment(\.posterStyle) private var posterStyle

    /// D2 fallback switch. Device-local and launch-latched: the presentation style must not
    /// change under a live search controller.
    private static let usesLegacyField = UserDefaults.standard.bool(forKey: "debug.searchLegacyField")

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Spec §3.1 / §10, same metrics as `CatalogGridView`: fixed-width poster columns at the
    /// HIG's 40pt gap, switching to the 5-column (320×480) poster at accessibility text sizes.
    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var cardWidth: CGFloat {
        accessibilityLayout
            ? Theme.Grid.itemWidth(columns: Theme.Grid.posterColumnsAccessibility)
            : posterStyle.width
    }
    private var cardHeight: CGFloat {
        accessibilityLayout ? cardWidth * 1.5 : posterStyle.height
    }

    private var gridColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: cardWidth, maximum: cardWidth),
            spacing: Theme.Grid.spacing
        )]
    }

    var body: some View {
        NavigationStack(path: $path) {
            searchRoot
                .navigationDestination(for: TitleRoute.self) { route in
                    DetailView(preview: route.preview)
                }
                .navigationDestination(for: CatalogRoute.self) { route in
                    CatalogGridView(route: route)
                }
                .navigationDestination(for: PersonRoute.self) { route in
                    PersonDetailView(personId: route.id, personName: route.name)
                }
                .navigationDestination(for: EntityRoute.self) { route in
                    EntityBrowseView(route: route)
                }
        }
        .onChange(of: query) { _, newValue in
            model.queryChanged(newValue)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Root

    @ViewBuilder
    private var searchRoot: some View {
        if Self.usesLegacyField {
            scrollContent(showsLegacyField: true)
        } else {
            scrollContent(showsLegacyField: false)
                .searchable(text: $query, prompt: Text(String(
                    localized: "search.prompt",
                    defaultValue: "Movies and Shows",
                    comment: "Placeholder in the Search tab's search field"
                )))
                .searchSuggestions {
                    ForEach(model.suggestions(for: query), id: \.self) { suggestion in
                        Label(suggestion, systemImage: "clock.arrow.circlepath")
                            .searchCompletion(suggestion)
                    }
                }
                .onSubmit(of: .search) { model.recordSearch(query) }
        }
    }

    private func scrollContent(showsLegacyField: Bool) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if showsLegacyField {
                    legacyField
                }
                if queryIsEmpty {
                    historyChips
                    // UX-8: the user can hide the whole Discover section (synced per profile);
                    // the page is then the search field plus recent searches.
                    if !model.hideDiscover {
                        discoverSection
                    }
                } else {
                    searchResults
                }
            }
            .padding(Theme.Spacing.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .reportsScrollToTabBar(tab: "Search")
        .background(Theme.Palette.background.ignoresSafeArea())
    }

    /// D2 fallback only: a plain field that opens tvOS's full-screen keyboard and dismisses on
    /// commit. No custom glass (spec gap 14): the system field style draws its own platter.
    private var legacyField: some View {
        TextField(String(
            localized: "search.prompt",
            defaultValue: "Movies and Shows",
            comment: "Placeholder in the Search tab's search field"
        ), text: $query)
            .font(Theme.Font.body)
            .onSubmit { model.recordSearch(query) }
    }

    private var queryIsEmpty: Bool {
        trimmedQuery.isEmpty
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SRC-1: a query goes to Recent Searches when one of its results is actually opened.
    private func openResult(_ item: MetaPreview) {
        model.recordSearch(query)
        path.append(TitleRoute(preview: item))
    }

    // MARK: - Search results (query non-empty)

    @ViewBuilder
    private var searchResults: some View {
        if let error = model.searchError {
            // Codex r1 on upstream 085e8dc6: a failed fan-out is not "No results". Name it and
            // offer the recovery (a manifest re-fetch, see `retrySearch()`).
            ContentUnavailableView {
                Label(String(
                    localized: "search.unavailable.title",
                    defaultValue: "Search Unavailable",
                    comment: "Title shown in Search when no add-on could be searched"
                ), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button {
                    model.retrySearch()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            .frame(maxWidth: .infinity)
        } else if model.showsNoResults {
            // System copy ("No Results for …" plus the spelling hint), localized by the OS.
            ContentUnavailableView.search(text: trimmedQuery)
                .frame(maxWidth: .infinity)
        } else if model.isLoading && model.sections.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                    .accessibilityLabel(Text(String(
                        localized: "search.loading",
                        defaultValue: "Searching",
                        comment: "Accessibility label of the spinner shown while a search runs"
                    )))
                Spacer()
            }
            .padding(.top, Theme.Spacing.sectionGap)
        }

        // Rows append as each catalog answers; rows already shown keep their place, so focus
        // never jumps while results stream in (QA §13 step 12).
        ForEach(model.sections, id: \.key) { section in
            CatalogRowView(section: section, onSelect: { item in openResult(item) })
        }
    }

    // MARK: - Recent searches

    @ViewBuilder
    private var historyChips: some View {
        if !model.history.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Recent Searches")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(model.history, id: \.self) { item in
                            FilterPill(title: item, systemImage: "clock.arrow.circlepath") {
                                query = item
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    model.removeHistory(item)
                                } label: {
                                    Label(String(localized: "Remove from history", defaultValue: "Remove from History",
                                                 comment: "Context menu item that deletes one recent search"),
                                          systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // MARK: - Discover (query empty)

    @ViewBuilder
    private var discoverSection: some View {
        if let discover = model.discover {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Discover")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                if !discover.typeOptions.isEmpty {
                    pillRow {
                        ForEach(discover.typeOptions, id: \.self) { option in
                            FilterPill(
                                title: typeLabel(option),
                                isSelected: widen(discover.selectedType) == option
                            ) { model.selectDiscoverType(option) }
                        }
                    }
                }

                if discover.catalogOptions.count > 1 {
                    pillRow {
                        ForEach(discover.catalogOptions, id: \.key) { option in
                            FilterPill(
                                title: option.catalogName,
                                subtitle: option.addonName,
                                isSelected: widen(discover.selectedCatalogKey) == option.key
                            ) { model.selectDiscoverCatalog(option.key) }
                        }
                    }
                }

                if !discover.genreOptions.isEmpty {
                    pillRow {
                        if discover.selectedCatalog?.genreRequired != true {
                            FilterPill(
                                title: String(localized: "All"),
                                isSelected: widen(discover.selectedGenre) == nil
                            ) { model.selectDiscoverGenre(nil) }
                        }
                        ForEach(discover.genreOptions, id: \.self) { genre in
                            FilterPill(
                                title: genre,
                                isSelected: widen(discover.selectedGenre) == genre
                            ) { model.selectDiscoverGenre(genre) }
                        }
                    }
                }

                discoverGrid(discover)
            }
        }
    }

    /// One horizontally scrolling row of pills, its own focus section so Up/Down move between
    /// rows instead of sliding sideways to the nearest pill.
    private func pillRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                content()
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    @ViewBuilder
    private func discoverGrid(_ discover: DiscoverUiState) -> some View {
        if discover.items.isEmpty {
            if discover.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, Theme.Spacing.xl)
            } else if let reason = discover.emptyStateReason {
                // Upstream 085e8dc6: RequestFailed with NO catalog options means an add-on MANIFEST
                // failed (SearchRepository.refreshDiscover's early return), not a catalog page.
                // Say so and offer the honest recovery: re-fetch the manifests.
                if reason == DiscoverEmptyStateReason.requestfailed, discover.catalogOptions.isEmpty {
                    ContentUnavailableView {
                        Label(String(
                            localized: "search.discover.addonsFailed.title",
                            defaultValue: "Add-ons Unavailable",
                            comment: "Title shown in Discover when the add-on manifests failed to load"
                        ), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(widen(discover.errorMessage) ?? String(localized: "Couldn't load your add-ons."))
                    } actions: {
                        Button {
                            AddonRepository.shared.refreshAll()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        discoverEmptyTitle(reason),
                        systemImage: discoverEmptySymbol(reason),
                        description: Text(discoverEmptyMessage(reason))
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Theme.Grid.rowSpacing) {
                ForEach(Array(discover.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: TitleRoute(preview: item)) {
                        PosterCard(
                            title: item.name,
                            imageURL: item.poster,
                            width: accessibilityLayout ? cardWidth : nil,
                            height: accessibilityLayout ? cardHeight : nil
                        )
                    }
                    .cardFocusButtonStyle()
                    .posterButtonShape()
                    // F13: the shared long-press menu, as on every other poster.
                    .posterContextMenu(item)
                    .onAppear { model.discoverItemAppeared(at: index) }
                }
            }
            if discover.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, Theme.Spacing.md)
            }
        }
    }

    // MARK: - Labels

    /// Kotlin `String?` properties can surface non-optional; force an explicit optional for ==.
    private func widen(_ value: String?) -> String? { value }

    private func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "movie": return String(localized: "Movies")
        case "series": return String(localized: "Series")
        case "tv": return String(localized: "TV")
        case "anime": return String(localized: "Anime")
        default: return type.capitalized
        }
    }

    // KMP exports these enum entries all-lowercase (like CloudLibraryItemType.webdownload).

    private func discoverEmptyTitle(_ reason: DiscoverEmptyStateReason) -> String {
        if reason == DiscoverEmptyStateReason.noactiveaddons {
            return String(localized: "search.discover.noAddons.title", defaultValue: "No Add-ons",
                          comment: "Title shown in Discover when no add-on is installed and enabled")
        }
        if reason == DiscoverEmptyStateReason.nodiscovercatalogs {
            return String(localized: "search.discover.noCatalogs.title", defaultValue: "Nothing to Browse",
                          comment: "Title shown in Discover when the add-ons expose no browsable catalog")
        }
        if reason == DiscoverEmptyStateReason.requestfailed {
            return String(localized: "search.discover.catalogFailed.title", defaultValue: "Catalog Unavailable",
                          comment: "Title shown in Discover when one catalog page failed to load")
        }
        return String(localized: "search.discover.empty.title", defaultValue: "Nothing Here Yet",
                      comment: "Title shown in Discover when the selected catalog or genre is empty")
    }

    private func discoverEmptySymbol(_ reason: DiscoverEmptyStateReason) -> String {
        if reason == DiscoverEmptyStateReason.noactiveaddons { return "puzzlepiece.extension" }
        if reason == DiscoverEmptyStateReason.requestfailed { return "exclamationmark.triangle" }
        return "square.stack.3d.up.slash"
    }

    private func discoverEmptyMessage(_ reason: DiscoverEmptyStateReason) -> String {
        if reason == DiscoverEmptyStateReason.noactiveaddons {
            return String(localized: "Install and enable an add-on to browse its catalogs.")
        }
        if reason == DiscoverEmptyStateReason.nodiscovercatalogs {
            return String(localized: "Your add-ons don't expose browsable catalogs.")
        }
        if reason == DiscoverEmptyStateReason.requestfailed {
            return String(localized: "Couldn't load this catalog. Try another genre or catalog.")
        }
        return String(localized: "Nothing here yet \u{2014} try another genre or catalog.")
    }
}

/// A capsule filter or recent-search pill, shared by Search and Library: the system `.bordered` button (translucent platter at
/// rest, white platter with a dark label on focus), so focus, press and Increase Contrast all come
/// from tvOS. Selection is a checkmark, never colour alone (HIG Color; spec §3.2), and there is no
/// custom glass on content (spec gap 14).
struct FilterPill: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if isSelected {
                    Image(systemName: "checkmark")
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .font(Theme.Font.meta)
            .padding(.horizontal, Theme.Spacing.xs)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
