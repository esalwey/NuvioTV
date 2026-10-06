package com.nuvio.app.core.sync

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences

actual object SyncClientIdentityStorage {
    private const val preferencesName = "nuvio_sync_client_identity"
    private const val clientIdKey = "client_instance_id"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadClientId(): String? =
        preferences?.getString(clientIdKey, null)

    actual fun saveClientId(clientId: String) {
        preferences
            ?.edit()
            ?.putString(clientIdKey, clientId)
            ?.apply()
    }
}
