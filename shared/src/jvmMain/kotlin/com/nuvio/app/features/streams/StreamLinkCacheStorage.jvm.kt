package com.nuvio.app.features.streams

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object StreamLinkCacheStorage {
    private const val preferencesName = "nuvio_stream_link_cache"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadEntry(hashedKey: String): String? =
        preferences?.getString(ProfileScopedKey.of(hashedKey), null)

    actual fun saveEntry(hashedKey: String, payload: String) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(hashedKey), payload)
            ?.apply()
    }

    actual fun removeEntry(hashedKey: String) {
        preferences
            ?.edit()
            ?.remove(ProfileScopedKey.of(hashedKey))
            ?.apply()
    }
}
