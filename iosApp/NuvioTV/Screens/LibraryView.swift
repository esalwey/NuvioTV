import SwiftUI
import SharedCore

/// The Library tab: a focusable poster grid of the titles saved via "Add to Library" (tap opens
/// detail; long-press removes), plus — when a debrid provider with cloud support is connected —
/// a "Debrid Cloud" source listing the provider's cloud files for direct playback.
///
/// Wave 2 (X3): system controls only. The source switch is a pair of `.bordered` capsule pills
/// with a checkmark on the active one, the sort order is a system `Menu` (spec 6.5), and an empty
/// library is a `ContentUnavailableView` (VIS-14). Menu at this tab root falls through to the
/// system sidebar (VIS-16), so there is no exit handler here.
struct LibraryView: View {
    @StateObject private var model = LibraryViewModel()
    @StateObject private var cloud = CloudLibraryViewModel()
    @Environment(\.posterStyle) private var posterStyle
    @State private var showingCloud = false
    @State private var filePicker: CloudFilePickerRoute?

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

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: cardWidth, maximum: cardWidth),
            spacing: Theme.Grid.spacing
        )]
    }

    private var showsCloud: Bool { showingCloud && cloud.hasConnectedProvider }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text("Library")
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    controlsRow
                    filtersRow

                    if !showsCloud, model.isRemoteSource, let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }

                    if showsCloud {
                        cloudContent
                    } else if model.items.isEmpty {
                        if model.unfilteredCount > 0 {
                            noMatchesState
                        } else if model.isLoading || model.isSyncing {
                            loadingState
                        } else {
                            emptyState
                        }
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Grid.rowSpacing) {
                            ForEach(model.items, id: \.id) { item in
                                NavigationLink(value: TitleRoute(preview: item.toMetaPreview())) {
                                    PosterCard(
                                        title: item.name,
                                        imageURL: item.poster,
                                        width: accessibilityLayout ? cardWidth : nil,
                                        height: accessibilityLayout ? cardHeight : nil
                                    )
                                }
                                .cardFocusButtonStyle()
                                .posterButtonShape()
                                // F13: the shared long-press menu (its library row reads "Remove
                                // from Library" for a saved title), same as every other poster.
                                .posterContextMenu(item.toMetaPreview())
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
            .reportsScrollToTabBar(tab: "Library")
            .background(Theme.Palette.background.ignoresSafeArea())
            .navigationDestination(for: TitleRoute.self) { route in
                DetailView(preview: route.preview)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonDetailView(personId: route.id, personName: route.name)
            }
            .navigationDestination(for: EntityRoute.self) { route in
                EntityBrowseView(route: route)
            }
        }
        .onAppear {
            model.start()
            cloud.start()
        }
        .onDisappear {
            model.stop()
            cloud.stop()
        }
        .fullScreenCover(item: $filePicker) { route in
            CloudFilePickerView(item: route.item) { file in
                cloud.play(item: route.item, file: file)
            }
        }
        .fullScreenCover(item: $cloud.playback) { ctx in
            // `.id` forces a fresh player per context (same rule as StreamPickerView).
            PlayerScreen(context: ctx)
                .ignoresSafeArea()
                .id(ctx.id)
        }
    }

    // MARK: - Source switcher + sort

    /// Source pills (Saved / Debrid Cloud) and the Library source + list menus on the leading
    /// side, sync and sort on the trailing side. Its own focus section so Down from any control
    /// lands in the grid, and Up from the grid comes back here.
    @ViewBuilder
    private var controlsRow: some View {
        let showsSort = !showsCloud && model.unfilteredCount > 0 && !model.availableSortOptions.isEmpty
        let showsSource = !showsCloud && model.hasConnectedProvider
        let showsList = !showsCloud && model.isRemoteSource && model.sections.count > 1
        let showsSync = !showsCloud && model.isRemoteSource
        if cloud.hasConnectedProvider || showsSort || showsSource || showsList || showsSync {
            HStack(spacing: Theme.Spacing.md) {
                if cloud.hasConnectedProvider {
                    FilterPill(title: String(localized: "Saved"), isSelected: !showingCloud) {
                        showingCloud = false
                    }
                    FilterPill(title: String(localized: "Debrid Cloud"), isSelected: showingCloud) {
                        showingCloud = true
                    }
                }
                if showsSource {
                    sourceMenu
                }
                if showsList {
                    listMenu
                }
                Spacer(minLength: Theme.Spacing.xl)
                if showsSync {
                    syncButton
                }
                if showsSort {
                    sortMenu
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .focusSection()
        }
    }

    /// Type / Genre / Year / Watch Status, one system `Menu` each (same look as the sort menu).
    /// A menu whose filter is active shows its value instead of its name; every menu only offers
    /// values that leave something on screen (the shared faceting).
    @ViewBuilder
    private var filtersRow: some View {
        if !showsCloud && model.unfilteredCount > 0 {
            HStack(spacing: Theme.Spacing.md) {
                if !model.typeOptions.isEmpty {
                    typeMenu
                }
                if !model.genreOptions.isEmpty {
                    genreMenu
                }
                if !model.yearOptions.isEmpty {
                    yearMenu
                }
                watchedMenu
                if model.isFiltering {
                    Button {
                        model.clearFilters()
                    } label: {
                        Label("Clear Filters", systemImage: "xmark.circle")
                            .font(Theme.Font.meta)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .focusSection()
        }
    }

    // MARK: - Source, list and sync

    private var sourceMenu: some View {
        LibraryMenu(
            title: String(localized: "Source"),
            value: Self.sourceLabel(model.sourceMode),
            systemImage: "tray.full"
        ) {
            ForEach(Self.sources, id: \.name) { source in
                LibraryMenuItem(
                    title: Self.sourceLabel(source),
                    isSelected: model.sourceMode == source
                ) {
                    model.setSource(source)
                }
                .disabled(!model.isConnected(source))
            }
        }
    }

    private static let sources: [LibrarySourceMode] = [.local, .trakt, .simkl]

    private static func sourceLabel(_ mode: LibrarySourceMode) -> String {
        if mode == .trakt { return String(localized: "Trakt") }
        if mode == .simkl { return String(localized: "Simkl") }
        return String(localized: "Nuvio Library")
    }

    /// The remote list being shown (a Trakt list, a Simkl status).
    private var listMenu: some View {
        let selected = model.sections.first(where: { $0.type == model.selectedSectionKey })
        return LibraryMenu(
            title: String(localized: "List"),
            value: selected?.displayTitle,
            systemImage: "list.bullet"
        ) {
            ForEach(model.sections, id: \.type) { section in
                LibraryMenuItem(
                    title: section.displayTitle,
                    isSelected: section.type == model.selectedSectionKey
                ) {
                    model.selectSection(section.type)
                }
            }
        }
    }

    private var syncButton: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if model.isSyncing || model.isLoading {
                ProgressView()
            }
            Button {
                model.syncNow()
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.Font.meta)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(model.isSyncing)
        }
    }

    // MARK: - Filters

    private var typeMenu: some View {
        LibraryMenu(
            title: String(localized: "Type"),
            value: model.selectedType.map(Self.typeLabel),
            systemImage: "film.stack"
        ) {
            LibraryMenuItem(title: String(localized: "All Types"), isSelected: model.selectedType == nil) {
                model.setType(nil)
            }
            ForEach(model.typeOptions, id: \.key) { option in
                LibraryMenuItem(
                    title: Self.typeLabel(option.key),
                    isSelected: option.key == model.selectedType
                ) {
                    model.setType(option.key)
                }
            }
        }
    }

    private var genreMenu: some View {
        LibraryMenu(
            title: String(localized: "Genre"),
            value: model.selectedGenre,
            systemImage: "theatermasks"
        ) {
            LibraryMenuItem(title: String(localized: "All Genres"), isSelected: model.selectedGenre == nil) {
                model.setGenre(nil)
            }
            ForEach(model.genreOptions, id: \.key) { option in
                LibraryMenuItem(
                    title: option.key,
                    isSelected: option.key == model.selectedGenre
                ) {
                    model.setGenre(option.key)
                }
            }
        }
    }

    private var yearMenu: some View {
        LibraryMenu(
            title: String(localized: "Year"),
            value: model.selectedYear,
            systemImage: "calendar"
        ) {
            LibraryMenuItem(title: String(localized: "All Years"), isSelected: model.selectedYear == nil) {
                model.setYear(nil)
            }
            ForEach(model.yearOptions, id: \.key) { option in
                LibraryMenuItem(
                    title: option.key,
                    isSelected: option.key == model.selectedYear
                ) {
                    model.setYear(option.key)
                }
            }
        }
    }

    private var watchedMenu: some View {
        LibraryMenu(
            title: String(localized: "Watch Status"),
            value: model.watchedFilter == .all ? nil : Self.watchedLabel(model.watchedFilter),
            systemImage: "eye"
        ) {
            ForEach(Self.watchedFilters, id: \.name) { filter in
                LibraryMenuItem(
                    title: Self.watchedLabel(filter),
                    isSelected: model.watchedFilter == filter
                ) {
                    model.setWatched(filter)
                }
            }
        }
    }

    private static let watchedFilters: [LibraryWatchedFilter] = [.all, .watched, .unwatched]

    private static func watchedLabel(_ filter: LibraryWatchedFilter) -> String {
        if filter == .watched { return String(localized: "Watched") }
        if filter == .unwatched { return String(localized: "Unwatched") }
        return String(localized: "All Titles")
    }

    private static func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "movie": return String(localized: "Movies")
        case "series": return String(localized: "Series")
        case "tv": return String(localized: "TV")
        case "anime": return String(localized: "Anime")
        case "channel": return String(localized: "Channels")
        default: return type.capitalized
        }
    }

    // MARK: - Sort (shared LibraryDisplaySettingsRepository — persisted + profile-scoped)

    /// Spec 6.5: the sort order is a system `Menu` (one control instead of a row of chips). The
    /// current order is the button's label and carries the checkmark inside the menu.
    private var sortMenu: some View {
        Menu {
            ForEach(model.availableSortOptions, id: \.name) { option in
                Button {
                    model.setSort(option)
                } label: {
                    if option == model.sortOption {
                        Label(Self.sortLabel(option), systemImage: "checkmark")
                    } else {
                        Text(Self.sortLabel(option))
                    }
                }
            }
        } label: {
            Label(Self.sortLabel(model.sortOption), systemImage: "arrow.up.arrow.down")
                .font(Theme.Font.meta)
        }
        .buttonBorderShape(.capsule)
        .accessibilityLabel(Text(String(
            localized: "library.sort.accessibility",
            defaultValue: "Sort Order",
            comment: "Accessibility label of the Library sort menu; its value is the current order"
        )))
        .accessibilityValue(Text(Self.sortLabel(model.sortOption)))
    }

    private static func sortLabel(_ option: LibrarySortOption) -> String {
        if option == .default_ { return String(localized: "Trakt Order") }
        if option == .addedDesc { return String(localized: "Recently Added") }
        if option == .addedAsc { return String(localized: "Oldest First") }
        if option == .releasedDesc { return String(localized: "Newest Release") }
        if option == .releasedAsc { return String(localized: "Oldest Release") }
        if option == .titleAsc { return String(localized: "A\u{2013}Z") }
        if option == .titleDesc { return String(localized: "Z\u{2013}A") }
        return option.name
    }

    // MARK: - Debrid cloud content

    @ViewBuilder
    private var cloudContent: some View {
        if let error = cloud.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: 1100, alignment: .leading)
        }

        HStack(spacing: Theme.Spacing.md) {
            Button {
                cloud.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(Theme.Font.meta)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(cloud.isRefreshing)
            if cloud.isRefreshing {
                ProgressView()
            }
        }
        .focusSection()

        ForEach(cloud.providers, id: \.providerId) { provider in
            CloudProviderSection(
                provider: provider,
                resolvingFileKey: cloud.resolvingFileKey
            ) { item in
                selectCloudItem(item)
            }
        }
    }

    private func selectCloudItem(_ item: CloudLibraryItem) {
        let files = item.playableFiles
        if files.count == 1, let file = files.first {
            cloud.play(item: item, file: file)
        } else if !files.isEmpty {
            filePicker = CloudFilePickerRoute(item: item)
        }
    }

    /// VIS-14: the system empty state. Same strings as before, so existing translations apply.
    @ViewBuilder
    private var emptyState: some View {
        if model.isRemoteSource {
            ContentUnavailableView {
                Label("This List Is Empty", systemImage: "books.vertical")
            } description: {
                Text("Titles you add to this list on Trakt or Simkl appear here after a sync.")
            } actions: {
                Button("Sync") { model.syncNow() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.sectionGap)
        } else {
            ContentUnavailableView {
                Label(String(localized: "Your library is empty", defaultValue: "Your Library Is Empty",
                             comment: "Title of the Library empty state"),
                      systemImage: "books.vertical")
            } description: {
                Text("Add movies and shows with the + button on a title\u{2019}s page.")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.sectionGap)
        }
    }

    /// The filters hide every title: say so and offer the way out.
    private var noMatchesState: some View {
        ContentUnavailableView {
            Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("No titles in your library match these filters.")
        } actions: {
            Button("Clear Filters") { model.clearFilters() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.sectionGap)
    }

    /// A provider list is still on its way (first load or manual sync).
    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.sectionGap)
    }
}

// MARK: - Menu building blocks

/// One Library control menu: a capsule `Menu` that shows its name, or the active value once a
/// choice is made, with the choice checkmarked inside. Same look as the sort menu.
private struct LibraryMenu<Content: View>: View {
    let title: String
    let value: String?
    let systemImage: String
    private let content: Content

    init(
        title: String,
        value: String?,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Label(value ?? title, systemImage: systemImage)
                .font(Theme.Font.meta)
        }
        .buttonBorderShape(.capsule)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value ?? String(localized: "All")))
    }
}

/// A menu choice; the current one carries the system checkmark.
private struct LibraryMenuItem: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
