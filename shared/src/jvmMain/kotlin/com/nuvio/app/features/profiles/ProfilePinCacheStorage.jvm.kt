package com.nuvio.app.features.profiles

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences

actual object ProfilePinCacheStorage {
    private const val preferencesName = "nuvio_profile_pin_cache"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadPayload(profileIndex: Int): String? =
        preferences?.getString(payloadKey(profileIndex), null)

    actual fun savePayload(profileIndex: Int, payload: String) {
        preferences
            ?.edit()
            ?.putString(payloadKey(profileIndex), payload)
            ?.apply()
    }

    actual fun removePayload(profileIndex: Int) {
        preferences
            ?.edit()
            ?.remove(payloadKey(profileIndex))
            ?.apply()
    }

    private fun payloadKey(profileIndex: Int): String = "profile_pin_cache_$profileIndex"
}