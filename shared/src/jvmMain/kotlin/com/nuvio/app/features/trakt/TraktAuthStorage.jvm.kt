package com.nuvio.app.features.trakt

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object TraktAuthStorage {
    private const val preferencesName = "nuvio_trakt_auth"
    private const val payloadKey = "trakt_auth_payload"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadPayload(profileId: Int): String? =
        preferences?.getString(ProfileScopedKey.of(payloadKey, profileId), null)

    actual fun savePayload(profileId: Int, payload: String) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(payloadKey, profileId), payload)
            ?.apply()
    }
}
