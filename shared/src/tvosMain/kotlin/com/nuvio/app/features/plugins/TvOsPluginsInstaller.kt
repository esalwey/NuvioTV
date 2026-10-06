package com.nuvio.app.features.plugins

import com.nuvio.app.core.bootstrap.TvOsExtraLifecycleHooks
import com.nuvio.app.core.build.FeaturePolicy
import com.nuvio.app.core.build.FeaturePolicyProvider
import kotlinx.coroutines.flow.StateFlow

/**
 * Wires the tvOS plugin stack into the shared seams. Swift calls [installTvOsPlugins] once at
 * startup, right after `installTvOsSharedProviders()`.
 *
 * - [PluginScraperHostProvider]: StreamsRepository/PlayerStreamsRepository ask the host for
 *   enabled scrapers and execute them — installing this makes plugin streams appear with ZERO
 *   player/stream-picker changes.
 * - [PluginSyncProvider]: SyncManager.pullAllForProfile already calls
 *   `PluginSyncProvider.controller.pullFromServer` — installing this makes plugin repos synced
 *   from the mobile app arrive automatically.
 * - [TvOsExtraLifecycleHooks]: profile switches and sign-out wipes reach the (tvosMain-only)
 *   PluginRepository, which appleMain's coordinator/cleaner can't reference directly.
 */
object TvOsPluginScraperHost : PluginScraperHost {
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
}

fun installTvOsPlugins() {
    // StreamsRepository gates every plugin call on FeaturePolicyProvider.policy.pluginsEnabled,
    // and tvOS otherwise runs DefaultFeaturePolicy (pluginsEnabled = false). Wrap the current
    // policy so only that flag flips and future default changes still flow through.
    val base = FeaturePolicyProvider.policy
    FeaturePolicyProvider.policy = object : FeaturePolicy by base {
        override val pluginsEnabled: Boolean = true
    }

    PluginScraperHostProvider.host = TvOsPluginScraperHost
    PluginSyncProvider.controller = PluginSyncController { profileId ->
        PluginRepository.pullFromServer(profileId)
    }
    TvOsExtraLifecycleHooks.onProfileChanged = { profileIndex ->
        PluginRepository.onProfileChanged(profileIndex)
    }
    TvOsExtraLifecycleHooks.onClearLocalState = {
        PluginRepository.clearLocalState()
    }
}
