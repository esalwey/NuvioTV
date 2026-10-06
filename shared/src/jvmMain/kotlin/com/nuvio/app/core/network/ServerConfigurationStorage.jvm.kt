package com.nuvio.app.core.network

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences

// Fork: public (upstream: internal) so composeApp's MainActivity can call initialize(context).
// NOTE: mirrors upstream ddc28dc8 verbatim apart from the lenient auth guard; not compile-verified
// locally (no Android SDK on the tvOS dev machine).
actual object ServerConfigurationStorage {
    private const val preferencesName = "server_configuration"
    private const val customEnabledKey = "custom_enabled"
    private const val backendUrlKey = "backend_url"
    private const val publishableKey = "publishable_key"
    private const val emailPasswordAuthKey = "email_password_auth"
    private const val tvLoginKey = "tv_login"
    private const val discoveryUrlKey = "discovery_url"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadCustom(): ServerConfiguration? {
        val values = preferences ?: return null
        if (!values.getBoolean(customEnabledKey, false)) return null
        val backendUrl = values.getString(backendUrlKey, null)?.trim().orEmpty()
        val key = values.getString(publishableKey, null)?.trim().orEmpty()
        val emailPasswordAuth = values.getBoolean(emailPasswordAuthKey, false)
        val tvLogin = values.getBoolean(tvLoginKey, false)
        // Fork: a tv_login-only server is valid (TV clients); upstream requires emailPasswordAuth.
        if (backendUrl.isBlank() || key.isBlank() || (!emailPasswordAuth && !tvLogin)) return null
        return ServerConfiguration(
            backendUrl = backendUrl,
            publishableKey = key,
            capabilities = ServerCapabilities(
                emailPasswordAuth = emailPasswordAuth,
                tvLogin = tvLogin,
            ),
            isCustom = true,
            discoveryUrl = values.getString(discoveryUrlKey, null),
        )
    }

    actual fun saveCustom(configuration: ServerConfiguration): Boolean =
        preferences
            ?.edit()
            ?.putBoolean(customEnabledKey, true)
            ?.putString(backendUrlKey, configuration.backendUrl)
            ?.putString(publishableKey, configuration.publishableKey)
            ?.putBoolean(emailPasswordAuthKey, configuration.capabilities.emailPasswordAuth)
            ?.putBoolean(tvLoginKey, configuration.capabilities.tvLogin)
            ?.putString(discoveryUrlKey, configuration.discoveryUrl)
            ?.commit() == true

    actual fun useOfficial(): Boolean = preferences?.edit()?.clear()?.commit() == true
}
