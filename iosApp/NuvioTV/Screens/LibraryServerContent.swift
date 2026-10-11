import Combine
import SwiftUI
import SharedCore

/// Backs the Library tab's "Servers" source: one shelf per selected Jellyfin / Emby library.
///
/// Thin mirror of the shared `loadServerShelves()` (the non-UI half of upstream's
/// `LibraryServerContent`): a shelf is the library's newest titles, or the reason it could not load,
/// and one failing library never hides the others. `hasLibraries` drives whether the source pill
/// exists at all; shelves are only fetched while the Servers source is on screen.
@MainActor
final class LibraryServerViewModel: ObservableObject {
    struct Shelf: Identifiable {
        let id: String
        let title: String
        let section: HomeCatalogSection?
        let failureMessage: String?
    }

    /// At least one enabled server has a selected library: the Servers source is worth offering.
    @Published private(set) var hasLibraries = false
    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var isLoading = false
    /// Set when the whole load failed (not one library): shown with a Try Again instead of the
    /// "No libraries selected" empty state, which would be a lie.
    @Published private(set) var loadFailureMessage: String?

    private var watcher: FlowWatcher?
    private var isActive = false
    private var signature = ""
    private var generation = 0

    func start() {
        guard watcher == nil else { return }
        MediaServersController.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(MediaServersController.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? MediaServersUiState else { return }
            self.apply(state)
        }
        // Back from a title or a grid: a load that was cut off by `stop()` is started again.
        if isActive && (shelves.isEmpty || isLoading) { reload() }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        generation += 1
    }

    /// The Servers source was switched on or off. Switching on always fetches fresh shelves.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active { reload() }
    }

    func reload() {
        generation += 1
        load(generation: generation, retriesLeft: 1)
    }

    /// A nil answer means the load itself failed (the connections changed under it, for instance),
    /// not that there is nothing to show: it is tried once more, then reported.
    private func load(generation current: Int, retriesLeft: Int) {
        isLoading = true
        loadFailureMessage = nil
        LibraryServerShelvesKt.loadServerShelves { [weak self] loaded, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                if let loaded {
                    self.isLoading = false
                    let result: [LibraryServerShelf] = loaded
                    self.shelves = result.map(Self.shelf(from:))
                } else if retriesLeft > 0 {
                    self.load(generation: current, retriesLeft: retriesLeft - 1)
                } else {
                    self.isLoading = false
                    self.shelves = []
                    self.loadFailureMessage = ServerFailureText.message(failure: "FAILED")
                }
            }
        }
    }

    private func apply(_ state: MediaServersUiState) {
        // Every enabled server's selected libraries, in order: a change here is a different set of
        // shelves, so an active Servers source reloads; unrelated emissions (a refresh spinner, a
        // connect in progress) do not.
        let current = state.servers
            .filter { $0.enabled }
            .flatMap { server in server.libraries.filter { $0.selected }.map { "\(server.id):\($0.id)" } }
        hasLibraries = !current.isEmpty
        let next = current.joined(separator: "|")
        guard next != signature else { return }
        signature = next
        if isActive { reload() }
    }

    private static func shelf(from shelf: LibraryServerShelf) -> Shelf {
        let ref = shelf.ref
        let failure: ServerFailure? = shelf.failure
        let message = failure.map { ServerFailureText.message(for: $0) }
        return Shelf(
            id: "\(ref.connection.id):\(ref.library.id)",
            title: ref.title,
            section: shelf.section,
            failureMessage: message
        )
    }
}

/// The Library tab's Servers source: Home-style rows, one per library. A row's trailing See All card
/// opens the full paged grid of that library, a title opens the ordinary Detail page, and a
/// collection opens its own grid (see `TitleDestinationView`).
struct LibraryServerContentView: View {
    @ObservedObject var model: LibraryServerViewModel

    var body: some View {
        if model.shelves.isEmpty {
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Spacing.sectionGap)
            } else if let message = model.loadFailureMessage {
                failureRow(title: String(localized: "Servers"), message: message)
                    .padding(.top, Theme.Spacing.sectionGap)
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No libraries selected"), systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Choose which libraries to show in Settings, under Account & Services, then Media Servers.")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.sectionGap)
            }
        } else {
            ForEach(model.shelves) { shelf in
                if let section = shelf.section, !section.items.isEmpty {
                    CatalogRowView(section: section)
                } else if let message = shelf.failureMessage {
                    failureRow(title: shelf.title, message: message)
                }
            }
        }
    }

    /// A library that could not load keeps its place with the reason and a way to try again; the
    /// other libraries are unaffected.
    private func failureRow(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button {
                model.reload()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(Theme.Font.meta)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}
