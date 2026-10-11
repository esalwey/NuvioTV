package com.nuvio.app.features.servers

/**
 * Secret-bearing storage for media server connections (the connection list and the access tokens).
 *
 * Apple targets keep it in the Keychain, Android in an AES-GCM blob protected by the Android
 * Keystore. Public (upstream: internal) so the Android host can call its `initialize(context)`.
 */
expect object ServerStorage {
    fun read(key: String): String?
    fun write(key: String, value: String?)
    fun clear()
}
