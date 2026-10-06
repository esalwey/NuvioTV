package com.nuvio.app.core.network

/**
 * Persisted custom-server selection (device/install configuration — deliberately NOT part of the
 * sign-out wipe, see `core.account.AccountDataStores`).
 */
// Fork: public (upstream: internal) — composeApp's Android MainActivity calls the android actual's
// initialize(context) across the module boundary.
expect object ServerConfigurationStorage {
    fun loadCustom(): ServerConfiguration?
    fun saveCustom(configuration: ServerConfiguration): Boolean
    fun useOfficial(): Boolean
}
