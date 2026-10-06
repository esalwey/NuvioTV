package com.nuvio.app.features.collection

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.catalog.CATALOG_PAGE_SIZE
import com.nuvio.app.features.catalog.CatalogPage
import com.nuvio.app.features.catalog.CatalogTarget
import com.nuvio.app.features.catalog.fetchCatalogPage
import com.nuvio.app.features.catalog.mergeCatalogItems
import com.nuvio.app.features.catalog.nextCatalogPaginationState
import com.nuvio.app.features.catalog.supportsPagination
import com.nuvio.app.core.i18n.localizedMediaTypeLabel
import com.nuvio.app.features.home.HomeCatalogSettingsRepository
import com.nuvio.app.features.home.HomeCatalogSection
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.filterReleasedItems
import com.nuvio.app.features.home.stableKey
import com.nuvio.app.features.trakt.TraktPublicListSourceResolver
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

data class FolderTab(
    val label: String,
    val typeLabel: String = "",
    val source: CollectionSource? = null,
    val sourceKey: String? = null,
    val manifestUrl: String? = null,
    val type: String = "",
    val catalogId: String = "",
    val genre: String? = null,
    val supportsPagination: Boolean = false,
    val items: List<MetaPreview> = emptyList(),
    val isLoading: Boolean = true,
    val isLoadingMore: Boolean = false,
    val nextSkip: Int? = null,
    val consecutiveDuplicatePages: Int = 0,
    val error: String? = null,
    val isAllTab: Boolean = false,
) {
    val canLoadMore: Boolean
        get() = supportsPagination && nextSkip != null
}

data class FolderDetailUiState(
    val folder: CollectionFolder? = null,
    val collectionTitle: String = "",
    val viewMode: FolderViewMode = FolderViewMode.TABBED_GRID,
    val tabs: List<FolderTab> = emptyList(),
    val selectedTabIndex: Int = 0,
    val isLoading: Boolean = true,
    val showAllTab: Boolean = true,
) {
    val selectedTab: FolderTab?
        get() = tabs.getOrNull(selectedTabIndex)

    val selectedTabCanLoadMore: Boolean
        get() {
            val currentTab = selectedTab ?: return false
            return if (currentTab.isAllTab) {
                tabs.any { !it.isAllTab && it.canLoadMore }
            } else {
                currentTab.canLoadMore
            }
        }

    val selectedTabIsLoadingMore: Boolean
        get() {
            val currentTab = selectedTab ?: return false
            return if (currentTab.isAllTab) {
                tabs.any { !it.isAllTab && it.isLoadingMore }
            } else {
                currentTab.isLoadingMore
            }
        }
}

object FolderDetailRepository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("FolderDetailRepository"))
    private val log = Logger.withTag("FolderDetailRepository")

    private val _uiState = MutableStateFlow(FolderDetailUiState())
    val uiState: StateFlow<FolderDetailUiState> = _uiState.asStateFlow()

    private val loadJobs = mutableMapOf<Int, Job>()

    /// UX-14 (Codex gate 2, round 8): [loadJobs] is mutated from callers on the main thread
    /// ([detach]/[clear]/[initialize]) and read from completion blocks on Dispatchers.Default —
    /// and the ownership check + publication must be ATOMIC against a concurrent replacement, or
    /// a cancelled job can pass the check and still publish stale (even cross-profile) state.
    /// Every [loadJobs] access, and every publication guarded by it, holds this lock.
    private val loadJobsLock = kotlinx.atomicfu.locks.SynchronizedObject()

    private var activeCollectionId: String? = null
    private var activeFolderId: String? = null

    /// UX-14 (Codex gate 2, rounds 2–6): EXACTLY the inputs [initialize] derives tab structure
    /// from, captured when state was built. The early-return reuses retained state only while the
    /// live inputs still compare equal — so a real edit/sync/addon change re-initializes, while
    /// anything the screen does NOT read (sibling folders, a startup refresh flipping an addon's
    /// `isRefreshing`, addon rename) must NOT discard the retained scroll position this feature
    /// exists to preserve. Per addon only `manifestUrl`/`enabled`/`manifest` matter (the source
    /// resolver may consult ANY addon's manifest catalogs, so the list isn't narrowed to the
    /// folder's own addons). `viewMode` is deliberately absent: tvOS renders every mode as the
    /// tabbed grid (v1 simplification, see FolderDetailView).
    private data class RetainedInputs(
        val folder: CollectionFolder,
        val collectionTitle: String,
        val showAllTab: Boolean,
        val addonCatalogInputs: List<Triple<String, Boolean, AddonManifest?>>,
        /// Round 7: loadTabPage filters every page through this setting, so retained ITEMS are a
        /// function of it too — flipping it between visits must refetch.
        val hideUnreleasedContent: Boolean,
    )

    private var activeInputsSnapshot: RetainedInputs? = null

    private fun retainedInputs(collection: Collection, folder: CollectionFolder): RetainedInputs =
        RetainedInputs(
            folder = folder,
            collectionTitle = collection.title,
            showAllTab = collection.showAllTab,
            addonCatalogInputs = AddonRepository.uiState.value.addons.map {
                Triple(it.manifestUrl, it.enabled, it.manifest)
            },
            hideUnreleasedContent = HomeCatalogSettingsRepository.snapshot().hideUnreleasedContent,
        )

    private fun liveRetainedInputs(collectionId: String, folderId: String): RetainedInputs? {
        val collection = CollectionRepository.getCollection(collectionId) ?: return null
        val folder = collection.folders.find { it.id == folderId } ?: return null
        return retainedInputs(collection, folder)
    }

    fun initialize(collectionId: String, folderId: String) {
        val current = _uiState.value
        if (
            activeCollectionId == collectionId &&
            activeFolderId == folderId &&
            current.folder?.id == folderId &&
            current.tabs.isNotEmpty() &&
            // UX-14 (Codex gate 2): with [detach] replacing [clear] on tvOS screen covers, this
            // early-return is also what a GENUINE re-entry hits — so the live derivation inputs
            // must still equal the snapshot state was built from (see [RetainedInputs] for what
            // counts and what deliberately doesn't). Any relevant edit/sync/addon change falls
            // through to a full re-init; item staleness on re-entry is the same accepted trade
            // UX-13 made for catalog grids.
            activeInputsSnapshot != null &&
            liveRetainedInputs(collectionId, folderId) == activeInputsSnapshot
        ) {
            // UX-14: a pop-back re-initialize after [detach]. Any tab whose load was in flight
            // when the screen was covered still SAYS it's loading, but its job was cancelled —
            // without this it would spin forever with no retry path.
            resumeInterruptedTabLoads()
            return
        }

        clear()
        activeCollectionId = collectionId
        activeFolderId = folderId

        val collection = CollectionRepository.getCollection(collectionId)
        if (collection == null) {
            _uiState.value = FolderDetailUiState(isLoading = false)
            return
        }

        val folder = collection.folders.find { it.id == folderId }
        if (folder == null) {
            _uiState.value = FolderDetailUiState(isLoading = false)
            return
        }
        activeInputsSnapshot = retainedInputs(collection, folder)

        val sources = folder.resolvedSources
        val showAll = collection.showAllTab && sources.size > 1
        val addons = AddonRepository.uiState.value.addons

        val tabs = buildList {
            if (showAll) {
                add(
                    FolderTab(
                        label = resourceString("All", StringKey.collections_tab_all),
                        isAllTab = true,
                        isLoading = true,
                    ),
                )
            }
            sources.forEachIndexed { sourceIndex, source ->
                if (source.isTmdb) {
                    val mediaType = TmdbCollectionMediaType.fromString(source.mediaType)
                    val type = if (mediaType == TmdbCollectionMediaType.TV) "series" else "movie"
                    add(
                        FolderTab(
                            label = source.title?.takeIf { it.isNotBlank() } ?: "TMDB",
                            typeLabel = "TMDB",
                            source = source,
                            sourceKey = source.catalogRouteKey(),
                            type = type,
                            catalogId = tmdbCatalogId(source),
                            supportsPagination = source.tmdbSourceType !in setOf(
                                TmdbCollectionSourceType.COLLECTION.name,
                                TmdbCollectionSourceType.PERSON.name,
                                TmdbCollectionSourceType.DIRECTOR.name,
                            ),
                            isLoading = true,
                        ),
                    )
                } else if (source.isTrakt) {
                    val mediaType = TmdbCollectionMediaType.fromString(source.mediaType)
                    val type = if (mediaType == TmdbCollectionMediaType.TV) "series" else "movie"
                    val typeLabel = if (mediaType == TmdbCollectionMediaType.TV) {
                        resourceString("Trakt Series List", StringKey.collections_folder_trakt_series_list)
                    } else {
                        resourceString("Trakt Movie List", StringKey.collections_folder_trakt_movie_list)
                    }
                    add(
                        FolderTab(
                            label = source.title?.takeIf { it.isNotBlank() } ?: "Trakt",
                            typeLabel = typeLabel,
                            source = source,
                            sourceKey = source.catalogRouteKey(),
                            type = type,
                            catalogId = traktCatalogId(source),
                            supportsPagination = true,
                            isLoading = true,
                        ),
                    )
                } else {
                    val catalogSource = source.addonCatalogSource() ?: return@forEachIndexed
                    val resolvedCatalog = addons.findCollectionCatalog(catalogSource)
                    val addon = resolvedCatalog?.addon
                    val catalog = resolvedCatalog?.catalog
                    val label = catalog?.name ?: catalogSource.catalogId
                    val typeLabel = localizedMediaTypeLabel(catalogSource.type)
                    val genreSuffix = if (catalogSource.genre != null) " · ${catalogSource.genre}" else ""
                    add(
                        FolderTab(
                            label = "$label ($typeLabel)$genreSuffix",
                            typeLabel = typeLabel,
                            source = source,
                            sourceKey = source.catalogRouteKey(),
                            manifestUrl = addon?.manifestUrl,
                            type = catalogSource.type,
                            catalogId = catalogSource.catalogId,
                            genre = catalogSource.genre,
                            supportsPagination = catalog?.supportsPagination() == true,
                            isLoading = true,
                        ),
                    )
                }
            }
        }

        _uiState.value = FolderDetailUiState(
            folder = folder,
            collectionTitle = collection.title,
            viewMode = collection.folderViewMode,
            tabs = tabs,
            selectedTabIndex = 0,
            isLoading = true,
            showAllTab = showAll,
        )

        // Load catalog data for each source
        sources.forEachIndexed { sourceIndex, source ->
            val tabIndex = if (showAll) sourceIndex + 1 else sourceIndex
            val catalogSource = source.addonCatalogSource()
            val resolvedCatalog = catalogSource?.let { addons.findCollectionCatalog(it) }
            if (!source.isTmdb && !source.isTrakt && resolvedCatalog == null) {
                updateTab(tabIndex) {
                    it.copy(
                        isLoading = false,
                        error = resourceString("Addon not found: ${catalogSource?.addonId.orEmpty()}", StringKey.collections_folder_addon_not_found, catalogSource?.addonId.orEmpty()),
                    )
                }
                return@forEachIndexed
            }

            loadTabPage(tabIndex, reset = true)
        }

        // If no sources, mark as done
        if (sources.isEmpty()) {
            _uiState.value = _uiState.value.copy(isLoading = false)
        }
    }

    fun selectTab(index: Int) {
        _uiState.value = _uiState.value.copy(selectedTabIndex = index)
    }

    fun clear() {
        kotlinx.atomicfu.locks.synchronized(loadJobsLock) {
            loadJobs.values.forEach { it.cancel() }
            loadJobs.clear()
        }
        activeCollectionId = null
        activeFolderId = null
        activeInputsSnapshot = null
        _uiState.value = FolderDetailUiState()
    }

    /// UX-14 (beta.12): cancel in-flight work but KEEP the loaded state and active keys — the
    /// pop-friendly sibling of [clear], mirroring `CatalogRepository.detach()`'s UX-13 contract.
    /// tvOS calls this from `FolderDetailView`'s `onDisappear`, which also fires when a pushed
    /// title screen merely COVERS the folder grid; with [clear] there, popping back re-ran
    /// [initialize] from scratch and rebuilt the grid at the top. Keeping state lets
    /// [initialize]'s same-key early-return preserve the items — and therefore the lazy grid's
    /// scroll position — when the user backs out of a title. A real exit path that must wipe
    /// (sign-out, mobile's route pop) stays on [clear].
    fun detach() {
        kotlinx.atomicfu.locks.synchronized(loadJobsLock) {
            loadJobs.values.forEach { it.cancel() }
            loadJobs.clear()
        }
    }

    /// UX-14 companion to [detach]: restart any tab load that state says is running but whose
    /// job no longer is (cancelled by [detach] while the screen was covered). `reset` only when
    /// the tab never delivered items — a loading-MORE interruption keeps its pages.
    private fun resumeInterruptedTabLoads() {
        // Liveness reads under the lock; the restarts happen outside it (loadTabPage takes the
        // same lock internally, and keeping the loop short avoids holding it across launches).
        val stalled = kotlinx.atomicfu.locks.synchronized(loadJobsLock) {
            _uiState.value.tabs.mapIndexedNotNull { index, tab ->
                if (tab.isAllTab) return@mapIndexedNotNull null // "All" aggregates per-source tabs
                val stateSaysLoading = tab.isLoading || tab.isLoadingMore
                val jobIsLive = loadJobs[index]?.isActive == true
                if (stateSaysLoading && !jobIsLive) index to tab.items.isEmpty() else null
            }
        }
        stalled.forEach { (index, resetNeeded) -> loadTabPage(index, reset = resetNeeded) }
    }

    fun loadMoreSelectedTab() {
        val current = _uiState.value
        val selectedTab = current.selectedTab ?: return
        if (selectedTab.isAllTab) {
            current.tabs.forEachIndexed { index, tab ->
                if (!tab.isAllTab && tab.canLoadMore && !tab.isLoading && !tab.isLoadingMore) {
                    loadTabPage(index, reset = false)
                }
            }
            return
        }

        if (selectedTab.canLoadMore && !selectedTab.isLoading && !selectedTab.isLoadingMore) {
            loadTabPage(current.selectedTabIndex, reset = false)
        }
    }

    // Upstream a255680b0: tabs load concurrently, so each update is an atomic read-modify-write —
    // two tabs finishing together no longer drop one another's results.
    private fun updateTab(index: Int, transform: (FolderTab) -> FolderTab) {
        _uiState.update { current ->
            val updatedTabs = current.tabs.toMutableList()
            if (index !in updatedTabs.indices) return@update current
            updatedTabs[index] = transform(updatedTabs[index])

            val allDone = updatedTabs.none { !it.isAllTab && it.isLoading }
            current.copy(
                tabs = updatedTabs,
                isLoading = !allDone,
            )
        }
    }

    private fun loadTabPage(index: Int, reset: Boolean) {
        val currentTab = _uiState.value.tabs.getOrNull(index) ?: return
        val requestedSkip = if (reset) 0 else currentTab.nextSkip ?: return
        val currentSource = currentTab.source
        if (
            currentSource?.isTmdb != true &&
            currentSource?.isTrakt != true &&
            currentTab.manifestUrl == null
        ) return

        updateTab(index) { tab ->
            if (reset) {
                tab.copy(
                    items = emptyList(),
                    isLoading = true,
                    isLoadingMore = false,
                    nextSkip = null,
                    consecutiveDuplicatePages = 0,
                    error = null,
                )
            } else {
                tab.copy(
                    isLoadingMore = true,
                    error = null,
                )
            }
        }

        kotlinx.atomicfu.locks.synchronized(loadJobsLock) {
            loadJobs.remove(index)?.cancel()
        }
        // UX-14 (Codex gate 2, rounds 5+8): LAZY start so the job is registered in [loadJobs]
        // BEFORE it can run — the ownership guards in onSuccess/onFailure below compare against
        // this map (via `registeredJob`, the self-reference a `val` initializer can't legally
        // hold), and an eagerly-started job could in principle complete before the map write.
        var registeredJob: Job? = null
        val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
            runCatching {
                val source = currentTab.source
                when {
                    source?.isTmdb == true -> TmdbCollectionSourceResolver.resolve(
                        source = source,
                        page = if (reset) 1 else requestedSkip,
                    )

                    source?.isTrakt == true -> TraktPublicListSourceResolver.resolve(
                        source = source,
                        page = if (reset) 1 else requestedSkip,
                    )

                    else -> fetchCatalogPage(
                        manifestUrl = requireNotNull(currentTab.manifestUrl),
                        type = currentTab.type,
                        catalogId = currentTab.catalogId,
                        genre = currentTab.genre,
                        skip = requestedSkip.takeIf { it > 0 },
                    )
                }.withUnreleasedFilter()
            }.onSuccess { page ->
                // UX-14 (Codex gate 2, rounds 5+8): cancellation is cooperative — a job cancelled
                // by [detach]/[clear]/a same-index reload just after its final suspension still
                // runs this non-suspending block. Publishing then would overwrite a resumed
                // request or leak a cleared profile's items back into state. Only the job
                // currently registered for this index may publish, and the check + publication
                // hold the registry lock so a concurrent replacement can't slip between them.
                kotlinx.atomicfu.locks.synchronized(loadJobsLock) {
                if (loadJobs[index] !== registeredJob) return@onSuccess
                updateTab(index) { tab ->
                    val mergedItems = if (reset) {
                        page.items
                    } else {
                        mergeCatalogItems(tab.items, page.items)
                    }
                    val supportsPagination = tab.supportsPagination || page.rawItemCount >= CATALOG_PAGE_SIZE
                    val loadedNewItems = reset || mergedItems.size > tab.items.size
                    val paginationState = nextCatalogPaginationState(
                        supportsPagination = supportsPagination,
                        requestedSkip = requestedSkip,
                        page = page,
                        loadedNewItems = loadedNewItems,
                        consecutiveDuplicatePages = if (reset) 0 else tab.consecutiveDuplicatePages,
                    )
                    tab.copy(
                        items = mergedItems,
                        supportsPagination = supportsPagination,
                        isLoading = false,
                        isLoadingMore = false,
                        nextSkip = paginationState.nextSkip,
                        consecutiveDuplicatePages = paginationState.consecutiveDuplicatePages,
                        error = null,
                    )
                }
                rebuildAllTab()
                } // synchronized(loadJobsLock)
            }.onFailure { error ->
                // UX-14 (Codex gate 2): a [detach]-cancelled load is NOT a failure. Writing
                // flags/error here raced the pop-back [initialize] — once the flags read false,
                // [resumeInterruptedTabLoads] saw nothing to resume and the tab sat empty with a
                // cancellation message and no retry path. Leaving state untouched keeps the tab
                // "loading with no live job", which is exactly the shape the resume path restarts.
                // (Same contract as CatalogRepository's fetch handlers.)
                if (error is CancellationException) return@onFailure
                // Rounds 5+8: same locked publication guard as onSuccess — a superseded job's
                // failure must not stamp an error onto a tab a NEWER job now owns.
                kotlinx.atomicfu.locks.synchronized(loadJobsLock) {
                    if (loadJobs[index] !== registeredJob) return@onFailure
                    log.e(error) { "Failed to load source ${currentTab.catalogId}" }
                    updateTab(index) { tab ->
                        tab.copy(
                            isLoading = false,
                            isLoadingMore = false,
                            nextSkip = if (reset) null else tab.nextSkip,
                            error = error.message,
                        )
                    }
                    rebuildAllTab()
                }
            }
        }
        registeredJob = job
        kotlinx.atomicfu.locks.synchronized(loadJobsLock) {
            loadJobs[index] = job
        }
        job.start()
    }

    private fun rebuildAllTab() {
        val current = _uiState.value
        if (!current.showAllTab) return
        val sourceTabs = current.tabs.filter { !it.isAllTab }

        // Round-robin merge
        val merged = mutableListOf<MetaPreview>()
        val seenKeys = mutableSetOf<String>()
        val iterators = sourceTabs.map { it.items.iterator() }
        var hasMore = true
        while (hasMore) {
            hasMore = false
            for (iterator in iterators) {
                if (iterator.hasNext()) {
                    val item = iterator.next()
                    if (seenKeys.add(item.stableKey())) {
                        merged.add(item)
                    }
                    hasMore = true
                }
            }
        }

        val updatedTabs = current.tabs.toMutableList()
        val allTabIndex = updatedTabs.indexOfFirst { it.isAllTab }
        if (allTabIndex >= 0) {
            val hasInitialLoads = sourceTabs.any { it.isLoading }
            val hasLoadMore = sourceTabs.any { it.isLoadingMore }
            val errorMessage = sourceTabs.firstOrNull { it.error != null }?.error
            updatedTabs[allTabIndex] = updatedTabs[allTabIndex].copy(
                items = merged,
                isLoading = hasInitialLoads,
                isLoadingMore = hasLoadMore,
                error = errorMessage.takeIf { merged.isEmpty() },
            )
        }
        _uiState.value = current.copy(tabs = updatedTabs)
    }

    fun getCatalogSectionsForRows(): List<HomeCatalogSection> {
        val current = _uiState.value
        val folder = current.folder ?: return emptyList()
        val collectionId = activeCollectionId ?: return emptyList()

        return current.tabs.filter { !it.isAllTab && it.items.isNotEmpty() }.mapNotNull { tab ->
            val directSource = tab.source?.let { it.isTmdb || it.isTrakt } == true
            val target = if (directSource) {
                val sourceKey = tab.sourceKey ?: return@mapNotNull null
                CatalogTarget.CollectionSource(
                    collectionId = collectionId,
                    folderId = folder.id,
                    sourceKey = sourceKey,
                    contentType = tab.type,
                    supportsPagination = tab.supportsPagination,
                )
            } else {
                val manifestUrl = tab.manifestUrl ?: return@mapNotNull null
                CatalogTarget.Addon(
                    manifestUrl = manifestUrl,
                    contentType = tab.type,
                    catalogId = tab.catalogId,
                    genre = tab.genre,
                    supportsPagination = tab.supportsPagination,
                )
            }
            HomeCatalogSection(
                key = "folder_${folder.id}_${tab.label}",
                title = tab.label,
                subtitle = tab.typeLabel,
                addonName = "",
                target = target,
                items = tab.items,
                availableItemCount = tab.items.size,
                hasMore = tab.canLoadMore,
            )
        }
    }
}

private fun Boolean?.orFalse(): Boolean = this == true

private fun CatalogPage.withUnreleasedFilter(): CatalogPage {
    if (!HomeCatalogSettingsRepository.snapshot().hideUnreleasedContent) return this
    val filteredItems = items.filterReleasedItems(CurrentDateProvider.todayIsoDate())
    return if (filteredItems.size == items.size) this else copy(items = filteredItems)
}

private fun tmdbCatalogId(source: CollectionSource): String =
    buildString {
        append("tmdb_")
        append(source.tmdbSourceType?.lowercase().orEmpty())
        source.tmdbId?.let {
            append("_")
            append(it)
        }
        append("_")
        append(source.mediaType?.lowercase().orEmpty())
    }

private fun traktCatalogId(source: CollectionSource): String =
    listOf(
        "trakt",
        "list",
        source.traktListId?.toString().orEmpty(),
        source.mediaType?.lowercase().orEmpty(),
        TraktListSort.normalize(source.sortBy),
        TraktSortHow.normalize(source.sortHow),
    ).joinToString("_")
