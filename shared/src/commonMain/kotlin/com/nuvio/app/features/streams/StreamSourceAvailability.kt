package com.nuvio.app.features.streams

import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.AddonsUiState
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.hasPendingEnabledManifests
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.plugins.PluginScraper
import com.nuvio.app.features.plugins.PluginScraperHostProvider
import com.nuvio.app.features.plugins.PluginsUiState

/**
 * Upstream 972109f9 ("disable play when no source is available"), tvOS port: whether any
 * configured source could return a stream for a title, so the details page can grey its Play
 * button out instead of opening a stream list that can only report "no compatible add-on".
 *
 * Deliberately conservative — Play is only disabled when that is CERTAIN: while the add-on list
 * has not loaded or a manifest is still fetching, the answer is "yes". Mirrors what
 * `StreamsRepository.load` fans out to: stream add-ons (with BUG-74's tmdb → IMDb remap), plugin
 * scrapers, and streams embedded in the title's meta.
 */
object StreamSourceAvailability {
    fun canStream(type: String, videoId: String): Boolean {
        if (addonsCanStream(AddonRepository.uiState.value, type, videoId) != false) return true
        if (FeaturePolicyProvider.policy.pluginsEnabled) {
            val host = PluginScraperHostProvider.host
            // First: the lookup initializes the plugin store, which may start a refresh.
            val scrapers = host.getEnabledScrapersForType(type)
            if (pluginsCanStream(host.uiState.value, scrapers) != false) return true
        }
        return MetaDetailsRepository.findEmbeddedStreams(videoId).isNotEmpty()
    }
}

/**
 * Whether the plugin scrapers could serve a title: true when an enabled scraper covers its type
 * ([enabledScrapersForType]). Null while that is not known yet — a plugin repository is still
 * refreshing (one just synced from the phone has no scrapers until its manifest arrives).
 */
fun pluginsCanStream(state: PluginsUiState, enabledScrapersForType: List<PluginScraper>): Boolean? {
    if (enabledScrapersForType.isNotEmpty()) return true
    if (state.pluginsEnabled && state.repositories.any { repository -> repository.isRefreshing }) return null
    return false
}

/**
 * Whether an enabled add-on declares a `stream` resource for [type] that accepts [videoId] — or,
 * for a `tmdb:` id, the IMDb id `StreamsRepository` remaps it to (BUG-74). Null while that is not
 * known yet: the add-on list has not loaded, or an enabled add-on's manifest is still fetching.
 */
fun addonsCanStream(state: AddonsUiState, type: String, videoId: String): Boolean? {
    if (!state.isInitialized) return null
    val enabled = state.addons.enabledAddons()
    if (enabled.hasPendingEnabledManifests()) return null
    val streamResources = enabled.flatMap { addon ->
        addon.manifest?.resources.orEmpty().filter { resource ->
            resource.name == "stream" && resource.types.contains(type)
        }
    }
    if (streamResources.any { resource -> StreamVideoIdRemap.accepts(resource.idPrefixes, videoId) }) return true
    // Any `tt`-shaped probe answers like a real IMDb id: `accepts` only compares prefixes.
    return StreamVideoIdRemap.parseTmdbId(videoId) != null &&
        streamResources.any { resource -> StreamVideoIdRemap.accepts(resource.idPrefixes, "tt0000000") }
}
