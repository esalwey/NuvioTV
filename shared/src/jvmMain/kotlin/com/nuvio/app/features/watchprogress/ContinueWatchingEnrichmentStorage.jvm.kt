package com.nuvio.app.features.watchprogress

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences

actual object ContinueWatchingEnrichmentStorage {
    private const val preferencesName = "nuvio_cw_enrichment"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadPayload(key: String): String? =
        preferences?.getString(key, null)

    actual fun savePayload(key: String, payload: String) {
        preferences
            ?.edit()
            ?.putString(key, payload)
            ?.apply()
    }

    actual fun removePayload(key: String) {
        preferences
            ?.edit()
            ?.remove(key)
            ?.apply()
    }
}
