package com.nuvio.app.features.watchprogress

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences

actual object WatchProgressStorage {
    private const val preferencesName = "nuvio_watch_progress"
    private const val payloadKey = "watch_progress_payload"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadPayload(profileId: Int): String? =
        preferences?.getString("${payloadKey}_$profileId", null)

    actual fun savePayload(profileId: Int, payload: String) {
        preferences
            ?.edit()
            ?.putString("${payloadKey}_$profileId", payload)
            ?.apply()
    }
}
