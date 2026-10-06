package com.nuvio.app.features.search

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.i18n.localizedMediaTypeLabel
import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonExtraProperty
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.firstEnabledManifestError
import com.nuvio.app.features.addons.hasPendingEnabledManifests
import com.nuvio.app.features.catalog.CATALOG_PAGE_SIZE
import com.nuvio.app.features.catalog.CatalogPage
import com.nuvio.app.features.catalog.CatalogTarget
import com.nuvio.app.features.catalog.buildCatalogUrl
import com.nuvio.app.features.catalog.fetchCatalogPage
import com.nuvio.app.features.catalog.mergeCatalogItems
import com.nuvio.app.features.catalog.nextCatalogPaginationState
import com.nuvio.app.features.catalog.supportsPagination
import com.nuvio.app.features.home.HomeCatalogSettingsRepository
import com.nuvio.app.features.home.HomeCatalogSection
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.filterReleasedItems
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

internal fun resolveDiscoverCatalog(
    sources: List<DiscoverCatalogOption>,
    preferredCatalogKey: String?,
    currentCatalogKey: String?,
): DiscoverCatalogOption? =
    sources.firstOrNull { it.key == preferredCatalogKey }
        ?: sources.firstOrNull { it.key == currentCatalogKey }
        ?: sources.firstOrNull()

object SearchRepository {
    private val log = Logger.withTag("SearchRepository")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("SearchRepository"))
    private val _uiState = MutableStateFlow(SearchUiState())
    val uiState: StateFlow<SearchUiState> = _uiState.asStateFlow()
    private val _discoverUiState = MutableStateFlow(DiscoverUiState())
    val discoverUiState: StateFlow<DiscoverUiState> = _discoverUiState.asStateFlow()

    private var activeJob: Job? = null
    private var activeDiscoverJob: Job? = null
    private var lastRequestKey: String? = null
    private var discoverSources: List<DiscoverCatalogOption> = emptyList()
    private var lastDiscoverHideUnreleasedContent: Boolean? = null
    /// Upstream 085e8dc6 / Codex r3: whether an enabled addon's manifest was still loading when the
    /// Discover feed was last prepared. Carried into loadDiscoverFeed's terminal publishes so an
    /// empty/failed page from an already-loaded addon doesn't become a terminal empty state while
    /// another addon may still bring catalogs; the previous value lets refreshDiscover notice the
    /// settle and re-run for an empty grid (see the reuse guard).
    private var discoverManifestsPending = false
    private var lastDiscoverHasPendingAddonManifests: Boolean? = null

    fun search(
        query: String,
        addons: List<ManagedAddon>,
        disabledCatalogKeys: Set<String> = emptySet(),
        forceRefresh: Boolean = false,
    ) {
        val normalizedQuery = query.trim()
        if (normalizedQuery.isBlank()) {
            clear()
            return
        }

        // Upstream 085e8dc6 (#1819): manifests still loading are not "no addons" — publish loading,
        // or the first manifest error, and only fall back to NoActiveAddons once everything settled.
        val enabledAddons = addons.enabledAddons()
        val hasPendingAddonManifests = enabledAddons.hasPendingEnabledManifests()
        val addonManifestErrorMessage = enabledAddons.firstEnabledManifestError()
        val activeAddons = enabledAddons.filter { it.manifest != null }
        if (activeAddons.isEmpty()) {
            activeJob?.cancel()
            lastRequestKey = null
            _uiState.value = SearchUiState(
                isLoading = hasPendingAddonManifests,
                emptyStateReason = when {
                    hasPendingAddonManifests -> null
                    addonManifestErrorMessage != null -> SearchEmptyStateReason.RequestFailed
                    else -> SearchEmptyStateReason.NoActiveAddons
                },
                errorMessage = addonManifestErrorMessage,
            )
            return
        }

        val requests = buildSearchRequests(
            addons = activeAddons,
            query = normalizedQuery,
            disabledCatalogKeys = disabledCatalogKeys,
        )
        // BUG-33 defect 1 instrumentation: same entries + disableCause pass buildSearchRequests
        // just ran (via logSearchSourceFilter), phrased for a human. Computed here so every
        // uiState below — including the early "no catalogs left" return — carries it.
        val fanOutLine = searchFanOutSummary(enumerateSearchCatalogs(activeAddons), disabledCatalogKeys)
        if (requests.isEmpty()) {
            activeJob?.cancel()
            lastRequestKey = null
            _uiState.value = SearchUiState(
                isLoading = hasPendingAddonManifests,
                emptyStateReason = if (hasPendingAddonManifests) null else SearchEmptyStateReason.NoSearchCatalogs,
                lastFanOut = fanOutLine,
            )
            return
        }

        val requestKey = buildString {
            append(normalizedQuery.lowercase())
            append('|')
            append(HomeCatalogSettingsRepository.snapshot().hideUnreleasedContent)
            append('|')
            // Upstream 085e8dc6: the final publish below can be "loading" purely because a manifest
            // is still pending; the flag must be part of the key or the same query re-issued after
            // that manifest fails is deduped by the same-key guard and the state never settles.
            append(hasPendingAddonManifests)
            append('|')
            append(
                requests.joinToString(separator = "|") { request ->
                    // BUG-33: request.key already disambiguates duplicate installs and twin
                    // catalogs, so identical fan-out sets collapse and different ones don't.
                    "${request.addon.manifestUrl}:${request.key}"
                },
            )
        }
        // Upstream (981b8bc7) also refetches a completed same-key search when not forced; tvOS
        // keeps the plain same-key reuse — search here only re-fires from the typing debounce on
        // screen re-entry, where a refetch would just flash-blank retained results.
        if (!forceRefresh && requestKey == lastRequestKey) return
        lastRequestKey = requestKey

        activeJob?.cancel()
        _uiState.value = SearchUiState(isLoading = true, lastFanOut = fanOutLine)

        activeJob = scope.launch {
            val resultChannel = Channel<IndexedSearchResult>(Channel.UNLIMITED)
            val jobs = requests.mapIndexed { index, request ->
                launch {
                    runCatching { request.toSection(forceRefresh = forceRefresh) }
                        .fold(
                            onSuccess = { section ->
                                resultChannel.trySend(
                                    IndexedSearchResult(
                                        index = index,
                                        section = section,
                                    ),
                                )
                            },
                            onFailure = { error ->
                                if (error is CancellationException) throw error
                                resultChannel.trySend(
                                    IndexedSearchResult(
                                        index = index,
                                        error = error,
                                    ),
                                )
                            },
                        )
                }
            }
            val closeChannelJob = launch {
                jobs.joinAll()
                resultChannel.close()
            }
            val results = arrayOfNulls<IndexedSearchResult>(requests.size)

            try {
                for (result in resultChannel) {
                    results[result.index] = result
                    val sections = results.orderedSections()
                    if (sections.isNotEmpty()) {
                        _uiState.value = SearchUiState(
                            isLoading = true,
                            sections = sections,
                            lastFanOut = fanOutLine,
                        )
                    }
                }
            } finally {
                closeChannelJob.cancel()
                resultChannel.close()
            }

            val completedResults = results.filterNotNull()
            val sections = results.orderedSections()
            val firstFailure = completedResults.firstNotNullOfOrNull { it.error?.message }
            val allFailed = completedResults.isNotEmpty() && completedResults.all { it.error != null }

            _uiState.value = SearchUiState(
                isLoading = sections.isEmpty() && hasPendingAddonManifests,
                sections = sections,
                emptyStateReason = when {
                    sections.isNotEmpty() -> null
                    hasPendingAddonManifests -> null
                    allFailed -> SearchEmptyStateReason.RequestFailed
                    else -> SearchEmptyStateReason.NoResults
                },
                errorMessage = if (allFailed) firstFailure else null,
                lastFanOut = fanOutLine,
            )
        }
    }

    fun clear() {
        activeJob?.cancel()
        lastRequestKey = null
        _uiState.value = SearchUiState()
    }

    fun reset() {
        activeJob?.cancel()
        activeDiscoverJob?.cancel()
        lastRequestKey = null
        discoverSources = emptyList()
        lastDiscoverHideUnreleasedContent = null
        discoverManifestsPending = false
        lastDiscoverHasPendingAddonManifests = null
        _uiState.value = SearchUiState()
        _discoverUiState.value = DiscoverUiState()
    }

    fun refreshDiscover(
        addons: List<ManagedAddon>,
        forceRefresh: Boolean = false,
    ) {
        // Upstream 085e8dc6 (#1819), same shape as search(): pending manifests → loading, a
        // manifest failure → RequestFailed + its message, NoActiveAddons only once settled.
        val enabledAddons = addons.enabledAddons()
        val hasPendingAddonManifests = enabledAddons.hasPendingEnabledManifests()
        val addonManifestErrorMessage = enabledAddons.firstEnabledManifestError()
        val activeAddons = enabledAddons.filter { it.manifest != null }
        if (activeAddons.isEmpty()) {
            activeDiscoverJob?.cancel()
            discoverSources = emptyList()
            lastDiscoverHideUnreleasedContent = null
            discoverManifestsPending = hasPendingAddonManifests
            lastDiscoverHasPendingAddonManifests = hasPendingAddonManifests
            log.d { "Discover refresh aborted: no active addons (pending=$hasPendingAddonManifests)" }
            _discoverUiState.value = DiscoverUiState(
                isLoading = hasPendingAddonManifests,
                emptyStateReason = when {
                    hasPendingAddonManifests -> null
                    addonManifestErrorMessage != null -> DiscoverEmptyStateReason.RequestFailed
                    else -> DiscoverEmptyStateReason.NoActiveAddons
                },
                errorMessage = addonManifestErrorMessage,
            )
            return
        }

        val sources = buildDiscoverSources(activeAddons)
        val current = _discoverUiState.value
        val hideUnreleasedContent = HomeCatalogSettingsRepository.snapshot().hideUnreleasedContent
        // Upstream (981b8bc7) drops canReuseDiscoverState and reuses only while a fetch is in
        // flight; tvOS keeps the completed-state reuse for non-forced calls because SearchViewModel
        // re-arms refreshDiscover on every screen re-entry — without it, each Search-tab visit
        // would blank and refetch the Discover grid.
        // Deviation from upstream 085e8dc6, which keys its whole DiscoverRequestKey on
        // hasPendingAddonManifests (so every settle blank-and-refetches, even a populated grid —
        // the exact thing this reuse exists to prevent). Here the settle only bypasses reuse when
        // the grid is EMPTY: that is the case where the feed was held in a pending "loading" state
        // (see loadDiscoverFeed) and now needs its real terminal state. The two pending
        // placeholders above/below are unreachable by this guard anyway (the empty branch nulls
        // lastDiscoverHideUnreleasedContent; the no-sources branch leaves selectedType null).
        val manifestsJustSettled = lastDiscoverHasPendingAddonManifests == true && !hasPendingAddonManifests
        lastDiscoverHasPendingAddonManifests = hasPendingAddonManifests
        discoverManifestsPending = hasPendingAddonManifests
        if (
            !forceRefresh &&
            !(manifestsJustSettled && current.items.isEmpty()) &&
            sources == discoverSources &&
            lastDiscoverHideUnreleasedContent == hideUnreleasedContent &&
            (current.canReuseDiscoverState(sources) || activeDiscoverJob?.isActive == true)
        ) {
            log.d {
                "Reusing discover state type=${current.selectedType} catalog=${current.selectedCatalogKey} " +
                    "genre=${current.selectedGenre ?: "<all>"} items=${current.items.size} nextSkip=${current.nextSkip}"
            }
            return
        }

        discoverSources = sources
        lastDiscoverHideUnreleasedContent = hideUnreleasedContent
        if (sources.isEmpty()) {
            activeDiscoverJob?.cancel()
            log.d { "Discover refresh found no compatible discover catalogs (pending=$hasPendingAddonManifests)" }
            _discoverUiState.value = DiscoverUiState(
                isLoading = hasPendingAddonManifests,
                emptyStateReason = if (hasPendingAddonManifests) null else DiscoverEmptyStateReason.NoDiscoverCatalogs,
            )
            return
        }

        val typeOptions = sources.map { it.type }.distinct()
        val preferredCatalogKey = DiscoverSelectionStorage.loadCatalogKey()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        // Upstream (ab57cf1b) resolves the catalog FIRST and derives the type from it, so a cold
        // start lands on the persisted catalog rather than on the first type's first catalog. The
        // reuse guard above means this only runs on cold start / after reset(). Upstream wraps the
        // resolve in requireNotNull (sources is non-empty by the early return); tvOS keeps the
        // pre-fix type logic as the null branch instead of throwing.
        val restoredCatalog = resolveDiscoverCatalog(
            sources = sources,
            preferredCatalogKey = preferredCatalogKey,
            currentCatalogKey = current.selectedCatalogKey,
        )
        val selectedType = restoredCatalog?.type
            ?: current.selectedType?.takeIf { type -> typeOptions.contains(type) }
            ?: typeOptions.first()
        val catalogOptions = sources.filter { it.type == selectedType }
        val selectedCatalog = restoredCatalog ?: catalogOptions.first()
        val selectedGenre = selectedCatalog.resolveGenreSelection(current.selectedGenre)

        _discoverUiState.value = DiscoverUiState(
            typeOptions = typeOptions,
            selectedType = selectedType,
            catalogOptions = catalogOptions,
            selectedCatalogKey = selectedCatalog.key,
            selectedGenre = selectedGenre,
            items = emptyList(),
            isLoading = false,
            nextSkip = null,
            emptyStateReason = null,
            errorMessage = null,
        )

        log.d {
            "Discover refresh prepared type=$selectedType catalog=${selectedCatalog.key} " +
                "genre=${selectedGenre ?: "<all>"} sources=${sources.size}"
        }

        loadDiscoverFeed(
            reset = true,
            forceRefresh = forceRefresh,
        )
    }

    fun selectDiscoverType(type: String) {
        val current = _discoverUiState.value
        if (current.selectedType == type) return

        val catalogOptions = discoverSources.filter { it.type == type }
        val selectedCatalog = catalogOptions.firstOrNull() ?: run {
            _discoverUiState.value = current.copy(
                selectedType = type,
                catalogOptions = emptyList(),
                selectedCatalogKey = null,
                selectedGenre = null,
                items = emptyList(),
                isLoading = false,
                nextSkip = null,
                emptyStateReason = DiscoverEmptyStateReason.NoDiscoverCatalogs,
                errorMessage = null,
            )
            return
        }

        _discoverUiState.value = current.copy(
            selectedType = type,
            catalogOptions = catalogOptions,
            selectedCatalogKey = selectedCatalog.key,
            selectedGenre = selectedCatalog.resolveGenreSelection(null),
            items = emptyList(),
            isLoading = false,
            nextSkip = null,
            emptyStateReason = null,
            errorMessage = null,
        )
        DiscoverSelectionStorage.saveCatalogKey(selectedCatalog.key)
        loadDiscoverFeed(reset = true)
    }

    fun selectDiscoverCatalog(catalogKey: String) {
        val current = _discoverUiState.value
        if (current.selectedCatalogKey == catalogKey) return

        val selectedCatalog = current.catalogOptions.firstOrNull { it.key == catalogKey } ?: return
        _discoverUiState.value = current.copy(
            selectedCatalogKey = selectedCatalog.key,
            selectedGenre = selectedCatalog.resolveGenreSelection(null),
            items = emptyList(),
            isLoading = false,
            nextSkip = null,
            emptyStateReason = null,
            errorMessage = null,
        )
        DiscoverSelectionStorage.saveCatalogKey(selectedCatalog.key)
        loadDiscoverFeed(reset = true)
    }

    fun selectDiscoverGenre(genre: String?) {
        val current = _discoverUiState.value
        val selectedCatalog = current.selectedCatalog ?: return
        val normalizedGenre = selectedCatalog.resolveGenreSelection(genre)
        if (current.selectedGenre == normalizedGenre) return

        _discoverUiState.value = current.copy(
            selectedGenre = normalizedGenre,
            items = emptyList(),
            isLoading = false,
            nextSkip = null,
            emptyStateReason = null,
            errorMessage = null,
        )
        loadDiscoverFeed(reset = true)
    }

    fun loadMoreDiscover() {
        val current = _discoverUiState.value
        if (current.isLoading || current.nextSkip == null) return
        loadDiscoverFeed(reset = false)
    }

    /// FEAT-10: every search-capable catalog across the enabled addons, in fan-out order —
    /// the option list behind the tvOS "Search Sources" settings. Key shape matches
    /// [DiscoverCatalogOption.key] (`manifestId:type:catalogId`) for the universal
    /// collision-free case, plus an identity-hash `#xxxxxxxx` suffix on EVERY member of a
    /// colliding group (see [enumerateSearchCatalogs]).
    fun searchCatalogOptions(addons: List<ManagedAddon>): List<SearchCatalogOption> =
        enumerateSearchCatalogs(addons.enabledAddons()).map { entry ->
            SearchCatalogOption(
                key = entry.key,
                addonName = entry.addon.displayTitle,
                catalogName = entry.catalog.name,
                type = entry.catalog.type,
                typeLabel = entry.catalog.type.displayLabel(),
            )
        }

    /// FEAT-10 / BUG-33: the ONE place that decides whether a stored disabled-key set switches a
    /// given catalog off. Both the fan-out filter ([buildSearchRequests]) and the diagnostics log
    /// go through here, and [isSearchSourceDisabled] re-exposes the same rule for UI layers.
    ///
    /// Two causes, checked in order:
    ///  * [SearchSourceDisableCause.StoredKey] — the entry's own (possibly suffixed) key is in
    ///    the set. This is what current UI writes produce, so per-member granularity is exact.
    ///  * [SearchSourceDisableCause.LegacyBaseKey] — the entry's BARE base key is in the set.
    ///    Keys persisted before the collision hardening are always bare, and pre-hardening they
    ///    disabled every colliding catalog at once. Honouring the bare key for every member of
    ///    the group reproduces that behaviour instead of silently re-enabling all but one
    ///    catalog on upgrade.
    private fun SearchCatalogEntry.disableCause(disabledCatalogKeys: Set<String>): SearchSourceDisableCause? =
        when {
            key in disabledCatalogKeys -> SearchSourceDisableCause.StoredKey
            baseKey in disabledCatalogKeys -> SearchSourceDisableCause.LegacyBaseKey
            else -> null
        }

    /// The [disableCause] rule, reachable from a key alone — for UI layers that hold a
    /// [SearchCatalogOption] and the persisted disabled set but not the enumeration.
    ///
    /// The tvOS Search Sources pane derives its toggle state from this call (not from a plain
    /// `disabledKeys.contains(option.key)`, which cannot see a LEGACY bare-key disable of a
    /// suffixed member: the search fan-out would skip the catalog while the row still read "On").
    ///
    /// Best-effort mirror, not the authority: it recovers the base key by parsing the suffix, so
    /// a catalog id that literally ends in `#<8 hex>` could be over-matched here. The fan-out
    /// filter never parses — it compares against the entry's real base key.
    fun isSearchSourceDisabled(optionKey: String, disabledCatalogKeys: Set<String>): Boolean {
        if (optionKey in disabledCatalogKeys) return true
        // ACCEPTED (Codex round-2 P3): pathological false display only. A real catalog id that
        // literally ends in `#<8 hex>` parses as a synthesized suffix here, so this mirror could
        // report the row as disabled when its (unrelated) "base" happens to be a stored key. It
        // is display-only — the fan-out filter compares against the entry's real baseKey and is
        // unaffected — and requires an addon author to mint an id in exactly the shape this
        // enumeration synthesizes. Not worth threading the enumeration into every UI layer.
        val base = optionKey.stripIdentitySuffix()
        return base != optionKey && base in disabledCatalogKeys
    }

    /// Codex round-2 finding N1: the WRITE side of [isSearchSourceDisabled]. Given one toggle
    /// action, returns the FULL disabled-key set to persist. Pure and Swift-callable — the
    /// settings pane owns the storage, this owns the key semantics, because only the enumeration
    /// knows which catalogs share a base key.
    ///
    /// Disabling is always "add the row's own key". Enabling is where the legacy semantics bite:
    /// a row can be off because a pre-hardening BARE base key sits in the set, and a bare key
    /// disables EVERY member of its collision group. Removing only the row's own (suffixed) key
    /// leaves that bare key in place, so [isSearchSourceDisabled] keeps reporting the row as
    /// disabled and the user can never switch it back on. Enabling such a member therefore
    /// MIGRATES the group: the bare key is dropped, and every OTHER member it was covering is
    /// re-persisted under its own suffixed key so their off state survives the migration
    /// unchanged. The toggled member's own key is deliberately not re-added — that is the point.
    ///
    /// Cases:
    ///  * disable → `current + optionKey`.
    ///  * enable with no legacy bare key in play — including a non-colliding catalog whose own
    ///    key IS the bare key — → plain `current - optionKey`, no migration.
    ///  * enable a group member covered by a bare key → `current - optionKey - baseKey +
    ///    {other group members' keys}`.
    ///  * enable an optionKey the enumeration no longer lists (a stale row racing an addon
    ///    change) → plain removal: group membership is unknowable, and guessing by parsing the
    ///    suffix could silently re-enable catalogs the user never touched.
    fun resolveSearchSourceToggle(
        optionKey: String,
        disabled: Boolean,
        currentDisabledKeys: Set<String>,
        addons: List<ManagedAddon>,
    ): Set<String> {
        if (disabled) return currentDisabledKeys + optionKey

        val next = currentDisabledKeys.toMutableSet()
        next.remove(optionKey)

        // The same enumeration the settings rows were minted from, so group membership here is
        // authoritative rather than parsed back out of the key string.
        val entries = enumerateSearchCatalogs(addons.enabledAddons())
        val entry = entries.firstOrNull { it.key == optionKey } ?: return next
        val baseKey = entry.baseKey
        // Own key == bare key (the non-colliding case): the removal above already cleared it and
        // there is no group to migrate.
        if (baseKey == optionKey || baseKey !in currentDisabledKeys) return next

        next.remove(baseKey)
        entries.forEach { other ->
            // `other.key != baseKey` is belt-and-braces: a group with 2+ members has every member
            // suffixed, so no sibling can carry the bare key we are retiring.
            if (other.baseKey == baseKey && other.key != optionKey && other.key != baseKey) {
                next.add(other.key)
            }
        }
        return next
    }

    // Internal (not private) so common tests can exercise the FEAT-10 filter without a network.
    internal fun buildSearchRequests(
        addons: List<ManagedAddon>,
        query: String,
        disabledCatalogKeys: Set<String> = emptySet(),
    ): List<SearchCatalogRequest> {
        val entries = enumerateSearchCatalogs(addons)
        logSearchSourceFilter(entries, disabledCatalogKeys)
        return entries
            // FEAT-10: sources the user switched off in Search Sources. Unknown keys in
            // the stored set (uninstalled addons, renamed catalogs) simply never match.
            .filter { entry -> entry.disableCause(disabledCatalogKeys) == null }
            .map { entry ->
                SearchCatalogRequest(
                    addon = entry.addon,
                    catalogId = entry.catalog.id,
                    catalogName = entry.catalog.name,
                    type = entry.catalog.type,
                    query = query,
                    supportsPagination = entry.catalog.supportsPagination(),
                    key = entry.key,
                )
            }
    }

    /// BUG-33 hardening: the single ordered enumeration of every search-capable catalog, and the
    /// ONLY place a search catalog key is minted. [searchCatalogOptions] (the settings pane) and
    /// [buildSearchRequests] (the fan-out filter) both go through here, so the two can never
    /// derive different keys for the same input ordering.
    ///
    /// `manifestId:type:catalogId` is not guaranteed unique — the same manifest.id can be
    /// installed twice under different URLs, and a single manifest may declare two catalogs with
    /// the same type+id. Colliding keys made one toggle silently govern several fan-out entries
    /// ("I select two catalogs but it searches all of them") and broke SwiftUI `ForEach` identity
    /// in the settings pane and in the results list.
    ///
    /// Disambiguation is IDENTITY-STABLE, not positional:
    ///  * A base key with no collision keeps the legacy format byte-for-byte — the universal
    ///    case, so persisted `search_disabled_catalog_keys` keep matching.
    ///  * EVERY member of a colliding group (including the first) gets `base#<h>`, where `<h>`
    ///    is [identityHash] of that member's OWN identity: its addon's manifestUrl plus the
    ///    catalog's index inside that manifest. Nothing about the other group members feeds the
    ///    hash, so uninstalling one addon never renumbers the survivors and their persisted
    ///    disablements keep matching (the earlier positional `#2`/`#3` scheme did renumber, and
    ///    silently re-enabled sources). The one accepted exception is benign: a group that
    ///    shrinks to a single member drops back to the bare base key.
    ///
    /// The trailing `.2`, `.3` loop is a pathological-case guard only: it covers a base key that
    /// literally ends in a synthesized suffix, and the degenerate case of the exact same
    /// manifestUrl installed twice (identical identities ⇒ identical hashes).
    private fun enumerateSearchCatalogs(addons: List<ManagedAddon>): List<SearchCatalogEntry> {
        val entries = addons.mapNotNull { addon ->
            val manifest = addon.manifest ?: return@mapNotNull null
            addon to manifest
        }.flatMap { (addon, manifest) ->
            manifest.catalogs.mapIndexedNotNull { catalogIndex, catalog ->
                if (!catalog.supportsSearch()) return@mapIndexedNotNull null
                SearchCatalogEntry(
                    addon = addon,
                    catalog = catalog,
                    baseKey = searchCatalogKey(manifest.id, catalog),
                    // Identity = this catalog's own coordinates. The index is taken over the FULL
                    // manifest catalog list so that a catalog gaining/losing `search` support
                    // elsewhere in the manifest cannot shift it.
                    identityHash = identityHash(addon.manifestUrl, catalogIndex),
                )
            }
        }

        val collisionCounts = entries.groupingBy { entry -> entry.baseKey }.eachCount()
        val usedKeys = mutableSetOf<String>()
        return entries.map { entry ->
            val preferred = if (collisionCounts[entry.baseKey] == 1) {
                entry.baseKey
            } else {
                "${entry.baseKey}#${entry.identityHash}"
            }
            var key = preferred
            var tiebreak = 1
            // ACCEPTED (Codex round-2 P3): this loop is not identity-stable. If two members of ONE
            // collision group ever produced the same 32-bit FNV digest, the `.2` suffix would be
            // handed out by encounter order, so uninstalling one addon could renumber the other —
            // exactly the silent re-enable the identity hash exists to avoid. It needs a digest
            // collision between two catalogs sharing a base key (a handful of members, not the
            // birthday bound over all keys), i.e. ~2^-32 per pair — astronomically unlikely, and
            // the only alternatives (wider digest, positional fallback) cost key-format stability
            // for every user to fix a case no install will hit.
            while (!usedKeys.add(key)) {
                tiebreak += 1
                key = "$preferred.$tiebreak"
            }
            if (key == entry.key) entry else entry.copy(key = key)
        }
    }

    /// BUG-33 defect 1: the ONE classification pass behind both [logSearchSourceFilter] (device
    /// log) and [searchFanOutSummary] (the in-app Settings caption) — pairs every entry with its
    /// [SearchCatalogEntry.disableCause] so the two surfaces can never disagree about which
    /// catalogs a search actually hit.
    private fun classifySearchFanOut(
        entries: List<SearchCatalogEntry>,
        disabledCatalogKeys: Set<String>,
    ): List<Pair<SearchCatalogEntry, SearchSourceDisableCause?>> =
        entries.map { entry -> entry to entry.disableCause(disabledCatalogKeys) }

    /// BUG-33 diagnostics: one line per search whenever the user has disabled at least one
    /// source, so a device log immediately shows requested-vs-filtered without a rebuild.
    /// FILTERED entries carry their match cause (`stored` = the entry's own key, `legacy` = the
    /// bare base key covering a whole collision group).
    ///
    /// BUG-33 defect 1 (re-opened twice): this shipped at `log.d`, and Kermit routes debug/info
    /// lines to os_log's default (non-persisted) tier — invisible in a plain `log show` / Console
    /// capture (see BUG-11). `log.w` is the lowest level that survives a default capture, and this
    /// only fires when the user has ≥1 disabled source, so it stays quiet for everyone else.
    private fun logSearchSourceFilter(
        entries: List<SearchCatalogEntry>,
        disabledCatalogKeys: Set<String>,
    ) {
        if (disabledCatalogKeys.isEmpty()) return
        log.w {
            val disabled = disabledCatalogKeys.sorted().joinToString(separator = ", ", prefix = "[", postfix = "]")
            val statuses = classifySearchFanOut(entries, disabledCatalogKeys).joinToString(separator = ", ", prefix = "[", postfix = "]") { (entry, cause) ->
                val status = when (cause) {
                    SearchSourceDisableCause.StoredKey -> "FILTERED(stored)"
                    SearchSourceDisableCause.LegacyBaseKey -> "FILTERED(legacy:${entry.baseKey})"
                    null -> "kept"
                }
                "${entry.key}=$status"
            }
            "[SearchSources] disabled=${disabledCatalogKeys.size}$disabled catalogs=${entries.size} $statuses"
        }
    }

    /// BUG-33 defect 1 instrumentation: the tester-visible counterpart to
    /// [logSearchSourceFilter] — same [classifySearchFanOut] pass, phrased in addon + catalog
    /// display names (never keys) so Settings → Content Sources → Search Sources can show
    /// exactly which catalogs the last search hit. Example:
    /// `"searched 3 of 7 catalogs · filtered: TMDB Popular-Films, TMDB Popular-Séries, +1 more"`.
    ///
    /// Plain English, not routed through [resourceString]/[StringKey]: this phrase has no
    /// existing key, and minting one needs three things this task can't safely do without a
    /// build to verify — a new [StringKey] enum case, its `ComposeResourcesStringProvider`
    /// mapping (an exhaustive `when`), and the bundled Compose Resources string itself. tvOS
    /// also never installs a [StringProvider] at all, so [resourceString] always resolves to
    /// the English fallback there regardless.
    private fun searchFanOutSummary(
        entries: List<SearchCatalogEntry>,
        disabledCatalogKeys: Set<String>,
    ): String {
        val classified = classifySearchFanOut(entries, disabledCatalogKeys)
        val keptCount = classified.count { (_, cause) -> cause == null }
        val filteredNames = classified.mapNotNull { (entry, cause) ->
            if (cause == null) return@mapNotNull null
            "${entry.addon.displayTitle} ${entry.catalog.name}-${entry.catalog.type.displayLabel()}"
        }

        val catalogWord = if (entries.size == 1) "catalog" else "catalogs"
        return buildString {
            append("searched $keptCount of ${entries.size} $catalogWord")
            if (filteredNames.isNotEmpty()) {
                append(" · filtered: ")
                val shown = filteredNames.take(4)
                append(shown.joinToString(", "))
                val remaining = filteredNames.size - shown.size
                if (remaining > 0) append(", +$remaining more")
            }
        }
    }

    private fun searchCatalogKey(manifestId: String, catalog: AddonCatalog): String =
        searchCatalogKey(manifestId, catalog.type, catalog.id)

    private fun searchCatalogKey(manifestId: String, type: String, catalogId: String): String =
        "$manifestId:$type:$catalogId"

    private fun buildDiscoverSources(addons: List<ManagedAddon>): List<DiscoverCatalogOption> =
        addons.mapNotNull { addon ->
            val manifest = addon.manifest ?: return@mapNotNull null
            addon to manifest
        }.flatMap { (addon, manifest) ->
            manifest.catalogs
                .filter { catalog -> catalog.supportsDiscover() }
                .map { catalog ->
                    val genreExtra = catalog.genreExtra()
                    DiscoverCatalogOption(
                        key = "${manifest.id}:${catalog.type}:${catalog.id}",
                        addonName = addon.displayTitle,
                        manifestUrl = addon.manifestUrl,
                        type = catalog.type,
                        catalogId = catalog.id,
                        catalogName = catalog.name,
                        genreOptions = genreExtra?.options.orEmpty(),
                        genreRequired = genreExtra?.isRequired == true,
                        supportsPagination = catalog.supportsPagination(),
                    )
                }
        }

    private suspend fun SearchCatalogRequest.toSection(forceRefresh: Boolean): HomeCatalogSection {
        val manifest = requireNotNull(addon.manifest)
        val page = fetchCatalogPage(
            manifestUrl = manifest.transportUrl,
            type = type,
            catalogId = catalogId,
            search = query,
            forceRefresh = forceRefresh,
        ).withUnreleasedFilter()
        val items = page.items
        require(items.isNotEmpty()) {
            resourceString("No search results returned for $catalogName.", StringKey.search_error_no_results_for_catalog, catalogName)
        }

        return HomeCatalogSection(
            key = sectionKey(),
            title = resourceString("$catalogName • ${type.displayLabel()}", StringKey.discover_catalog_context, catalogName, type.displayLabel()),
            subtitle = addon.displayTitle,
            addonName = addon.displayTitle,
            target = toCatalogTarget(manifestTransportUrl = manifest.transportUrl),
            items = items,
            availableItemCount = page.rawItemCount,
            hasMore = supportsPagination && page.nextSkip != null,
        )
    }

    private fun loadDiscoverFeed(
        reset: Boolean,
        forceRefresh: Boolean = false,
    ) {
        activeDiscoverJob?.cancel()
        val current = _discoverUiState.value
        val selectedCatalog = current.selectedCatalog ?: return
        val requestedSkip = if (reset) 0 else current.nextSkip ?: return
        val requestUrl = buildCatalogUrl(
            manifestUrl = selectedCatalog.manifestUrl,
            type = selectedCatalog.type,
            catalogId = selectedCatalog.catalogId,
            genre = current.selectedGenre,
            search = null,
            skip = requestedSkip.takeIf { it > 0 },
        )

        log.d {
            "Discover request reset=$reset addon=${selectedCatalog.addonName} type=${selectedCatalog.type} " +
                "catalogId=${selectedCatalog.catalogId} catalogKey=${selectedCatalog.key} " +
                "genre=${current.selectedGenre ?: "<all>"} skip=$requestedSkip url=$requestUrl"
        }

        _discoverUiState.value = current.copy(
            isLoading = true,
            items = if (reset) emptyList() else current.items,
            nextSkip = if (reset) null else current.nextSkip,
            consecutiveDuplicatePages = if (reset) 0 else current.consecutiveDuplicatePages,
            emptyStateReason = null,
            errorMessage = null,
        )

        activeDiscoverJob = scope.launch {
            runCatching {
                fetchCatalogPage(
                    manifestUrl = selectedCatalog.manifestUrl,
                    type = selectedCatalog.type,
                    catalogId = selectedCatalog.catalogId,
                    genre = current.selectedGenre,
                    skip = requestedSkip.takeIf { it > 0 },
                    forceRefresh = forceRefresh,
                ).withUnreleasedFilter()
            }.fold(
                onSuccess = { page ->
                    val latest = _discoverUiState.value
                    if (latest.selectedCatalogKey != selectedCatalog.key || latest.selectedGenre != current.selectedGenre) {
                        return@fold
                    }
                    val mergedItems = if (reset) {
                        page.items
                    } else {
                        mergeCatalogItems(latest.items, page.items)
                    }
                    val supportsPagination = selectedCatalog.supportsPagination || page.rawItemCount >= CATALOG_PAGE_SIZE
                    val loadedNewItems = reset || mergedItems.size > latest.items.size
                    val paginationState = nextCatalogPaginationState(
                        supportsPagination = supportsPagination,
                        requestedSkip = requestedSkip,
                        page = page,
                        loadedNewItems = loadedNewItems,
                        consecutiveDuplicatePages = if (reset) 0 else latest.consecutiveDuplicatePages,
                    )
                    log.d {
                        "Discover response catalogKey=${selectedCatalog.key} returned=${page.items.size} " +
                            "merged=${mergedItems.size} rawItemCount=${page.rawItemCount} nextSkip=${page.nextSkip} " +
                            "sample=${page.items.previewNames()}"
                    }
                    // Codex r3: an empty page is not terminal while another addon's manifest may
                    // still bring catalogs — hold "loading"; refreshDiscover re-runs on settle.
                    val holdForManifests = mergedItems.isEmpty() && discoverManifestsPending
                    _discoverUiState.value = latest.copy(
                        items = mergedItems,
                        isLoading = holdForManifests,
                        nextSkip = paginationState.nextSkip,
                        consecutiveDuplicatePages = paginationState.consecutiveDuplicatePages,
                        emptyStateReason = if (mergedItems.isEmpty() && !holdForManifests) DiscoverEmptyStateReason.NoResults else null,
                        errorMessage = null,
                    )
                },
                onFailure = { error ->
                    if (error is CancellationException) {
                        log.d {
                            "Discover request cancelled catalogKey=${selectedCatalog.key} addon=${selectedCatalog.addonName} " +
                                "type=${selectedCatalog.type} catalogId=${selectedCatalog.catalogId} " +
                                "genre=${current.selectedGenre ?: "<all>"} skip=$requestedSkip"
                        }
                        return@fold
                    }

                    val latest = _discoverUiState.value
                    if (latest.selectedCatalogKey != selectedCatalog.key || latest.selectedGenre != current.selectedGenre) {
                        return@fold
                    }
                    log.e(error) {
                        "Discover request failed catalogKey=${selectedCatalog.key} addon=${selectedCatalog.addonName} " +
                            "type=${selectedCatalog.type} catalogId=${selectedCatalog.catalogId} " +
                            "genre=${current.selectedGenre ?: "<all>"} skip=$requestedSkip url=$requestUrl"
                    }
                    val remainingItems = if (reset) emptyList() else latest.items
                    val holdForManifests = remainingItems.isEmpty() && discoverManifestsPending
                    _discoverUiState.value = latest.copy(
                        items = remainingItems,
                        isLoading = holdForManifests,
                        nextSkip = null,
                        emptyStateReason = if (holdForManifests) null else DiscoverEmptyStateReason.RequestFailed,
                        errorMessage = if (holdForManifests) null else error.message ?: resourceString("The selected catalog failed to return discover items.", StringKey.discover_empty_load_failed_message),
                    )
                },
            )
        }
    }
}

private data class IndexedSearchResult(
    val index: Int,
    val section: HomeCatalogSection? = null,
    val error: Throwable? = null,
)

private fun Array<IndexedSearchResult?>.orderedSections(): List<HomeCatalogSection> =
    mapNotNull { result -> result?.section }

private fun CatalogPage.withUnreleasedFilter(): CatalogPage {
    if (!HomeCatalogSettingsRepository.snapshot().hideUnreleasedContent) return this
    val filteredItems = items.filterReleasedItems(CurrentDateProvider.todayIsoDate())
    return if (filteredItems.size == items.size) this else copy(items = filteredItems)
}

/// One search-capable catalog paired with its collision-free key. Internal to the enumeration —
/// nothing crosses the Swift boundary (see [SearchCatalogOption], whose fields are unchanged).
///
/// [baseKey] is the legacy `manifestId:type:catalogId` form; [key] equals it unless the base
/// collides, in which case it is `baseKey#identityHash`.
private data class SearchCatalogEntry(
    val addon: ManagedAddon,
    val catalog: AddonCatalog,
    val baseKey: String,
    val identityHash: String,
    val key: String = baseKey,
)

/// Why a catalog counts as disabled — see `SearchRepository.disableCause`.
private enum class SearchSourceDisableCause {
    /// The entry's own (possibly suffixed) key is in the stored set.
    StoredKey,

    /// The entry's bare base key is in the stored set: a pre-hardening persisted key, which
    /// disables every member of the collision group exactly as it used to.
    LegacyBaseKey,
}

internal data class SearchCatalogRequest(
    val addon: ManagedAddon,
    val catalogId: String,
    val catalogName: String,
    val type: String,
    val query: String,
    val supportsPagination: Boolean,
    /// BUG-33: the disambiguated enumeration key this request came from. Kotlin-internal (no
    /// Swift exposure) — it exists so the results section key can stay unique per install.
    val key: String,
)

/// BUG-48 (beta.12): the See All target for a search-result section. The section was built FROM
/// this request's query, so the target must carry the SAME query — building it without one (the
/// old inline construction) made the pushed grid fetch the addon's unfiltered catalog: empty for
/// search-only catalogs (the grid behind BUG-47's eject), silently wrong titles for browsable
/// ones. Internal + pure so common tests can pin the threading without a network round-trip.
internal fun SearchCatalogRequest.toCatalogTarget(manifestTransportUrl: String): CatalogTarget.Addon =
    CatalogTarget.Addon(
        manifestUrl = manifestTransportUrl,
        contentType = type,
        catalogId = catalogId,
        search = query,
        supportsPagination = supportsPagination,
    )

/// BUG-33: the results list is `ForEach(model.sections, id: \.key)` (SearchView.swift), so two
/// duplicate installs of the same catalog must not produce the same section key or the rails
/// collapse into one identity. The request carries the enumeration's disambiguated key, and its
/// suffix (empty for the collision-free case) is spliced in right after the catalog id — so
/// non-colliding catalogs keep the legacy section-key format byte-for-byte.
///
/// Internal so common tests can assert uniqueness without a network round-trip.
internal fun SearchCatalogRequest.sectionKey(): String {
    val manifestId = addon.manifest?.id.orEmpty()
    val baseKey = "$manifestId:$type:$catalogId"
    val disambiguator = key.removePrefix(baseKey).takeIf { it != key }.orEmpty()
    return "$manifestId:search:$type:$catalogId$disambiguator:${query.lowercase()}"
}

private val FNV32_OFFSET_BASIS: UInt = 2166136261u
private val FNV32_PRIME: UInt = 16777619u

/// 32-bit FNV-1a over UTF-16 code units, big-endian per unit. Explicit and platform-independent
/// by construction: no `String.hashCode`, no randomness, no clock — identical on JVM/Native/JS
/// for identical input, which is what makes the persisted keys portable and stable.
private fun fnv1a32(value: String): UInt {
    var hash = FNV32_OFFSET_BASIS
    for (char in value) {
        val code = char.code
        hash = (hash xor ((code shr 8) and 0xFF).toUInt()) * FNV32_PRIME
        hash = (hash xor (code and 0xFF).toUInt()) * FNV32_PRIME
    }
    return hash
}

/// The stable per-catalog identity digest used to disambiguate colliding base keys. Derived
/// ONLY from the catalog's own coordinates — the installing addon's manifestUrl (the thing that
/// actually distinguishes two installs of the same manifest.id) and the catalog's index inside
/// that manifest (the thing that distinguishes two same-type+id catalogs in one manifest).
/// A space separates the two fields (a manifest URL never contains one), so a URL ending in
/// digits cannot alias a different index. Rendered as 8 lowercase hex digits.
private fun identityHash(manifestUrl: String, catalogIndex: Int): String =
    fnv1a32("$manifestUrl $catalogIndex").toString(16).padStart(8, '0')

/// Inverse of the suffix minting in `enumerateSearchCatalogs`: recovers the bare base key from a
/// possibly-suffixed one. Only strips a suffix that matches the synthesized shape
/// (`#` + 8 hex digits, optionally `.` + tiebreak digits), so a catalog id containing a literal
/// `#` is left alone.
private fun String.stripIdentitySuffix(): String {
    val hashIndex = lastIndexOf('#')
    if (hashIndex <= 0) return this
    var suffix = substring(hashIndex + 1)
    val dotIndex = suffix.indexOf('.')
    if (dotIndex >= 0) {
        val tiebreak = suffix.substring(dotIndex + 1)
        if (tiebreak.isEmpty() || tiebreak.any { !it.isDigit() }) return this
        suffix = suffix.substring(0, dotIndex)
    }
    if (suffix.length != 8 || suffix.any { char -> char !in '0'..'9' && char !in 'a'..'f' }) return this
    return substring(0, hashIndex)
}

private fun AddonCatalog.supportsSearch(): Boolean =
    extra.any { property -> property.name == "search" } &&
        extra.none { property -> property.isRequired && property.name != "search" }

private fun AddonCatalog.supportsDiscover(): Boolean {
    if (extra.any { property -> property.name == "search" && property.isRequired }) {
        return false
    }

    return extra.none { property ->
        when (property.name) {
            "genre" -> property.isRequired && property.options.isEmpty()
            "skip" -> false
            "search" -> false
            else -> property.isRequired
        }
    }
}

private fun AddonCatalog.genreExtra(): AddonExtraProperty? =
    extra.firstOrNull { property -> property.name == "genre" }

private fun DiscoverCatalogOption.resolveGenreSelection(requestedGenre: String?): String? =
    when {
        genreOptions.isEmpty() -> null
        requestedGenre != null && genreOptions.contains(requestedGenre) -> requestedGenre
        genreRequired -> genreOptions.firstOrNull()
        else -> null
    }

private fun DiscoverUiState.canReuseDiscoverState(
    sources: List<DiscoverCatalogOption>,
): Boolean {
    val currentType = selectedType ?: return false
    if (!typeOptions.contains(currentType) || !sources.any { it.type == currentType }) {
        return false
    }

    val currentCatalog = sources.firstOrNull { it.key == selectedCatalogKey } ?: return false
    if (currentCatalog.type != currentType) {
        return false
    }

    val resolvedGenre = currentCatalog.resolveGenreSelection(selectedGenre)
    if (selectedGenre != resolvedGenre) {
        return false
    }

    return isLoading || items.isNotEmpty() || emptyStateReason != null || errorMessage != null || nextSkip != null
}

private fun List<MetaPreview>.previewNames(limit: Int = 5): String {
    if (isEmpty()) return "[]"
    return take(limit).joinToString(prefix = "[", postfix = if (size > limit) ", ...]" else "]") { item ->
        item.name
    }
}

private fun String.displayLabel(): String =
    localizedMediaTypeLabel(this)

private fun String.typeSortKey(): String =
    when (lowercase()) {
        "movie" -> "0_movie"
        "series" -> "1_series"
        "anime" -> "2_anime"
        else -> "9_$this"
    }
