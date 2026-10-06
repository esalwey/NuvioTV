package com.nuvio.app.features.plugins

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Seam exposing the subset of PluginRepository that :shared consumers (StreamsRepository)
 * need. PluginRepository is an `expect object` with actuals in FLAVOR source sets
 * (iosAppStore/fullCommonMain/androidPlaystore), which :shared has no equivalent of, so it
 * cannot move. The phone app installs an adapter backed by PluginRepository at startup;
 * tvOS leaves the default (plugins disabled, no scrapers).
 */
interface PluginScraperHost {
    val uiState: StateFlow<PluginsUiState>
    fun initialize()
    fun getEnabledScrapersForType(type: String): List<PluginScraper>
    suspend fun executeScraper(
        scraper: PluginScraper,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?,
    ): Result<List<PluginRuntimeResult>>
}

object PluginScraperHostProvider {
    private val defaultState: StateFlow<PluginsUiState> =
        MutableStateFlow(PluginsUiState(pluginsEnabled = false))

    var host: PluginScraperHost = object : PluginScraperHost {
        override val uiState: StateFlow<PluginsUiState> = defaultState
        override fun initialize() {}
        override fun getEnabledScrapersForType(type: String): List<PluginScraper> = emptyList()
        override suspend fun executeScraper(
            scraper: PluginScraper,
            tmdbId: String,
            mediaType: String,
            season: Int?,
            episode: Int?,
        ): Result<List<PluginRuntimeResult>> = Result.success(emptyList())
    }
}
