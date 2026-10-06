package com.nuvio.app.features.simkl

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

internal actual object SimklSyncStorage {
    private const val preferencesName = "nuvio_simkl_sync"
    private const val payloadKey = "simkl_sync_snapshot"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadPayload(): String? =
        preferences?.getString(ProfileScopedKey.of(payloadKey), null)

    actual fun savePayload(payload: String) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(payloadKey), payload)
            ?.apply()
    }

    actual fun removeProfile(profileId: Int) {
        preferences
            ?.edit()
            ?.remove(ProfileScopedKey.of(payloadKey, profileId))
            ?.apply()
    }
}
