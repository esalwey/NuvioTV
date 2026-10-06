import SwiftUI
import SharedCore

/// Full-screen focusable poster grid for a single catalog ("See All"), backed by the shared
/// paginated `CatalogRepository`. Pushed from a `CatalogRowView` header via `CatalogRoute`.
///
/// This screen relies on the ancestor `NavigationStack` (Home / Search) for navigation: its poster
/// `NavigationLink`s push `TitleRoute`, which those stacks already resolve to `DetailView`.
struct CatalogGridView: View {
    let route: CatalogRoute
    @StateObject private var model: CatalogGridViewModel

    init(route: CatalogRoute) {
        self.route = route
        _model = StateObject(wrappedValue: CatalogGridViewModel(target: route.target))
    }

    @Environment(\.posterStyle) private var posterStyle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Spec §3.1 / §10: at accessibility text sizes the grid switches to the HIG's 5-column poster
    /// (320×480), so the larger focused titles still fit under each poster.
    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var cardWidth: CGFloat {
        accessibilityLayout
            ? Theme.Grid.itemWidth(columns: Theme.Grid.posterColumnsAccessibility)
            : posterStyle.width
    }
    private var cardHeight: CGFloat {
        accessibilityLayout ? cardWidth * 1.5 : posterStyle.height
    }

    /// Fixed-width columns at the HIG's 40pt gap: as many as fit, every poster the same size.
    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: cardWidth, maximum: cardWidth),
            spacing: Theme.Grid.spacing
        )]
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text(route.title)
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    if model.items.isEmpty {
                        stateView
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Grid.rowSpacing) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
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
                                // F13: shared long-press menu (library, watched).
                                .posterContextMenu(item)
                                .onAppear { model.itemAppeared(at: index) }
                            }
                        }

                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Spacing.xl)
                        }
                    }
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// Loading, error and empty states. VIS-14: error and empty use the system
    /// `ContentUnavailableView`.
    ///
    /// A pushed screen with no focusable content strands focus on the ancestor tab bar, where Menu
    /// exits the app instead of popping this screen (observed on tvOS 27; BUG-47's "crash to the
    /// home screen"). Every non-grid state therefore keeps a focusable Go Back control, so Menu
    /// always pops.
    @ViewBuilder
    private var stateView: some View {
        if model.isLoading {
            VStack(spacing: Theme.Spacing.lg) {
                ProgressView()
                Text("Loading\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button("Go Back") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.sectionGap)
        } else if let message = model.errorMessage {
            ContentUnavailableView {
                Label(String(localized: "catalog.error.title",
                             defaultValue: "Couldn\u{2019}t Load Titles",
                             comment: "Full catalog grid: title shown when the catalog failed to load"),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Go Back") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, Theme.Spacing.sectionGap)
        } else {
            ContentUnavailableView {
                Label(String(localized: "catalog.empty.title",
                             defaultValue: "No Titles",
                             comment: "Catalog grid and collection folder: title shown when there is nothing to show"),
                      systemImage: "film.stack")
            } description: {
                Text("No titles here yet.")
            } actions: {
                Button("Go Back") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, Theme.Spacing.sectionGap)
        }
    }
}
