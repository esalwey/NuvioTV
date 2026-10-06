package com.nuvio.app.core.network

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import platform.Foundation.NSUserDefaults

/**
 * One versioned JSON blob under a single defaults key — NSUserDefaults has no multi-key
 * transaction, so the earlier split-key shape could tear on a crash mid-replace and hand the next
 * launch a hybrid configuration (server B's URL with server A's publishable key). A single
 * `setObject` replaces the record atomically. No migration: this storage never shipped in a beta
 * (Wave 11 is unreleased), so no install holds the split keys. (Codex round 4.)
 *
 * Bounded, tiny payload — safe for defaults (not the PayloadFileStore class of unbounded data).
 */
@Serializable
private data class StoredServerConfiguration(
    // No default: always encoded on save, required on load — a record without (or with an
    // unsupported) version must be rejected, not silently misread. (Codex round 5.)
    val version: Int,
    val backendUrl: String,
    val publishableKey: String,
    val emailPasswordAuth: Boolean,
    val tvLogin: Boolean,
    val discoveryUrl: String? = null,
)

internal const val SERVER_CONFIG_SCHEMA_VERSION = 1

actual object ServerConfigurationStorage {
    private const val configKey = "server_custom_config"
    private val json = Json { ignoreUnknownKeys = true }

    actual fun loadCustom(): ServerConfiguration? {
        val payload = NSUserDefaults.standardUserDefaults.stringForKey(configKey) ?: return null
        // TV-lenient load guard: any unreadable/incomplete record falls back to the official
        // backend (repository substitutes officialConfiguration()) instead of failing boot.
        val stored = runCatching { json.decodeFromString<StoredServerConfiguration>(payload) }
            .getOrNull() ?: return null
        if (stored.version != SERVER_CONFIG_SCHEMA_VERSION) return null
        val backendUrl = stored.backendUrl.trim()
        val key = stored.publishableKey.trim()
        // Fork: a tv_login-only server is valid on tvOS (upstream requires emailPasswordAuth).
        if (backendUrl.isBlank() || key.isBlank() || (!stored.emailPasswordAuth && !stored.tvLogin)) return null
        return ServerConfiguration(
            backendUrl = backendUrl,
            publishableKey = key,
            capabilities = ServerCapabilities(
                emailPasswordAuth = stored.emailPasswordAuth,
                tvLogin = stored.tvLogin,
            ),
            isCustom = true,
            discoveryUrl = stored.discoveryUrl,
        )
    }

    actual fun saveCustom(configuration: ServerConfiguration): Boolean {
        val values = NSUserDefaults.standardUserDefaults
        val payload = json.encodeToString(
            StoredServerConfiguration.serializer(),
            StoredServerConfiguration(
                version = SERVER_CONFIG_SCHEMA_VERSION,
                backendUrl = configuration.backendUrl,
                publishableKey = configuration.publishableKey,
                emailPasswordAuth = configuration.capabilities.emailPasswordAuth,
                tvLogin = configuration.capabilities.tvLogin,
                discoveryUrl = configuration.discoveryUrl,
            ),
        )
        values.setObject(payload, forKey = configKey)
        return values.synchronize()
    }

    actual fun useOfficial(): Boolean {
        val values = NSUserDefaults.standardUserDefaults
        values.removeObjectForKey(configKey)
        return values.synchronize()
    }
}
