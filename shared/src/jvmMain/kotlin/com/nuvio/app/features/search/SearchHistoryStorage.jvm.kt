package com.nuvio.app.features.search

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object SearchHistoryStorage {
    private const val preferencesName = "nuvio_search_history"
    private const val payloadKey = "search_history_payload"
    private const val enabledKey = "recent_searches_enabled"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadPayload(): String? =
        preferences?.getString(ProfileScopedKey.of(payloadKey), null)

    actual fun savePayload(payload: String) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(payloadKey), payload)
            ?.apply()
    }

    actual fun loadEnabled(): Boolean? {
        val key = ProfileScopedKey.of(enabledKey)
        val prefs = preferences ?: return null
        return if (prefs.contains(key)) prefs.getBoolean(key, true) else null
    }

    actual fun saveEnabled(enabled: Boolean) {
        preferences
            ?.edit()
            ?.putBoolean(ProfileScopedKey.of(enabledKey), enabled)
            ?.apply()
    }
}
