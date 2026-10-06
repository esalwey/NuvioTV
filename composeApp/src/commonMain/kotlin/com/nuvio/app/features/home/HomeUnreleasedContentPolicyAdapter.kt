package com.nuvio.app.features.home

/**
 * Installs the shared [HomeUnreleasedContentPolicyProvider] seam, backed by this app's
 * HomeCatalogSettingsRepository. Keeps the HomeRepository/ProfileRepository god-objects
 * (reached transitively via HomeCatalogSettingsRepository) out of :shared.
 */
object HomeUnreleasedContentPolicyAdapter {
    fun install() {
        HomeUnreleasedContentPolicyProvider.policy = HomeUnreleasedContentPolicy {
            HomeCatalogSettingsRepository.snapshot().hideUnreleasedContent
        }
    }
}
