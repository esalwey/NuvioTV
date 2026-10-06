package com.nuvio.app.features.plugins

import kotlin.concurrent.Volatile

/**
 * Compose-free seam for pulling plugin state from the server. The real implementation
 * (PluginRepository) is flavor-bound — its `expect`/`actual` actuals live in distribution-specific
 * source sets (iosAppStore / fullCommonMain / androidPlaystore), so it can't move to `:shared`.
 * SyncManager talks to it only through this interface.
 *
 * Default is a no-op so a target with no adapter installed (e.g. tvOS today, or the App Store
 * flavor where plugins are disabled) still works.
 */
fun interface PluginSyncController {
    suspend fun pullFromServer(profileId: Int)
}

/** Process-wide holder for the active [PluginSyncController]. composeApp installs the real one. */
object PluginSyncProvider {
    @Volatile
    var controller: PluginSyncController = PluginSyncController { }
}
