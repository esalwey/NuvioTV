import Combine
import SharedCore

/// The shared `LibraryItem`, named so SwiftUI files can use it: DeveloperToolsSupport (re-exported
/// by SwiftUI) declares a `LibraryItem` too, and `SharedCore.LibraryItem` resolves to the
/// `SharedCore` class. This file imports no SwiftUI, so the name is unambiguous here.
typealias NuvioLibraryItem = LibraryItem

/// Observes the shared `LibraryRepository` — the personal saved library that the detail screen's
/// "Add to Library" action writes to. Profile-scoped (reloads on profile switch via the Phase 4
/// lifecycle coordinator).
///
/// Besides the sorted items it owns the Library screen's view state: the active source
/// (Nuvio / Trakt / Simkl), the remote list ("section") being shown, the Type / Genre / Year /
/// Watched filters and the manual sync. Filtering and faceting are the shared
/// `LibraryFilteringKt.filterLibraryItems`; sorting is the shared `sortLibraryItems`.
@MainActor
final class LibraryViewModel: ObservableObject {
    /// Items already filtered and sorted per the shared `LibraryDisplaySettingsRepository` sort option.
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var sortOption: LibrarySortOption = .addedDesc
    /// Sort options valid for the active source (DEFAULT = Trakt rank, Trakt mode only).
    @Published private(set) var availableSortOptions: [LibrarySortOption] = []

    // MARK: Source

    /// The source actually shown. The shared repo falls back to `.local` when the chosen provider
    /// is not connected, so this is always something that can render.
    @Published private(set) var sourceMode: LibrarySourceMode = .local
    @Published private(set) var isTraktConnected = false
    @Published private(set) var isSimklConnected = false
    /// Lists of the active remote source (Trakt lists, Simkl statuses). Empty for the local library.
    @Published private(set) var sections: [LibrarySection] = []
    @Published private(set) var selectedSectionKey: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSyncing = false

    // MARK: Filters

    @Published private(set) var selectedType: String?
    @Published private(set) var selectedGenre: String?
    @Published private(set) var selectedYear: String?
    @Published private(set) var watchedFilter: LibraryWatchedFilter = .all
    @Published private(set) var typeOptions: [LibraryFilterOption] = []
    @Published private(set) var genreOptions: [LibraryFilterOption] = []
    @Published private(set) var yearOptions: [LibraryFilterOption] = []
    /// Titles in the list being shown before any filter — tells "empty library" from "no match".
    @Published private(set) var unfilteredCount = 0

    var isRemoteSource: Bool { sourceMode != .local }
    var hasConnectedProvider: Bool { isTraktConnected || isSimklConnected }
    var isFiltering: Bool {
        selectedType != nil || selectedGenre != nil || selectedYear != nil || watchedFilter != .all
    }

    private var rawItems: [LibraryItem] = []
    /// Lists as the provider reports them: only the ones that hold titles.
    private var rawSections: [LibrarySection] = []
    /// The user's own lists of the active remote library, empty ones included.
    private var ownLists: [TrackingLibraryTab] = []
    private var ownListsWatcher: FlowWatcher?
    private var watcher: FlowWatcher?
    private var displayWatcher: FlowWatcher?
    private var traktWatcher: FlowWatcher?
    private var simklWatcher: FlowWatcher?
    private var watchedWatcher: FlowWatcher?
    private var fullyWatchedWatcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        LibraryRepository.shared.ensureLoaded()
        LibraryDisplaySettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(LibraryRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? LibraryUiState else { return }
            if self.sourceMode != state.sourceMode {
                // A different source is a different library: its lists and facets do not carry over.
                self.selectedSectionKey = nil
                self.clearFilterSelection()
            }
            self.rawItems = state.items
            self.rawSections = state.sections
            self.sourceMode = state.sourceMode
            self.sections = self.sectionsIncludingEmptyLists()
            self.isLoading = state.isLoading
            let error = state.errorMessage ?? ""
            self.errorMessage = error.isEmpty ? nil : error
            self.republish()
        }
        // A list just created is empty, so the provider's sections leave it out; it still has to be
        // there to pick (and to add titles to). Re-derive when the lists change (create, rename,
        // delete, reorder).
        ownListsWatcher = FlowWatcherKt.watch(LibraryListsBridge.shared.managementInfo) { [weak self] emitted in
            guard let self else { return }
            self.ownLists = (emitted as? LibraryListManagementInfo)?.lists ?? []
            self.sections = self.sectionsIncludingEmptyLists()
            self.republish()
        }
        displayWatcher = FlowWatcherKt.watch(LibraryDisplaySettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? LibraryDisplaySettingsUiState else { return }
            self.sortOption = state.sortOption
            self.republish()
        }
        TraktAuthRepository.shared.ensureLoaded(profileId: ProfileRepository.shared.activeProfileId)
        traktWatcher = FlowWatcherKt.watch(TraktAuthRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? TraktAuthUiState else { return }
            self.isTraktConnected = state.mode == .connected
        }
        SimklAuthRepository.shared.ensureLoaded(profileId: ProfileRepository.shared.activeProfileId)
        simklWatcher = FlowWatcherKt.watch(SimklAuthRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? SimklAuthUiState else { return }
            self.isSimklConnected = state.mode == .connected
        }
        // The Watched filter follows the watched history live (a title marked watched from its
        // poster menu leaves the Unwatched list at once). Nothing to redo while it is off.
        WatchedRepository.shared.ensureLoaded()
        watchedWatcher = FlowWatcherKt.watch(WatchedRepository.shared.uiState) { [weak self] _ in
            guard let self, self.watchedFilter != .all else { return }
            self.republish()
        }
        fullyWatchedWatcher = FlowWatcherKt.watch(WatchedRepository.shared.fullyWatchedSeriesKeys) { [weak self] _ in
            guard let self, self.watchedFilter != .all else { return }
            self.republish()
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        displayWatcher?.cancel()
        displayWatcher = nil
        ownListsWatcher?.cancel()
        ownListsWatcher = nil
        traktWatcher?.cancel()
        traktWatcher = nil
        simklWatcher?.cancel()
        simklWatcher = nil
        watchedWatcher?.cancel()
        watchedWatcher = nil
        fullyWatchedWatcher?.cancel()
        fullyWatchedWatcher = nil
    }

    /// The provider's sections, plus an empty section for each of the user's own lists that holds
    /// nothing yet, in the order the user arranged them (the watchlist and other fixed lists
    /// first). Unchanged for the local library and for providers without lists of their own.
    private func sectionsIncludingEmptyLists() -> [LibrarySection] {
        guard isRemoteSource, !ownLists.isEmpty else { return rawSections }
        let ownKeys = Set(ownLists.map { $0.key })
        let byKey = Dictionary(rawSections.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
        let fixed = rawSections.filter { !ownKeys.contains($0.type) }
        let own = ownLists.map { tab in
            byKey[tab.key] ?? LibrarySection(type: tab.key, displayTitle: tab.title, items: [])
        }
        return fixed + own
    }

    /// Persist a new sort (shared repo: profile-scoped NSUserDefaults) — the watcher republishes.
    func setSort(_ option: LibrarySortOption) {
        LibraryDisplaySettingsRepository.shared.setSortOption(sortOption: option)
    }

    // MARK: - Source + list

    /// Switch the Library source. This is the same persisted choice as Settings > Library Source;
    /// the shared repo reloads the matching library and the state watcher republishes.
    func setSource(_ mode: LibrarySourceMode) {
        guard mode != sourceMode else { return }
        TrackingSettingsRepository.shared.setLibrarySourceMode(source: mode)
    }

    func isConnected(_ mode: LibrarySourceMode) -> Bool {
        if mode == .trakt { return isTraktConnected }
        if mode == .simkl { return isSimklConnected }
        return true
    }

    func selectSection(_ key: String) {
        guard key != selectedSectionKey else { return }
        selectedSectionKey = key
        republish()
    }

    /// User-initiated refresh of the active source (bypasses the provider cache).
    func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        LibraryRepository.shared.syncNow { [weak self] _ in
            // The suspend bridge resolves on whichever thread finished the coroutine.
            Task { @MainActor in
                self?.isSyncing = false
            }
        }
    }

    // MARK: - Filters

    func setType(_ key: String?) {
        selectedType = key
        republish()
    }

    func setGenre(_ key: String?) {
        selectedGenre = key
        republish()
    }

    func setYear(_ key: String?) {
        selectedYear = key
        republish()
    }

    func setWatched(_ filter: LibraryWatchedFilter) {
        watchedFilter = filter
        republish()
    }

    func clearFilters() {
        clearFilterSelection()
        republish()
    }

    private func clearFilterSelection() {
        selectedType = nil
        selectedGenre = nil
        selectedYear = nil
        watchedFilter = .all
    }

    /// Re-derive the published items: pick the remote list, filter, then sort via the shared rules
    /// (DEFAULT falls back to ADDED_DESC in local mode, exactly like mobile's Library screen).
    private func republish() {
        availableSortOptions = LibraryDisplaySettingsKt.availableLibrarySortOptions(sourceMode: sourceMode)

        // Remote sources show one list at a time (the first until the user picks another).
        var base = rawItems
        if isRemoteSource, !sections.isEmpty {
            // The chosen list; until one is chosen, the first that has titles (an empty list the
            // user just created must not become the landing page).
            let section = sections.first(where: { $0.type == selectedSectionKey })
                ?? sections.first(where: { !$0.items.isEmpty })
                ?? sections[0]
            if selectedSectionKey != section.type { selectedSectionKey = section.type }
            base = section.items
        } else if selectedSectionKey != nil {
            selectedSectionKey = nil
        }
        unfilteredCount = base.count

        let watchedIds: Set<String> = watchedFilter == .all ? [] : Self.watchedIds(in: base)
        let result = LibraryFilteringKt.filterLibraryItems(
            items: base,
            type: selectedType,
            genre: selectedGenre,
            year: selectedYear,
            watched: watchedFilter,
            watchedIds: watchedIds
        )
        selectedType = result.selectedType
        selectedGenre = result.selectedGenre
        selectedYear = result.selectedYear
        typeOptions = result.types
        genreOptions = result.genres
        yearOptions = result.years

        items = LibraryDisplaySettingsKt.sortLibraryItems(items: result.items, selected: sortOption, sourceMode: sourceMode)
    }

    /// Ids of the titles the user finished: a watched movie, or a series whose released episodes
    /// are all watched (the same test the poster badge and its context menu use).
    private static func watchedIds(in items: [LibraryItem]) -> Set<String> {
        var ids: Set<String> = []
        for item in items {
            if WatchedRepository.shared.isWatched(id: item.id, type: item.type, season: nil, episode: nil)
                || WatchedRepository.shared.isFullyWatchedSeries(id: item.id, type: item.type) {
                ids.insert(item.id)
            }
        }
        return ids
    }

    /// Remove a title from the library. `toggleSaved` flips an already-saved item back off.
    func remove(_ item: LibraryItem) {
        LibraryRepository.shared.toggleSaved(item: item)
    }

    deinit {
        watcher?.cancel()
        displayWatcher?.cancel()
        ownListsWatcher?.cancel()
        traktWatcher?.cancel()
        simklWatcher?.cancel()
        watchedWatcher?.cancel()
        fullyWatchedWatcher?.cancel()
    }
}
