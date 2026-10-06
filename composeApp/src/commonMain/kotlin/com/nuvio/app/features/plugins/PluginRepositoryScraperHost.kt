package com.nuvio.app.features.plugins

import kotlinx.coroutines.flow.StateFlow

/**
 * Installs the shared [PluginScraperHostProvider] seam, backed by this app's flavor-bound
 * [PluginRepository] `expect object`. Keeps PluginRepository (whose actuals live in flavor
 * source sets) out of :shared.
 */
object PluginRepositoryScraperHost : PluginScraperHost {
    override val uiState: StateFlow<PluginsUiState>
        get() = PluginRepository.uiState

    override fun initialize() = PluginRepository.initialize()

    override fun getEnabledScrapersForType(type: String): List<PluginScraper> =
        PluginRepository.getEnabledScrapersForType(type)

    override suspend fun executeScraper(
        scraper: PluginScraper,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?,
    ): Result<List<PluginRuntimeResult>> =
        PluginRepository.executeScraper(scraper, tmdbId, mediaType, season, episode)

    fun install() {
        PluginScraperHostProvider.host = this
    }
}
