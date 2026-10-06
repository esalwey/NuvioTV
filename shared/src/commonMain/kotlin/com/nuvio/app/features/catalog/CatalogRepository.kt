package com.nuvio.app.features.catalog

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.collection.TmdbCollectionSourceResolver
import com.nuvio.app.features.collection.catalogRouteKey
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.library.sortLibraryItems
import com.nuvio.app.features.library.toMetaPreview
import com.nuvio.app.features.home.HomeCatalogSettingsRepository
import com.nuvio.app.features.home.filterReleasedItems
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
import kotlinx.coroutines.launch

object CatalogRepository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("CatalogRepository"))
    private val _uiState = MutableStateFlow(CatalogUiState())
    val uiState: StateFlow<CatalogUiState> = _uiState.asStateFlow()

    private var activeJob: Job? = null

    // Publication guard: cancellation is cooperative, so a job cancelled by detach()/clear()
    // while inside non-suspending work (e.g. library sorting) still reaches its fold. The
    // request-equality guard alone can't stop it — detach() deliberately RETAINS activeRequest —
    // so each fetch captures the generation at launch and may only publish while it is still the
    // current one; detach()/clear()/every new fetch bump it (Codex round 8). Atomic because the
    // bumps come from the Swift main thread while the folds read it on Dispatchers.Default —
    // a plain Int has no cross-thread visibility guarantee on K/N (Codex round 12).
    private val fetchGeneration = kotlinx.atomicfu.atomic(0)
    private var activeRequest: CatalogRequest? = null
    private val scrollPositions = linkedMapOf<CatalogRequest, CatalogScrollPosition>()

    fun load(
        target: CatalogTarget,
        force: Boolean = false,
    ) {
        val request = catalogRequest(target)
        // `isLoading` may only short-circuit while the fetch that set it is still alive: after a
        // pop-time detach() a cancelled-before-start job can leave isLoading=true behind with no
        // job to ever clear it, and trusting it here would wedge every same-target reload.
        val fetchStillRunning = activeJob?.isActive == true && _uiState.value.isLoading
        if (!force && activeRequest == request && (_uiState.value.items.isNotEmpty() || fetchStillRunning)) {
            // Re-entering a retained grid whose fetch was detach()-cancelled mid-page: heal the
            // stranded isLoading before returning, or the Swift side's `itemAppeared` guard never
            // calls loadMore() again and the footer spinner sticks forever (Codex round 3). Safe
            // to emit here — this runs from a live screen's own load(), not a pop teardown.
            if (_uiState.value.isLoading && activeJob?.isActive != true) {
                _uiState.value = _uiState.value.copy(isLoading = false)
            }
            return
        }
        activeRequest = request
        if (target is CatalogTarget.Library) {
            fetchInternalLibrary(request)
            return
        }
        fetchPage(
            request = request,
            reset = true,
            forceRefresh = force,
        )
    }

    fun loadMore() {
        val request = activeRequest ?: return
        val current = _uiState.value
        // Same rationale as load()'s guard: trust isLoading only while the fetch that set it is
        // still alive. A pop-time detach() during a page load strands isLoading=true with no job
        // to ever clear it — an unconditional check would disable pagination for this catalog
        // permanently (Codex round 2).
        val fetchStillRunning = activeJob?.isActive == true && current.isLoading
        if (fetchStillRunning || current.nextSkip == null) return
        fetchPage(
            request = request,
            reset = false,
            forceRefresh = false,
        )
    }

    fun clear() {
        fetchGeneration.incrementAndGet()
        activeJob?.cancel()
        activeRequest = null
        scrollPositions.clear()
        _uiState.value = CatalogUiState()
    }

    /// H1 hardening (BUG-47/UX-13): the "See All" grid's `stop()` used to call [clear], which is the
    /// full-teardown variant (also used by [com.nuvio.app.core.bootstrap.TvOsProviderInstaller] on
    /// sign-out) — it cancels the fetch AND resets `items`/`scrollPositions` to blank. On a normal
    /// pop that double duty was actively harmful: it raced a stray in-flight completion against the
    /// pop's own teardown (BUG-47), and it threw away the scroll position `load()`'s same-target
    /// early-return exists to preserve (UX-13). `detach()` does only the half a pop needs — cancel
    /// the active fetch job — and leaves `activeRequest`, `items`, and `scrollPositions` untouched,
    /// so a subsequent `load()` for the same target still early-returns with everything intact.
    /// `clear()` itself is untouched; its sign-out caller needs the full wipe.
    fun detach() {
        fetchGeneration.incrementAndGet()
        activeJob?.cancel()
    }

    fun scrollPosition(
        target: CatalogTarget,
    ): CatalogScrollPosition =
        scrollPositions[catalogRequest(target)]
            ?: CatalogScrollPosition()

    fun saveScrollPosition(
        target: CatalogTarget,
        firstVisibleItemIndex: Int,
        firstVisibleItemScrollOffset: Int,
    ) {
        val request = catalogRequest(target)
        scrollPositions[request] = CatalogScrollPosition(
            firstVisibleItemIndex = firstVisibleItemIndex,
            firstVisibleItemScrollOffset = firstVisibleItemScrollOffset,
        )
    }

    private fun fetchInternalLibrary(request: CatalogRequest) {
        activeJob?.cancel()
        val generation = fetchGeneration.incrementAndGet()
        _uiState.value = _uiState.value.copy(
            isLoading = true,
            errorMessage = null,
        )

        activeJob = scope.launch {
            runCatching {
                val target = request.target as CatalogTarget.Library
                LibraryRepository.ensureLoaded()
                val libraryState = LibraryRepository.uiState.value
                val items = libraryState.sections
                    .firstOrNull { it.type == target.sectionType }
                    ?.items
                    .orEmpty()
                sortLibraryItems(
                    items = items,
                    selected = target.sortOption,
                    sourceMode = libraryState.sourceMode,
                )
                    .map { it.toMetaPreview() }
                    .let(::dedupeCatalogItems)
            }.fold(
                onSuccess = { items ->
                    if (generation != fetchGeneration.value || activeRequest != request) return@fold
                    _uiState.value = CatalogUiState(
                        items = items,
                        isLoading = false,
                        nextSkip = null,
                        errorMessage = null,
                    )
                },
                onFailure = { error ->
                    // A detach()-cancelled job must not surface as a failure: activeRequest is
                    // deliberately retained across pops, so the request guard alone can't stop it.
                    if (error is CancellationException) return@fold
                    if (generation != fetchGeneration.value || activeRequest != request) return@fold
                    _uiState.value = CatalogUiState(
                        items = emptyList(),
                        isLoading = false,
                        nextSkip = null,
                        errorMessage = error.message ?: resourceString("Unable to load catalog items.", StringKey.catalog_load_failed),
                    )
                },
            )
        }
    }

    private fun fetchPage(
        request: CatalogRequest,
        reset: Boolean,
        forceRefresh: Boolean,
    ) {
        activeJob?.cancel()
        val generation = fetchGeneration.incrementAndGet()
        val current = _uiState.value
        val requestedSkip = if (reset) 0 else current.nextSkip ?: return

        _uiState.value = current.copy(
            items = if (reset) emptyList() else current.items,
            isLoading = true,
            nextSkip = if (reset) null else current.nextSkip,
            errorMessage = null,
        )

        activeJob = scope.launch {
            runCatching {
                when (val target = request.target) {
                    is CatalogTarget.Addon -> fetchCatalogPage(
                        manifestUrl = target.manifestUrl,
                        type = target.contentType,
                        catalogId = target.catalogId,
                        genre = target.genre,
                        search = target.search,
                        skip = requestedSkip.takeIf { it > 0 },
                        forceRefresh = forceRefresh,
                    )

                    is CatalogTarget.CollectionSource -> fetchCollectionSourcePage(
                        target = target,
                        page = requestedSkip.takeIf { it > 0 } ?: 1,
                    )

                    is CatalogTarget.Library -> error(resourceString("Unable to load catalog items.", StringKey.catalog_load_failed))
                }.withUnreleasedFilter(request.hideUnreleasedContent)
            }.fold(
                onSuccess = { page ->
                    if (generation != fetchGeneration.value || activeRequest != request) return@fold

                    val mergedItems = if (reset) {
                        dedupeCatalogItems(page.items)
                    } else {
                        mergeCatalogItems(_uiState.value.items, page.items)
                    }
                    val supportsPagination = request.target.supportsPagination || page.rawItemCount >= CATALOG_PAGE_SIZE
                    val loadedNewItems = reset || mergedItems.size > current.items.size
                    val paginationState = nextCatalogPaginationState(
                        supportsPagination = supportsPagination,
                        requestedSkip = requestedSkip,
                        page = page,
                        loadedNewItems = loadedNewItems,
                        consecutiveDuplicatePages = if (reset) 0 else current.consecutiveDuplicatePages,
                    )
                    _uiState.value = CatalogUiState(
                        items = mergedItems,
                        isLoading = false,
                        nextSkip = paginationState.nextSkip,
                        consecutiveDuplicatePages = paginationState.consecutiveDuplicatePages,
                        errorMessage = null,
                    )
                },
                onFailure = { error ->
                    // See fetchInternalLibrary: a pop-time detach() cancellation is not a failure.
                    if (error is CancellationException) return@fold
                    if (generation != fetchGeneration.value || activeRequest != request) return@fold

                    _uiState.value = current.copy(
                        items = if (reset) emptyList() else current.items,
                        isLoading = false,
                        nextSkip = null,
                        errorMessage = error.message ?: resourceString("Unable to load catalog items.", StringKey.catalog_load_failed),
                    )
                },
            )
        }
    }

    private fun catalogRequest(target: CatalogTarget): CatalogRequest =
        CatalogRequest(
            target = target,
            hideUnreleasedContent = HomeCatalogSettingsRepository.snapshot().hideUnreleasedContent,
        )
}

private fun CatalogPage.withUnreleasedFilter(hideUnreleasedContent: Boolean): CatalogPage {
    if (!hideUnreleasedContent) return this
    val filteredItems = items.filterReleasedItems(CurrentDateProvider.todayIsoDate())
    return if (filteredItems.size == items.size) this else copy(items = filteredItems)
}

private suspend fun fetchCollectionSourcePage(
    target: CatalogTarget.CollectionSource,
    page: Int,
): CatalogPage {
    CollectionRepository.initialize()
    val source = CollectionRepository.getCollection(target.collectionId)
        ?.folders
        ?.firstOrNull { it.id == target.folderId }
        ?.resolvedSources
        ?.firstOrNull { it.catalogRouteKey() == target.sourceKey }
        ?: error(resourceString("Unable to load catalog items.", StringKey.catalog_load_failed))

    return when {
        source.isTmdb -> TmdbCollectionSourceResolver.resolve(source = source, page = page)
        source.isTrakt -> TraktPublicListSourceResolver.resolve(source = source, page = page)
        else -> error(resourceString("Unable to load catalog items.", StringKey.catalog_load_failed))
    }
}

private data class CatalogRequest(
    val target: CatalogTarget,
    val hideUnreleasedContent: Boolean,
)
