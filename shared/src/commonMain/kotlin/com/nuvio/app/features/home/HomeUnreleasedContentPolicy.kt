package com.nuvio.app.features.home

/**
 * Seam exposing only the single "hide unreleased content" preference that :shared
 * consumers (e.g. MetaDetailsRepository) need, without pulling in the
 * HomeCatalogSettingsRepository god-object (which hard-calls HomeRepository +
 * ProfileRepository, both last-migrating aggregators).
 *
 * The phone app installs a policy backed by HomeCatalogSettingsRepository at startup;
 * tvOS leaves the default (do not hide).
 */
fun interface HomeUnreleasedContentPolicy {
    fun hideUnreleasedContent(): Boolean
}

object HomeUnreleasedContentPolicyProvider {
    var policy: HomeUnreleasedContentPolicy = HomeUnreleasedContentPolicy { false }
}
