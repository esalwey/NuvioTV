package com.nuvio.app.features.collection

import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.catalog.CatalogPage
import com.nuvio.app.features.catalog.fetchCatalogPage
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.trakt.TraktPublicListSourceResolver
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * BUG-38: genre folders on Home are TMDB DISCOVER-type collections, and
 * [TmdbCollectionSourceResolver.importMetadata] mints no cover for DISCOVER sources (only for
 * COLLECTION/COMPANY/NETWORK/PERSON) — upstream mobile has the same gap, so there is nothing to
 * "restore" here. This object is a tvOS **display-time fallback only**: it resolves the first
 * item's poster/banner from the folder's first resolvable source, using the exact same
 * source-resolution dispatch [FolderDetailRepository] and `HomeRepository`'s collection-hero
 * pipeline use (TMDB / Trakt / addon catalog), so the fallback never diverges from what the
 * folder would actually show once opened.
 *
 * This NEVER persists anything: the result is not written onto [CollectionFolder.coverImageUrl],
 * the folder, the collection, or anything that syncs (`CollectionSyncService`). It is purely an
 * in-memory, per-app-run rendering aid for [FolderTile] in CollectionsUI.swift.
 */
object FolderCoverResolver {
    private val log = Logger.withTag("FolderCoverResolver")
    private val mutex = Mutex()

    // Keyed by folder id + a signature of its resolved sources, so an edit that changes a
    // folder's sources (without changing its id) doesn't keep serving a stale cover. Values are
    // cached even when null (no cover found, or resolution failed/threw — e.g. no TMDB API key)
    // so a folder that can't resolve a cover is only ever attempted once per app run, not retried
    // on every re-render/refocus.
    private val cache = mutableMapOf<String, String?>()

    suspend fun fallbackCoverUrl(folder: CollectionFolder): String? {
        val key = cacheKey(folder)
        mutex.withLock {
            if (cache.containsKey(key)) return cache.getValue(key)
        }
        val resolved = resolve(folder)
        mutex.withLock {
            // A concurrent caller may have raced us to the same key (e.g. the same folder
            // rendered in two rows at once); both resolutions are equivalent for a given
            // signature, so last-writer-wins is harmless.
            //
            // Codex review: a null caused (possibly) by addon manifests that simply haven't
            // finished loading yet is NOT cached — collection rows can render before
            // AddonRepository has its manifests, and AddonsUiState carries no readiness flag to
            // tell "still loading" from "uninstalled". Leaving the key absent lets a later
            // render retry; the retry is cheap (findCollectionCatalog miss, no network).
            if (resolved.cacheable) {
                cache[key] = resolved.url
            }
        }
        return resolved.url
    }

    private fun cacheKey(folder: CollectionFolder): String {
        // Codex review: the key carries every input the RESOLUTION depends on, not just the
        // folder — the active profile, the TMDB language/key presence (discover results are
        // language-dependent), and which installed addon each addon-backed source currently
        // routes through. Reconfiguring an addon, switching profiles, or changing the TMDB
        // language changes the key, so the old entry is simply never consulted again (this
        // cache is per-app-run and tiny; abandoned entries are cheaper than an invalidation
        // fan-in from three repositories).
        val addons = AddonRepository.uiState.value.addons
        val signature = folder.resolvedSources.joinToString("|") { source ->
            val route = source.catalogRouteKey()
            if (source.isTmdb || source.isTrakt) {
                route
            } else {
                val resolvedManifest = source.addonCatalogSource()
                    ?.let { addons.findCollectionCatalog(it)?.addon?.manifestUrl }
                "$route@${resolvedManifest ?: "?"}"
            }
        }
        val tmdb = TmdbSettingsRepository.snapshot()
        val tmdbBit = "${tmdb.language}:${tmdb.apiKey.isNotBlank()}"
        return "${ProfileRepository.activeProfileId}::${folder.id}::$signature::$tmdbBit"
    }

    private class Resolution(val url: String?, val cacheable: Boolean)

    private suspend fun resolve(folder: CollectionFolder): Resolution = withContext(Dispatchers.Default) {
        var resolution = attempt(folder, AddonRepository.uiState.value.addons)
        if (resolution.url == null && !resolution.cacheable) {
            // Codex review (two rounds): collection rows can mount before addon manifests finish
            // loading, and the Swift task is keyed on the folder (unchanged by an addon emission),
            // so the retry must live HERE. Waiting for a merely non-empty addon list is not
            // enough — on a cold launch the repository publishes pending addons with null
            // manifests first. Wait until this folder's addon catalogs actually resolve, or until
            // every enabled addon has its manifest (loading finished — a miss is then genuine).
            // Zero-addon users and permanently failing manifests just ride the bounded timeout
            // (no network involved), and the result stays uncacheable for a later render.
            val wantedCatalogs = folder.resolvedSources
                .filter { source -> !source.isTmdb && !source.isTrakt }
                .mapNotNull { source -> source.addonCatalogSource() }
            val readyAddons = withTimeoutOrNull(ADDON_READY_TIMEOUT_MS) {
                AddonRepository.uiState.first { state ->
                    val addons = state.addons
                    addons.isNotEmpty() && (
                        wantedCatalogs.all { wanted -> addons.findCollectionCatalog(wanted) != null } ||
                            addons.enabledAddons().all { addon -> addon.manifest != null }
                        )
                }.addons
            }
            if (readyAddons != null) {
                resolution = attempt(folder, readyAddons)
            }
        }
        resolution
    }

    private suspend fun attempt(folder: CollectionFolder, addons: List<ManagedAddon>): Resolution {
        var sawUnresolvedAddonCatalog = false
        var sawFailedRequest = false
        for (source in folder.resolvedSources) {
            if (!source.isTmdb && !source.isTrakt) {
                val catalogSource = source.addonCatalogSource()
                if (catalogSource != null && addons.findCollectionCatalog(catalogSource) == null) {
                    sawUnresolvedAddonCatalog = true
                    continue
                }
            }
            val page = runCatching { source.resolveFirstPage(addons) }
                .onFailure { error ->
                    // Expected/common failure: no TMDB API key configured, or a transient network
                    // error. Logged at debug, not warn — this is a best-effort display fallback.
                    // Codex review: a throw makes the whole resolution NON-cacheable, so recovery
                    // (connectivity back, key added) gets retried on a later render instead of
                    // serving a blank cover for the rest of the app run.
                    sawFailedRequest = true
                    log.d(error) { "Fallback cover resolution failed for folder ${folder.id}" }
                }
                .getOrNull()
            val preview = page?.items?.firstOrNull() ?: continue
            val url = preview.poster?.takeIf { it.isNotBlank() }
                ?: preview.banner?.takeIf { it.isNotBlank() }
            if (url != null) return Resolution(url, cacheable = true)
        }
        return Resolution(url = null, cacheable = !sawUnresolvedAddonCatalog && !sawFailedRequest)
    }

    private const val ADDON_READY_TIMEOUT_MS = 10_000L

    // Mirrors HomeRepository's `CollectionSource.resolveCollectionHeroItems` dispatch and
    // FolderDetailRepository.loadTabPage's source-type branch, so the fallback cover always
    // matches what the folder's first tab would actually load.
    private suspend fun CollectionSource.resolveFirstPage(
        addons: List<ManagedAddon>,
    ): CatalogPage? = when {
        isTmdb -> TmdbCollectionSourceResolver.resolve(source = this, page = 1)
        isTrakt -> TraktPublicListSourceResolver.resolve(source = this, page = 1)
        else -> {
            val catalogSource = addonCatalogSource() ?: return null
            val resolvedCatalog = addons.findCollectionCatalog(catalogSource) ?: return null
            fetchCatalogPage(
                manifestUrl = resolvedCatalog.addon.manifestUrl,
                type = catalogSource.type,
                catalogId = catalogSource.catalogId,
                genre = catalogSource.genre,
                maxItems = 1,
            )
        }
    }
}
