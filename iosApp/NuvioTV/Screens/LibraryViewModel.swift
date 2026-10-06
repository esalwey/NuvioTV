import Combine
import SharedCore

/// Observes the shared `LibraryRepository` — the personal saved library that the detail screen's
/// "Add to Library" action writes to. Profile-scoped (reloads on profile switch via the Phase 4
/// lifecycle coordinator).
@MainActor
final class LibraryViewModel: ObservableObject {
    /// Items already sorted per the shared `LibraryDisplaySettingsRepository` sort option.
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var sortOption: LibrarySortOption = .addedDesc
    /// Sort options valid for the active source (DEFAULT = Trakt rank, Trakt mode only).
    @Published private(set) var availableSortOptions: [LibrarySortOption] = []

    private var rawItems: [LibraryItem] = []
    private var sourceMode: LibrarySourceMode = .local
    private var watcher: FlowWatcher?
    private var displayWatcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        LibraryRepository.shared.ensureLoaded()
        LibraryDisplaySettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(LibraryRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? LibraryUiState else { return }
            self.rawItems = state.items
            self.sourceMode = state.sourceMode
            self.republish()
        }
        displayWatcher = FlowWatcherKt.watch(LibraryDisplaySettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? LibraryDisplaySettingsUiState else { return }
            self.sortOption = state.sortOption
            self.republish()
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        displayWatcher?.cancel()
        displayWatcher = nil
    }

    /// Persist a new sort (shared repo: profile-scoped NSUserDefaults) — the watcher republishes.
    func setSort(_ option: LibrarySortOption) {
        LibraryDisplaySettingsRepository.shared.setSortOption(sortOption: option)
    }

    /// Re-derive the published sorted items via the shared sort rules (DEFAULT falls back to
    /// ADDED_DESC in local mode, exactly like mobile's Library screen).
    private func republish() {
        availableSortOptions = LibraryDisplaySettingsKt.availableLibrarySortOptions(sourceMode: sourceMode)
        items = LibraryDisplaySettingsKt.sortLibraryItems(items: rawItems, selected: sortOption, sourceMode: sourceMode)
    }

    /// Remove a title from the library. `toggleSaved` flips an already-saved item back off.
    func remove(_ item: LibraryItem) {
        LibraryRepository.shared.toggleSaved(item: item)
    }

    deinit {
        watcher?.cancel()
        displayWatcher?.cancel()
    }
}
