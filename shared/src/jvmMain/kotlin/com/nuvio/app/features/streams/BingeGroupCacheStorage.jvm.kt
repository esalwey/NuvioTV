package com.nuvio.app.features.streams

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object BingeGroupCacheStorage {
    private const val preferencesName = "nuvio_binge_group_cache"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun load(hashedKey: String): String? =
        preferences?.getString(ProfileScopedKey.of(hashedKey), null)

    actual fun save(hashedKey: String, value: String) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(hashedKey), value)
            ?.apply()
    }

    actual fun remove(hashedKey: String) {
        preferences
            ?.edit()
            ?.remove(ProfileScopedKey.of(hashedKey))
            ?.apply()
    }
}
