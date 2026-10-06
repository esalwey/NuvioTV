package com.nuvio.app.features.watchprogress

import kotlin.concurrent.Volatile

/**
 * Compose-free seam resolving a cloud-library poster fallback URL for a watch-progress entry,
 * without [WatchProgressModels] importing `features.cloud.*` (which depends on the unmigrated
 * debrid layer). The phone app installs a resolver backed by `cloudLibraryProviderPosterUrl`
 * + `CloudLibraryContentType` at startup; tvOS leaves the default (returns null).
 */
fun interface CloudPosterResolver {
    fun resolve(
        contentType: String?,
        parentMetaType: String?,
        parentMetaId: String?,
        providerAddonId: String?,
    ): String?
}

object CloudPosterProvider {
    @Volatile
    var resolver: CloudPosterResolver = CloudPosterResolver { _, _, _, _ -> null }
}
