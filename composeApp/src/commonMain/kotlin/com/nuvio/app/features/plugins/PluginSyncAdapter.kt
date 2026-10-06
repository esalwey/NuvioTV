package com.nuvio.app.features.plugins

/**
 * Installs the flavor-bound [PluginRepository] behind the shared [PluginSyncController] seam so
 * SyncManager (in :shared) can trigger plugin pulls. Call [install] once at app startup.
 */
object PluginSyncAdapter {
    fun install() {
        PluginSyncProvider.controller = PluginSyncController { profileId ->
            PluginRepository.pullFromServer(profileId)
        }
    }
}
