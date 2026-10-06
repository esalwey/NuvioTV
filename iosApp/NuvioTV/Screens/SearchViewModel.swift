import Combine
import Foundation
import SharedCore

/// Drives the Search screen. Observes the installed addons (to pass into `SearchRepository.search`
/// and `refreshDiscover`), the shared `SearchRepository.uiState` (results, as `[HomeCatalogSection]`),
/// the Discover state (`discoverUiState` — genre/catalog browsing shown while the query is empty),
/// and the per-profile search history (`SearchHistoryRepository`).
///
/// Queries are debounced so we don't fire a request on every keystroke.
@MainActor
final class SearchViewModel: ObservableObject {
    /// FEAT-10: which search-capable catalogs the user has switched OFF in Settings →
    /// Content Sources → Search Sources. Stored as their stable `manifestId:type:catalogId`
    /// keys. Local to this Apple TV (not synced), like the appearance toggles — keys for
    /// since-uninstalled addons linger harmlessly (they never match) and re-arm if the
    /// addon comes back.
    ///
    /// SRC-2: per PROFILE — under `ProfileScopedKey`'s "<base>_<profileId>" shape, which
    /// `AccountDataStores` ("SearchSourceSettings (tvOS)") wipes at sign-out. A profile that has
    /// never saved its own choice starts from the device-wide value earlier builds stored.
    enum SearchSourceSettings {
        private static let legacyDefaultsKey = "search_disabled_catalog_keys"

        private static var defaultsKey: String {
            "\(legacyDefaultsKey)_\(ProfileRepository.shared.activeProfileId)"
        }

        static var disabledKeys: Set<String> {
            let defaults = UserDefaults.standard
            if let keys = defaults.stringArray(forKey: defaultsKey) { return Set(keys) }
            return Set(defaults.stringArray(forKey: legacyDefaultsKey) ?? [])
        }

        static func setDisabled(_ disabled: Bool, forKey key: String) {
            var keys = disabledKeys
            if disabled { keys.insert(key) } else { keys.remove(key) }
            UserDefaults.standard.set(Array(keys).sorted(), forKey: defaultsKey)
        }

        /// Persists an entire resolved disabled-keys set in one write. Callers that compute a
        /// whole new set (e.g. the collision-group resolver in `SettingsViewModel.setSearchSource`)
        /// should use this instead of a remove/add diff loop: a single `UserDefaults.set` call is
        /// atomic for this purpose, so app termination mid-update can't land on a torn state where
        /// some sibling keys were persisted and others weren't.
        static func setAll(_ keys: Set<String>) {
            UserDefaults.standard.set(Array(keys).sorted(), forKey: defaultsKey)
        }
    }
    @Published private(set) var sections: [HomeCatalogSection] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var emptyMessage: String?
    /// VIS-14: a settled search came back empty. Drives the system `ContentUnavailableView.search`.
    var showsNoResults: Bool { emptyMessage != nil }
    /// Upstream 085e8dc6 / Codex r1+r4: a non-empty query that could not be searched because every
    /// enabled add-on's MANIFEST failed to load — the state this batch introduced. Rendered with a
    /// Retry that re-fetches the manifests. Deliberately NOT set for catalog-level RequestFailed:
    /// the shared `toSection()` treats an empty catalog page as an error, so an all-empty search
    /// also publishes RequestFailed and must keep reading as "No results." (pre-existing behaviour).
    @Published private(set) var searchError: String?
    /// BUG-33 defect 1 instrumentation: passthrough of `SearchUiState.lastFanOut` — a
    /// human-readable "searched N of M catalogs" line set by the shared repo right after the
    /// last `search()` call. Settings → Content Sources → Search Sources renders the same value
    /// via its own watcher on `SearchRepository.shared.uiState` (this tab and the Settings tab
    /// hold independent view-model instances, so each watches the shared state directly rather
    /// than one passing a value to the other).
    @Published private(set) var lastFanOut: String?
    /// Recent searches for this profile (most recent first).
    @Published private(set) var history: [String] = []
    /// Shared Discover state: type/catalog/genre options + a paginated item grid.
    @Published private(set) var discover: DiscoverUiState?
    /// UX-8: the user hid the whole Discover section (synced home-catalog setting). Seeded from
    /// the repository snapshot so the very first frame is right, then live via the watcher.
    @Published private(set) var hideDiscover = HomeCatalogSettingsRepository.shared.snapshot().hideDiscover
    private var catalogSettingsWatcher: FlowWatcher?

    private var addonWatcher: FlowWatcher?
    private var searchWatcher: FlowWatcher?
    private var discoverWatcher: FlowWatcher?
    private var historyWatcher: FlowWatcher?
    private var enabledAddons: [ManagedAddon] = []
    private var lastDiscoverAddonSignature: String?
    /// Upstream 085e8dc6 (#1819): the trimmed query currently being searched (nil while the field
    /// is empty). `SearchRepository.search` only recomputes its pending-manifest state when it is
    /// called again, and this screen otherwise calls it only from the typing debounce — so an addon
    /// manifest landing or failing mid-query has to re-issue the search itself.
    private var activeQuery: String?
    private var lastSearchAddonSignature: String?
    private var debounce: Task<Void, Never>?
    private var started = false

    /// H2 hardening (BUG-47), mirrors `CatalogGridViewModel.stopped`: `FlowWatcher.cancel()`'s
    /// cancellation is cooperative, so a resume already queued on the main run loop can deliver one
    /// more value to a callback AFTER `stop()` returns, driving `@Published` mutations into a view
    /// mid-pop. One flag for all four watchers — they're always started and stopped together.
    private var stopped = false

    func start() {
        guard !started else { return }
        started = true
        stopped = false

        searchWatcher = FlowWatcherKt.watch(SearchRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? SearchUiState else { return }
            self.isLoading = state.isLoading
            self.sections = state.sections
            let settledEmpty = state.sections.isEmpty && !state.isLoading
            // KMP exports enum entries all-lowercase (like DiscoverEmptyStateReason.requestfailed).
            // Manifest failure = RequestFailed while no enabled add-on has a manifest at all.
            let manifestFailure = settledEmpty
                && state.emptyStateReason == SearchEmptyStateReason.requestfailed
                && !self.enabledAddons.contains(where: { $0.manifest != nil })
            let errorText: String? = state.errorMessage
            self.searchError = manifestFailure ? (errorText ?? String(localized: "Couldn't load your add-ons.")) : nil
            self.emptyMessage = settledEmpty && !manifestFailure && state.emptyStateReason != nil
                ? String(localized: "No results.")
                : nil
            self.lastFanOut = state.lastFanOut
        }

        discoverWatcher = FlowWatcherKt.watch(SearchRepository.shared.discoverUiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? DiscoverUiState else { return }
            self.discover = state
        }

        historyWatcher = FlowWatcherKt.watch(SearchHistoryRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let items = emitted as? [String] else { return }
            self.history = items
        }
        SearchHistoryRepository.shared.ensureLoaded()

        // UX-8: follow the synced Hide Discover flag. When it flips back OFF while the screen is
        // up, re-arm so the section rebuilds (refreshDiscoverIfNeeded early-returns on a matching
        // addon signature and would otherwise leave `discover` stale/nil).
        catalogSettingsWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? HomeCatalogSettingsUiState else { return }
            let wasHidden = self.hideDiscover
            self.hideDiscover = state.hideDiscover
            if wasHidden && !state.hideDiscover {
                self.lastDiscoverAddonSignature = nil
                self.refreshDiscoverIfNeeded()
            }
        }

        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, !self.stopped else { return }
            guard let state = emitted as? AddonsUiState else { return }
            self.enabledAddons = AddonModelsKt.enabledAddons(state.addons)
            self.refreshDiscoverIfNeeded()
            self.researchIfAddonsChanged()
        }

        AddonRepository.shared.initialize()
    }

    func stop() {
        // H2: flip first, before tearing down the watchers — see the `stopped` doc comment.
        stopped = true
        debounce?.cancel()
        addonWatcher?.cancel()
        searchWatcher?.cancel()
        discoverWatcher?.cancel()
        historyWatcher?.cancel()
        catalogSettingsWatcher?.cancel()
        addonWatcher = nil
        searchWatcher = nil
        discoverWatcher = nil
        historyWatcher = nil
        catalogSettingsWatcher = nil
        started = false
        // Re-arm Discover for the next start(): refreshDiscoverIfNeeded() early-returns when
        // the signature already matches, so without this the section would never rebuild.
        // canReuseDiscoverState in the repository still avoids redundant network work.
        lastDiscoverAddonSignature = nil
        // `activeQuery` deliberately survives: the view's `@State query` outlives a tab switch and
        // `.onChange(of: query)` won't refire, so the next addon emission after start() must still
        // be able to re-issue. The repository's same-key early return keeps that a no-op otherwise.
        lastSearchAddonSignature = nil
    }

    /// Called as the search text changes; debounces, then queries (or resets on empty).
    func queryChanged(_ text: String) {
        debounce?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            // `.reset()` is the nuclear account/profile-teardown variant — it also wipes
            // discoverSources, which permanently kills the Discover section here since
            // nothing ever re-arms it. Use `.clear()`, which only resets search state. (BUG-33(2))
            SearchRepository.shared.clear()
            sections = []
            emptyMessage = nil
            searchError = nil
            activeQuery = nil
            return
        }

        // Spec 6.4: ~300 ms after the last key. The system search keyboard reports every
        // character, and dictation or an iPhone keyboard can deliver a whole word at once.
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.activeQuery = trimmed
            self.lastSearchAddonSignature = self.addonManifestSignature
            SearchRepository.shared.search(
                query: trimmed,
                addons: self.enabledAddons,
                // FEAT-10: sources switched off in Settings → Content Sources → Search
                // Sources. Read fresh per query so a settings change applies immediately.
                disabledCatalogKeys: Self.SearchSourceSettings.disabledKeys,
                forceRefresh: false
            )
        }
    }

    // MARK: - Search history

    /// Record a committed query (keyboard submit, or a result opened), so partial typing doesn't
    /// pollute history. The shared repository ignores it while Recent Searches is off.
    func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SearchHistoryRepository.shared.recordSearch(query: trimmed)
    }

    func removeHistory(_ query: String) {
        SearchHistoryRepository.shared.removeSearch(query: query)
    }

    /// Spec 6.4 `.searchSuggestions`: recent searches that contain what has been typed so far,
    /// most recent first. Empty while nothing is typed (the Recent Searches row shows them then)
    /// and once the text already equals a recent search.
    func suggestions(for text: String) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        return Array(history.lazy.filter { item in
            item.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                && item.compare(typed, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }.prefix(5))
    }

    // MARK: - Discover

    /// Per-addon manifest-load state, not just the URL set: a manifest landing or failing changes
    /// nothing about `manifestUrl`, so the old URL-only signature never re-armed Discover after the
    /// initial pending state and the "Install and enable an add-on" copy stuck for an addon that
    /// WAS installed (upstream 085e8dc6, #1819). Only flips when `manifest`/`isRefreshing` change,
    /// so a normal launch with cached manifests still dedupes exactly as before.
    private var addonManifestSignature: String {
        enabledAddons
            .map { "\($0.manifestUrl)|\($0.manifest != nil ? 1 : 0)|\($0.isRefreshing ? 1 : 0)" }
            .sorted()
            .joined(separator: ",")
    }

    /// (Re)build the Discover catalog options when the enabled-addon set changes.
    private func refreshDiscoverIfNeeded() {
        // UX-8: nothing to build while the section is hidden — skips the addon fan-out too. The
        // catalog-settings watcher re-arms `lastDiscoverAddonSignature` when the flag clears.
        guard !hideDiscover else { return }
        let signature = addonManifestSignature
        guard signature != lastDiscoverAddonSignature else { return }
        lastDiscoverAddonSignature = signature
        SearchRepository.shared.refreshDiscover(addons: enabledAddons, forceRefresh: false)
    }

    /// Retry for `searchError` (a manifest failure): re-fetch the manifests — the same recovery
    /// Discover offers. The addon watcher then re-issues the active search when they land.
    func retrySearch() {
        AddonRepository.shared.refreshAll()
    }

    /// Re-issue the active search when an enabled addon's manifest state changes. The repository
    /// keys requests on the pending flag + catalog set, so an unchanged fan-out is a no-op there.
    private func researchIfAddonsChanged() {
        guard let activeQuery else { return }
        let signature = addonManifestSignature
        guard signature != lastSearchAddonSignature else { return }
        lastSearchAddonSignature = signature
        SearchRepository.shared.search(
            query: activeQuery,
            addons: enabledAddons,
            disabledCatalogKeys: Self.SearchSourceSettings.disabledKeys,
            forceRefresh: false
        )
    }

    func selectDiscoverType(_ type: String) {
        SearchRepository.shared.selectDiscoverType(type: type)
    }

    func selectDiscoverCatalog(_ key: String) {
        SearchRepository.shared.selectDiscoverCatalog(catalogKey: key)
    }

    func selectDiscoverGenre(_ genre: String?) {
        SearchRepository.shared.selectDiscoverGenre(genre: genre)
    }

    /// Load-more sentinel: fire pagination as the grid approaches its end.
    func discoverItemAppeared(at index: Int) {
        guard let discover, discover.canLoadMore, !discover.isLoading else { return }
        if index >= discover.items.count - 8 {
            SearchRepository.shared.loadMoreDiscover()
        }
    }

    deinit {
        debounce?.cancel()
        addonWatcher?.cancel()
        searchWatcher?.cancel()
        discoverWatcher?.cancel()
        historyWatcher?.cancel()
        catalogSettingsWatcher?.cancel()
    }
}
