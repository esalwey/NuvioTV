package com.nuvio.app.features.details

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.fetchAddonResponseText
import com.nuvio.app.features.home.HomeUnreleasedContentPolicyProvider
import com.nuvio.app.features.home.filterReleasedItems
import com.nuvio.app.features.mdblist.MdbListMetadataService
import com.nuvio.app.features.mdblist.MdbListSettingsRepository
import com.nuvio.app.features.tmdb.TmdbMetadataService
import com.nuvio.app.features.tmdb.TmdbService
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.trakt.TraktAuthRepository
import com.nuvio.app.features.trakt.TraktConnectionMode
import com.nuvio.app.features.trakt.TraktRelatedRepository
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.trakt.shouldUseTraktMoreLikeThis
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

object MetaDetailsRepository {
    private data class CachedMetaEntry(
        val baseMeta: MetaDetails,
        val metaScreenMeta: MetaDetails? = null,
        val metaScreenSettingsFingerprint: String? = null,
    )

    private val log = Logger.withTag("MetaDetailsRepo")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main + uncaughtCoroutineLogger("MetaDetailsRepository"))
    private val _uiState = MutableStateFlow(MetaDetailsUiState())
    val uiState: StateFlow<MetaDetailsUiState> = _uiState.asStateFlow()
    private var activeRequestKey: String? = null
    private val cachedMetaByRequestKey = mutableMapOf<String, CachedMetaEntry>()
    /**
     * BUG-63: bumped by [clear]. Every load captures the generation it started under and writes
     * to the cache only if nothing cleared it in between — otherwise a request that was in flight
     * across a Metadata Language flip (or any other `clear()`) would repopulate the map with the
     * old language's meta/trailers right after the invalidation.
     */
    private var cacheGeneration = 0

    /** A request may publish to the UI only if it is still the active key AND nothing `clear()`ed
     *  the repo since it started — otherwise an old-language load could overwrite a newer one. */
    private fun isLiveRequest(requestKey: String, generation: Int): Boolean =
        generation == cacheGeneration && MetaRequestResolution.isActiveRequest(activeRequestKey, requestKey)

    /**
     * The generation check and the map write happen together on the main dispatcher (the same
     * one [clear] and [load] run on), so a `clear()` can never slip between the check and the
     * write from a `Dispatchers.Default` enrichment. `build` sees the CURRENT cached entry.
     */
    private suspend fun putCache(
        requestKey: String,
        generation: Int,
        build: (existing: CachedMetaEntry?) -> CachedMetaEntry?,
    ) = withContext(Dispatchers.Main.immediate) {
        if (generation != cacheGeneration) return@withContext
        val entry = build(cachedMetaByRequestKey[requestKey])
        if (entry == null) cachedMetaByRequestKey.remove(requestKey) else cachedMetaByRequestKey[requestKey] = entry
    }

    fun load(type: String, id: String) {
        log.d { "load() called — type=$type id=$id" }
        val requestKey = MetaRequestResolution.requestKey(type, id)
        val currentState = _uiState.value
        val mdbListSettings = MdbListSettingsRepository.snapshot()
        val metaScreenSettingsFingerprint = buildMetaScreenSettingsFingerprint(mdbListSettings)

        cachedMetaByRequestKey[requestKey]?.let { cachedEntry ->
            cachedEntry.metaScreenMeta
                ?.takeIf { cachedEntry.metaScreenSettingsFingerprint == metaScreenSettingsFingerprint }
                ?.let { cachedMeta ->
                    _uiState.value = MetaDetailsUiState(meta = cachedMeta.withUnreleasedFilter(), requestKey = requestKey)
                    activeRequestKey = requestKey
                    return
                }

            val cachedBaseMeta = cachedEntry.baseMeta
            if (!shouldEnrichForMetaScreen(cachedBaseMeta, id, mdbListSettings)) {
                _uiState.value = MetaDetailsUiState(meta = cachedBaseMeta.withUnreleasedFilter(), requestKey = requestKey)
                activeRequestKey = requestKey
                return
            }

            if (currentState.isLoading && MetaRequestResolution.isActiveRequest(activeRequestKey, requestKey)) {
                log.d { "Meta screen enrichment already in flight — type=$type id=$id" }
                return
            }

            activeRequestKey = requestKey
            _uiState.value = MetaDetailsUiState(
                isLoading = true,
                meta = cachedBaseMeta,
                requestKey = requestKey,
            )
            val cachedPathGeneration = cacheGeneration

            scope.launch {
                val enrichedMeta = withContext(Dispatchers.Default) {
                    enrichForMetaScreen(
                        generation = cachedPathGeneration,
                        requestKey = requestKey,
                        meta = cachedBaseMeta,
                        fallbackItemId = id,
                        fallbackItemType = type,
                        settings = mdbListSettings,
                        settingsFingerprint = metaScreenSettingsFingerprint,
                    )
                }
                // Skip if a newer load() has taken over the shared repo.
                if (isLiveRequest(requestKey, cachedPathGeneration)) {
                    _uiState.value = MetaDetailsUiState(meta = enrichedMeta.withUnreleasedFilter(), requestKey = requestKey)
                }
            }
            return
        }

        if (currentState.meta?.type == type && currentState.meta?.id == id && !currentState.isLoading) {
            log.d { "Skipping reload for cached meta — type=$type id=$id" }
            activeRequestKey = requestKey
            return
        }

        if (currentState.isLoading && MetaRequestResolution.isActiveRequest(activeRequestKey, requestKey)) {
            log.d { "Request already in flight — type=$type id=$id" }
            return
        }

        activeRequestKey = requestKey
        _uiState.value = MetaDetailsUiState(isLoading = true, requestKey = requestKey)
        val generation = cacheGeneration

        scope.launch {
            val metaLookupId = resolveMetaLookupId(itemId = id, itemType = type)
            val manifests = findReadyMetaManifests(type = type, id = metaLookupId)

            if (manifests.isEmpty()) {
                val tmdbMeta = tryFetchTmdbFallbackMeta(type = type, id = id)
                if (tmdbMeta != null) {
                    publishLoadedMeta(
                        generation = generation,
                        requestKey = requestKey,
                        meta = tmdbMeta,
                        fallbackItemId = id,
                        fallbackItemType = type,
                        mdbListSettings = mdbListSettings,
                        metaScreenSettingsFingerprint = metaScreenSettingsFingerprint,
                    )
                    return@launch
                }

                log.w { "No addon provides meta for type=$type id=$id" }
                // Skip if a newer load() has taken over the shared repo.
                if (isLiveRequest(requestKey, generation)) {
                    _uiState.value = MetaDetailsUiState(
                        errorMessage = resourceString(
                            "No addon provides meta for this content.",
                            StringKey.details_no_addon_meta,
                        ),
                        requestKey = requestKey,
                    )
                    activeRequestKey = null
                }
                return@launch
            }

            for (manifest in manifests) {
                // Bound each addon's meta fetch (mirrors fetch()); without this a slow addon can
                // hang the sequential loop for minutes (only ktor's 60s per-request timeout applies).
                val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                    withContext(Dispatchers.Default) {
                        tryFetchMeta(manifest, type, metaLookupId, includeMdbList = false)
                    }
                }
                if (result != null) {
                    publishLoadedMeta(
                        generation = generation,
                        requestKey = requestKey,
                        meta = result,
                        fallbackItemId = metaLookupId,
                        fallbackItemType = type,
                        mdbListSettings = mdbListSettings,
                        metaScreenSettingsFingerprint = metaScreenSettingsFingerprint,
                    )
                    return@launch
                }
            }

            val tmdbMeta = tryFetchTmdbFallbackMeta(type = type, id = id)
            if (tmdbMeta != null) {
                publishLoadedMeta(
                    generation = generation,
                    requestKey = requestKey,
                    meta = tmdbMeta,
                    fallbackItemId = id,
                    fallbackItemType = type,
                    mdbListSettings = mdbListSettings,
                    metaScreenSettingsFingerprint = metaScreenSettingsFingerprint,
                )
                return@launch
            }

            // Skip if a newer load() has taken over the shared repo.
            if (isLiveRequest(requestKey, generation)) {
                _uiState.value = MetaDetailsUiState(
                    errorMessage = resourceString(
                        "Could not load details from any addon.",
                        StringKey.details_load_failed_all_addons,
                    ),
                    requestKey = requestKey,
                )
                activeRequestKey = null
            }
        }
    }

    /**
     * The addon's own `imdb_id` for the title [id] (upstream 90054b7b9), from the title on screen or
     * the metadata cache: the IMDB id a kitsu/mal/custom-id title is enriched and skipped with.
     * Best effort — a title whose details were never loaded this session has none.
     */
    internal fun addonImdbId(id: String): String? {
        val meta = _uiState.value.meta?.takeIf { it.id == id }
            ?: cachedMetaByRequestKey.values.firstNotNullOfOrNull { entry ->
                entry.baseMeta.takeIf { it.id == id }
            }
        return meta?.imdbId?.trim()?.takeIf { it.startsWith("tt", ignoreCase = true) }
    }

    fun peek(type: String, id: String): MetaDetails? {
        val requestKey = MetaRequestResolution.requestKey(type, id)
        val currentMeta = _uiState.value.meta?.takeIf { it.type == type && it.id == id }
        if (currentMeta != null) return currentMeta

        val metaScreenSettingsFingerprint = buildMetaScreenSettingsFingerprint(MdbListSettingsRepository.snapshot())
        val cachedEntry = cachedMetaByRequestKey[requestKey] ?: return null
        val cachedMeta = cachedEntry.metaScreenMeta
            ?.takeIf { cachedEntry.metaScreenSettingsFingerprint == metaScreenSettingsFingerprint }
            ?: cachedEntry.baseMeta
        // Upstream 752962638: the same view a loaded title gets (unreleased rows filtered).
        return cachedMeta.withUnreleasedFilter()
    }

    /**
     * Every mutation of the cache/generation runs on the main dispatcher (see [putCache]). Callers
     * on main (Settings, Detail) get the clear synchronously — `Main.immediate` runs the block
     * inline; a caller on another dispatcher (e.g. a profile sync bumping the TMDB language from
     * `SyncManager`'s Default scope) gets it hopped onto main, so it can never interleave with a
     * generation-checked write.
     */
    fun clear() {
        scope.launch(Dispatchers.Main.immediate) {
            activeRequestKey = null
            cacheGeneration++
            cachedMetaByRequestKey.clear()
            _uiState.value = MetaDetailsUiState()
        }
    }

    // Upstream ccc6b87d (beta.12 port): `cacheResult = false` lets BULK callers (badge
    // resolution, episode-release sweeps — neither built on tvOS yet) resolve metadata without
    // permanently caching every item they touch. The default preserves existing behavior for
    // every current caller; ported now so shared/ stays in sync for when either bulk feature
    // lands here.
    suspend fun fetch(type: String, id: String, cacheResult: Boolean = true): MetaDetails? {
        val requestKey = MetaRequestResolution.requestKey(type, id)
        cachedMetaByRequestKey[requestKey]?.let { return it.baseMeta }
        val generation = cacheGeneration

        val metaLookupId = resolveMetaLookupId(itemId = id, itemType = type)
        val manifests = findReadyMetaManifests(type = type, id = metaLookupId)

        for (manifest in manifests) {
            val result = withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                tryFetchMeta(manifest, type, metaLookupId, includeMdbList = false)
            }
            if (result != null) {
                if (cacheResult) {
                    putCache(requestKey, generation) { CachedMetaEntry(baseMeta = result) }
                }
                return result
            }
        }

        return tryFetchTmdbFallbackMeta(type = type, id = id)?.also { result ->
            if (cacheResult) {
                putCache(requestKey, generation) { CachedMetaEntry(baseMeta = result) }
            }
        }
    }

    private const val FETCH_TIMEOUT_MS = 5_000L
    private const val METADATA_PROVIDER_READY_TIMEOUT_MS = 10_000L
    private const val TMDB_ENRICH_TIMEOUT_MS = 5_000L
    private const val MDBLIST_ENRICH_TIMEOUT_MS = 5_000L

    private suspend fun tryFetchMeta(
        manifest: AddonManifest,
        type: String,
        id: String,
        includeMdbList: Boolean,
    ): MetaDetails? {
        val url = buildAddonResourceUrl(
            manifestUrl = manifest.transportUrl,
            resource = "meta",
            type = type,
            id = id,
        )

        return try {
            TmdbSettingsRepository.ensureLoaded()
            log.d { "Fetching meta from: $url" }
            val payload = fetchAddonResponseText(url)
            log.d { "Raw payload length=${payload.length}, first 500 chars: ${payload.take(500)}" }
            val result = MetaDetailsParser.parse(payload)
            val tmdbEnriched = withTimeoutOrNull(TMDB_ENRICH_TIMEOUT_MS) {
                TmdbMetadataService.enrichMeta(
                    meta = result,
                    fallbackItemId = id,
                    settings = TmdbSettingsRepository.snapshot(),
                )
            } ?: result
            val enriched = if (includeMdbList) {
                MdbListSettingsRepository.ensureLoaded()
                withTimeoutOrNull(MDBLIST_ENRICH_TIMEOUT_MS) {
                    MdbListMetadataService.enrichMeta(
                        meta = tmdbEnriched,
                        fallbackItemId = id,
                        settings = MdbListSettingsRepository.snapshot(),
                    )
                } ?: tmdbEnriched
            } else {
                tmdbEnriched
            }
            log.d { "Parsed meta: type=${enriched.type}, name=${enriched.name}, videos=${enriched.videos.size}" }
            if (enriched.videos.isNotEmpty()) {
                val first = enriched.videos.first()
                log.d { "First video: id=${first.id} title=${first.title} s=${first.season} e=${first.episode} embeddedStreams=${first.streams.size}" }
            }
            enriched
        } catch (e: Throwable) {
            if (e is CancellationException) throw e
            log.e(e) { "Failed to fetch/parse meta from $url (manifest=${manifest.transportUrl})" }
            null
        }
    }

    private suspend fun findReadyMetaManifests(type: String, id: String): List<AddonManifest> {
        AddonRepository.initialize()

        findMetaManifests(AddonRepository.uiState.value, type, id).takeIf { it.isNotEmpty() }?.let { return it }

        if (!AddonRepository.uiState.value.hasPendingEnabledAddonManifests()) {
            return emptyList()
        }

        val readyState = withTimeoutOrNull(METADATA_PROVIDER_READY_TIMEOUT_MS) {
            AddonRepository.uiState.first { state ->
                findMetaManifests(state, type, id).isNotEmpty() ||
                    !state.hasPendingEnabledAddonManifests()
            }
        } ?: AddonRepository.uiState.value

        return findMetaManifests(readyState, type, id)
    }

    private fun findMetaManifests(state: com.nuvio.app.features.addons.AddonsUiState, type: String, id: String): List<AddonManifest> =
        state.addons
            .enabledAddons()
            .mapNotNull { it.manifest }
            .filter { manifest ->
                manifest.resources.any { resource ->
                    resource.name == "meta" &&
                        resource.types.contains(type) &&
                        (resource.idPrefixes.isEmpty() || resource.idPrefixes.any { id.startsWith(it) })
                }
            }

    private fun com.nuvio.app.features.addons.AddonsUiState.hasPendingEnabledAddonManifests(): Boolean =
        addons.enabledAddons().any { addon -> addon.manifest == null && addon.isRefreshing }

    private suspend fun resolveMetaLookupId(itemId: String, itemType: String): String {
        val tmdbId = MetaRequestResolution.parseTmdbId(itemId) ?: return itemId

        return withTimeoutOrNull(FETCH_TIMEOUT_MS) {
            TmdbService.tmdbToImdb(tmdbId = tmdbId, mediaType = itemType)
        }
            ?.takeIf { it.isNotBlank() }
            ?: itemId
    }

    private suspend fun tryFetchTmdbFallbackMeta(type: String, id: String): MetaDetails? =
        withTimeoutOrNull(TMDB_ENRICH_TIMEOUT_MS) {
            TmdbMetadataService.fetchStandaloneMeta(
                type = type,
                id = id,
                settings = TmdbSettingsRepository.snapshot(),
            )
        }

    private suspend fun publishLoadedMeta(
        generation: Int,
        requestKey: String,
        meta: MetaDetails,
        fallbackItemId: String,
        fallbackItemType: String,
        mdbListSettings: com.nuvio.app.features.mdblist.MdbListSettings,
        metaScreenSettingsFingerprint: String,
    ) {
        val cachedEntry = CachedMetaEntry(baseMeta = meta)
        putCache(requestKey, generation) { cachedEntry }

        if (!shouldEnrichForMetaScreen(meta, fallbackItemId, mdbListSettings)) {
            // Skip if a newer load() has taken over the shared repo (caching above still stands).
            if (isLiveRequest(requestKey, generation)) {
                _uiState.value = MetaDetailsUiState(meta = meta.withUnreleasedFilter(), requestKey = requestKey)
            }
            return
        }

        if (isLiveRequest(requestKey, generation)) {
            _uiState.value = MetaDetailsUiState(
                isLoading = true,
                meta = meta,
                requestKey = requestKey,
            )
        }
        val enrichedMeta = withContext(Dispatchers.Default) {
            enrichForMetaScreen(
                generation = generation,
                requestKey = requestKey,
                meta = meta,
                fallbackItemId = fallbackItemId,
                fallbackItemType = fallbackItemType,
                settings = mdbListSettings,
                settingsFingerprint = metaScreenSettingsFingerprint,
            )
        }
        putCache(requestKey, generation) {
            cachedEntry.copy(
                metaScreenMeta = enrichedMeta,
                metaScreenSettingsFingerprint = metaScreenSettingsFingerprint,
            )
        }
        if (isLiveRequest(requestKey, generation)) {
            _uiState.value = MetaDetailsUiState(meta = enrichedMeta.withUnreleasedFilter(), requestKey = requestKey)
        }
    }

    private suspend fun enrichForMetaScreen(
        generation: Int,
        requestKey: String,
        meta: MetaDetails,
        fallbackItemId: String,
        fallbackItemType: String,
        settings: com.nuvio.app.features.mdblist.MdbListSettings,
        settingsFingerprint: String,
    ): MetaDetails {
        val mdbListEnrichedMeta = withTimeoutOrNull(MDBLIST_ENRICH_TIMEOUT_MS) {
            MdbListMetadataService.enrichMeta(
                meta = meta,
                fallbackItemId = fallbackItemId,
                settings = settings,
            )
        } ?: meta
        val enrichedMeta = applyMoreLikeThisSource(
            meta = mdbListEnrichedMeta,
            fallbackItemId = fallbackItemId,
            fallbackItemType = fallbackItemType,
        )

        putCache(requestKey, generation) { existing ->
            existing
                ?.copy(
                    metaScreenMeta = enrichedMeta,
                    metaScreenSettingsFingerprint = settingsFingerprint,
                )
                ?: CachedMetaEntry(
                    baseMeta = meta,
                    metaScreenMeta = enrichedMeta,
                    metaScreenSettingsFingerprint = settingsFingerprint,
                )
        }

        return enrichedMeta
    }

    private suspend fun applyMoreLikeThisSource(
        meta: MetaDetails,
        fallbackItemId: String,
        fallbackItemType: String,
    ): MetaDetails {
        TraktSettingsRepository.ensureLoaded()
        TraktAuthRepository.ensureLoaded()
        TmdbSettingsRepository.ensureLoaded()

        val traktSettings = TraktSettingsRepository.uiState.value
        val isTraktAuthenticated = TraktAuthRepository.uiState.value.mode == TraktConnectionMode.CONNECTED
        val shouldUseTrakt = shouldUseTraktMoreLikeThis(
            isAuthenticated = isTraktAuthenticated,
            source = traktSettings.moreLikeThisSource,
        ) && supportsMoreLikeThis(meta, fallbackItemType)

        if (shouldUseTrakt) {
            val items = runCatching {
                // Bound the related-titles call so a slow Trakt response can't stall enrichment.
                withTimeoutOrNull(FETCH_TIMEOUT_MS) {
                    TraktRelatedRepository.getRelated(
                        meta = meta,
                        fallbackItemId = fallbackItemId,
                        fallbackItemType = fallbackItemType,
                    )
                } ?: emptyList()
            }.onFailure { error ->
                log.w { "Failed to load Trakt related titles for ${meta.id}: ${error.message}" }
            }.getOrDefault(emptyList())

            return meta.copy(
                moreLikeThis = items,
                moreLikeThisSource = MoreLikeThisSource.TRAKT.takeIf { items.isNotEmpty() },
            )
        }

        val tmdbSettings = TmdbSettingsRepository.snapshot()
        if (!tmdbSettings.enabled || !tmdbSettings.useMoreLikeThis) {
            return meta.copy(moreLikeThis = emptyList(), moreLikeThisSource = null)
        }

        return meta.copy(
            moreLikeThisSource = MoreLikeThisSource.TMDB.takeIf { meta.moreLikeThis.isNotEmpty() },
        )
    }

    private fun shouldFetchMdbListOnMetaScreen(
        meta: MetaDetails,
        fallbackItemId: String,
        settings: com.nuvio.app.features.mdblist.MdbListSettings,
    ): Boolean = MdbListMetadataService.shouldFetchForMeta(
        meta = meta,
        fallbackItemId = fallbackItemId,
        settings = settings,
    )

    private fun shouldEnrichForMetaScreen(
        meta: MetaDetails,
        fallbackItemId: String,
        settings: com.nuvio.app.features.mdblist.MdbListSettings,
    ): Boolean {
        if (shouldFetchMdbListOnMetaScreen(meta, fallbackItemId, settings)) return true
        return shouldApplyMoreLikeThisSource(meta)
    }

    private fun shouldApplyMoreLikeThisSource(meta: MetaDetails): Boolean {
        TraktSettingsRepository.ensureLoaded()
        TraktAuthRepository.ensureLoaded()
        TmdbSettingsRepository.ensureLoaded()

        val traktSettings = TraktSettingsRepository.uiState.value
        val isTraktAuthenticated = TraktAuthRepository.uiState.value.mode == TraktConnectionMode.CONNECTED
        val tmdbSettings = TmdbSettingsRepository.snapshot()
        return shouldUseTraktMoreLikeThis(
            isAuthenticated = isTraktAuthenticated,
            source = traktSettings.moreLikeThisSource,
        ) || !tmdbSettings.enabled || !tmdbSettings.useMoreLikeThis || meta.moreLikeThisSource == null && meta.moreLikeThis.isNotEmpty()
    }

    private fun buildMetaScreenSettingsFingerprint(
        settings: com.nuvio.app.features.mdblist.MdbListSettings,
    ): String {
        TraktSettingsRepository.ensureLoaded()
        TraktAuthRepository.ensureLoaded()
        TmdbSettingsRepository.ensureLoaded()
        val providers = settings.enabledProvidersInPriorityOrder().joinToString(",")
        val traktSettings = TraktSettingsRepository.uiState.value
        val traktAuthMode = TraktAuthRepository.uiState.value.mode
        val tmdbSettings = TmdbSettingsRepository.snapshot()
        return buildString {
            append("${settings.enabled}:${settings.apiKey.trim()}:$providers")
            append("|more_like=${traktSettings.moreLikeThisSource}:$traktAuthMode")
            append("|tmdb=${tmdbSettings.enabled}:${tmdbSettings.useMoreLikeThis}:${tmdbSettings.hasApiKey}:${tmdbSettings.language}")
        }
    }

    private fun supportsMoreLikeThis(meta: MetaDetails, fallbackItemType: String): Boolean =
        normalizeMoreLikeThisType(meta.type) != null || normalizeMoreLikeThisType(fallbackItemType) != null

    private fun normalizeMoreLikeThisType(value: String?): String? =
        when (value?.trim()?.lowercase()) {
            "movie", "film" -> "movie"
            "series", "show", "tv", "tvshow" -> "series"
            else -> null
        }

    private fun MetaDetails.withUnreleasedFilter(): MetaDetails {
        if (!HomeUnreleasedContentPolicyProvider.policy.hideUnreleasedContent()) return this
        val todayIsoDate = CurrentDateProvider.todayIsoDate()
        val releasedMoreLikeThis = moreLikeThis.filterReleasedItems(todayIsoDate)
        return copy(
            moreLikeThis = releasedMoreLikeThis,
            moreLikeThisSource = moreLikeThisSource.takeIf { releasedMoreLikeThis.isNotEmpty() },
            collectionItems = collectionItems.filterReleasedItems(todayIsoDate),
        )
    }

   
    fun findEmbeddedStreams(videoId: String): List<com.nuvio.app.features.streams.StreamItem> {
        val meta = _uiState.value.meta ?: return emptyList()
        val videosWithStreams = meta.videos.filter { it.streams.isNotEmpty() }
        if (videosWithStreams.isEmpty()) return emptyList()

        val directMatch = videosWithStreams.firstOrNull { it.id == videoId }
        if (directMatch != null) return directMatch.streams

        val parts = videoId.split(":")
        if (parts.size >= 3) {
            val season = parts[parts.size - 2].toIntOrNull()
            val episode = parts[parts.size - 1].toIntOrNull()
            if (season != null && episode != null) {
                val episodeMatch = videosWithStreams.firstOrNull { it.season == season && it.episode == episode }
                if (episodeMatch != null) return episodeMatch.streams
            }
        }

        val prefixMatch = videosWithStreams.firstOrNull { it.id.startsWith("$videoId:") }
        if (prefixMatch != null) return prefixMatch.streams

        if (videoId == meta.id && videosWithStreams.size == 1) {
            return videosWithStreams.first().streams
        }

        if (videoId == meta.id && videosWithStreams.isNotEmpty()) {
            return videosWithStreams.flatMap { it.streams }
        }

        return emptyList()
    }
}
