package com.nuvio.app.features.streams

import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.AddonsUiState
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.plugins.PluginRepositoryItem
import com.nuvio.app.features.plugins.PluginScraper
import com.nuvio.app.features.plugins.PluginsUiState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class StreamSourceAvailabilityTest {
    private fun addon(
        resources: List<AddonResource>,
        enabled: Boolean = true,
        isRefreshing: Boolean = false,
        hasManifest: Boolean = true,
    ) = ManagedAddon(
        manifestUrl = "https://addon.example/${resources.hashCode()}/manifest.json",
        manifest = if (hasManifest) {
            AddonManifest(
                id = "addon",
                name = "Addon",
                description = "",
                version = "1.0.0",
                resources = resources,
                types = listOf("movie", "series"),
                transportUrl = "https://addon.example",
            )
        } else {
            null
        },
        enabled = enabled,
        isRefreshing = isRefreshing,
    )

    private val ttStreams = AddonResource(name = "stream", types = listOf("movie", "series"), idPrefixes = listOf("tt"))

    private fun state(vararg addons: ManagedAddon) = AddonsUiState(addons = addons.toList(), isInitialized = true)

    @Test
    fun unknown_until_the_addon_list_has_loaded_and_manifests_settled() {
        assertNull(addonsCanStream(AddonsUiState(), "movie", "tt1"))
        assertNull(addonsCanStream(state(addon(listOf(ttStreams), isRefreshing = true, hasManifest = false)), "movie", "tt1"))
    }

    @Test
    fun a_matching_stream_resource_can_stream() {
        assertEquals(true, addonsCanStream(state(addon(listOf(ttStreams))), "series", "tt1:1:2"))
    }

    @Test
    fun catalog_only_disabled_or_foreign_prefix_addons_cannot_stream() {
        val catalogOnly = addon(listOf(AddonResource(name = "catalog", types = listOf("movie"))))
        val disabled = addon(listOf(ttStreams), enabled = false)
        val kitsuOnly = addon(listOf(AddonResource(name = "stream", types = listOf("series"), idPrefixes = listOf("kitsu:"))))

        assertEquals(false, addonsCanStream(state(catalogOnly, disabled, kitsuOnly), "movie", "tt1"))
        assertEquals(false, addonsCanStream(state(kitsuOnly), "movie", "kitsu:1"))
    }

    @Test
    fun a_tmdb_id_reaches_tt_only_addons_through_the_remap() {
        assertEquals(true, addonsCanStream(state(addon(listOf(ttStreams))), "movie", "tmdb:550"))
    }

    private fun scraper(types: List<String>) = PluginScraper(
        id = "scraper",
        repositoryUrl = "https://plugins.example/manifest.json",
        name = "Scraper",
        description = "",
        version = "1.0.0",
        filename = "scraper.js",
        supportedTypes = types,
        enabled = true,
        manifestEnabled = true,
        code = "",
    )

    private fun repository(isRefreshing: Boolean) = PluginRepositoryItem(
        manifestUrl = "https://plugins.example/manifest.json",
        name = "Plugins",
        isRefreshing = isRefreshing,
    )

    @Test
    fun an_enabled_scraper_for_the_type_can_stream() {
        assertEquals(true, pluginsCanStream(PluginsUiState(), listOf(scraper(listOf("movie")))))
    }

    @Test
    fun plugins_are_unknown_while_a_repository_is_still_refreshing() {
        val refreshing = PluginsUiState(repositories = listOf(repository(isRefreshing = true)))
        assertNull(pluginsCanStream(refreshing, emptyList()))
    }

    @Test
    fun settled_or_disabled_plugins_without_a_scraper_cannot_stream() {
        val settled = PluginsUiState(repositories = listOf(repository(isRefreshing = false)))
        val disabled = PluginsUiState(pluginsEnabled = false, repositories = listOf(repository(isRefreshing = true)))
        assertEquals(false, pluginsCanStream(settled, emptyList()))
        assertEquals(false, pluginsCanStream(disabled, emptyList()))
        assertEquals(false, pluginsCanStream(PluginsUiState(), emptyList()))
    }
}
