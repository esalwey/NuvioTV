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

                    if showsCloud {
                        cloudContent
                    } else if model.items.isEmpty {
                        emptyState
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

    /// Source pills on the leading side, sort on the trailing side. Its own focus section so Down
    /// from any control lands in the grid, and Up from the grid comes back here.
    @ViewBuilder
    private var controlsRow: some View {
        let showsSort = !showsCloud && !model.items.isEmpty && !model.availableSortOptions.isEmpty
        if cloud.hasConnectedProvider || showsSort {
            HStack(spacing: Theme.Spacing.md) {
                if cloud.hasConnectedProvider {
                    FilterPill(title: String(localized: "Saved"), isSelected: !showingCloud) {
                        showingCloud = false
                    }
                    FilterPill(title: String(localized: "Debrid Cloud"), isSelected: showingCloud) {
                        showingCloud = true
                    }
                }
                Spacer(minLength: Theme.Spacing.xl)
                if showsSort {
                    sortMenu
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .focusSection()
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
    private var emptyState: some View {
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
