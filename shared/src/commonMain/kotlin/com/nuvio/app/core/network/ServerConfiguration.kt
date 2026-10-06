package com.nuvio.app.core.network

import com.nuvio.app.core.build.FeaturePolicyProvider
import io.ktor.http.Url
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Where the TV QR sign-in sends the phone when the OFFICIAL backend is active (the site hosts the
 * approve page; the session code rides the URL). Mirrors the Android TV app's
 * TV_LOGIN_WEB_BASE_URL default. Custom servers derive theirs from the backend origin — see
 * [ServerConfiguration.tvLoginWebBaseUrl].
 */
// Fork: moved here from TvLoginRepository so the active server owns the redirect base.
const val OFFICIAL_TV_LOGIN_WEB_BASE_URL = "https://nuvio.tv/tv-login"

data class ServerCapabilities(
    val emailPasswordAuth: Boolean,
    val tvLogin: Boolean,
)

data class ServerConfiguration(
    val backendUrl: String,
    val publishableKey: String,
    val capabilities: ServerCapabilities,
    val isCustom: Boolean,
    val discoveryUrl: String? = null,
    val fallbackBackendUrl: String? = null,
) {
    val isSecure: Boolean
        get() = backendUrl.startsWith("https://", ignoreCase = true)

    val isPublicHost: Boolean
        get() = isPublicServerHost(backendUrl)

    /**
     * Base URL the TV login RPC is told to build its approval web URL from (`p_redirect_base_url`).
     * Official backend → the hosted nuvio.tv page; a self-hosted server is expected to serve its
     * own approve page at `<backend>/tv-login` (mirrors NuvioMedia/NuvioTV's
     * ServerConfigurationStore, which does exactly this).
     */
    // Fork: upstream cmp-rewrite has no TV login; this mirrors the Android TV app.
    val tvLoginWebBaseUrl: String
        get() = if (isCustom) "$backendUrl/tv-login" else OFFICIAL_TV_LOGIN_WEB_BASE_URL

    /** `host` (plus `:port` when non-default) for UI labels; falls back to the raw URL if unparsable. */
    // Fork: tvOS Settings/Welcome surface the active server by host.
    val displayHost: String
        get() {
            // Ktor parses a scheme-less string as a RELATIVE url (host "localhost"), so require an
            // explicit scheme before trusting the parse.
            if (!backendUrl.contains("://")) return backendUrl
            val parsed = runCatching { Url(backendUrl) }.getOrNull() ?: return backendUrl
            if (parsed.host.isBlank()) return backendUrl
            val host = if (':' in parsed.host) "[${parsed.host}]" else parsed.host
            val port = if (parsed.port == parsed.protocol.defaultPort) "" else ":${parsed.port}"
            return "$host$port"
        }
}

/**
 * The active backend. [active] is read by SupabaseProvider/SupabaseEndpointConfig/etc. at call
 * time, so switching servers takes effect on the next client creation (see SupabaseProvider.reset()).
 *
 * The custom-server gate (`FeaturePolicyProvider.policy.customServerConnectionsEnabled`) is read at
 * CALL time — never cached — but the initial load happens on first access of this object, so a
 * frontend that flips the flag (tvOS: installTvOsSharedProviders; composeApp: AppFeaturePolicyAdapter)
 * MUST install its policy before anything touches this repository or SupabaseProvider.client,
 * otherwise a saved custom server is silently ignored until the next launch.
 */
object ServerConfigurationRepository {
    private val _active = MutableStateFlow(loadActiveConfiguration())
    val active: StateFlow<ServerConfiguration> = _active.asStateFlow()

    fun saveCustom(configuration: ServerConfiguration): Boolean {
        // Fork: shared/ reads the FeaturePolicy seam instead of composeApp's AppFeaturePolicy.
        if (!FeaturePolicyProvider.policy.customServerConnectionsEnabled) return false
        if (!ServerConfigurationStorage.saveCustom(configuration)) return false
        _active.value = configuration
        return true
    }

    fun useOfficial(): Boolean {
        if (!ServerConfigurationStorage.useOfficial()) return false
        _active.value = officialConfiguration()
        return true
    }

    private fun loadActiveConfiguration(): ServerConfiguration {
        if (!FeaturePolicyProvider.policy.customServerConnectionsEnabled) return officialConfiguration()
        return ServerConfigurationStorage.loadCustom() ?: officialConfiguration()
    }
}

internal fun officialConfiguration() = ServerConfiguration(
    backendUrl = SupabaseConfig.URL.trim().trimEnd('/'),
    publishableKey = SupabaseConfig.ANON_KEY.trim(),
    capabilities = ServerCapabilities(
        emailPasswordAuth = true,
        tvLogin = true,
    ),
    isCustom = false,
    fallbackBackendUrl = SupabaseConfig.FALLBACK_URL.trim().trimEnd('/').takeIf { it.isNotBlank() },
)

internal fun isPublicServerHost(url: String): Boolean {
    val host = runCatching { Url(url).host.lowercase() }.getOrNull() ?: return true
    if (host == "localhost" || host.endsWith(".local") || host == "::1") return false
    if (host.startsWith("127.") || host.startsWith("10.") || host.startsWith("192.168.")) return false
    val parts = host.split('.')
    if (parts.size == 4) {
        val first = parts[0].toIntOrNull()
        val second = parts[1].toIntOrNull()
        if (first == 172 && second != null && second in 16..31) return false
        if (first == 169 && second == 254) return false
    }
    return true
}
