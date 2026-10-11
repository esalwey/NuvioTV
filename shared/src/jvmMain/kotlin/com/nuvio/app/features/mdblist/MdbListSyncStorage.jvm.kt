package com.nuvio.app.features.mdblist

// JVM actual for the :shared jvm test target, mirroring the androidMain actual.

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey
import com.nuvio.app.core.storage.jvmSharedPreferences

actual object PlatformMdbListSyncStorage : MdbListSyncStorage {
    private const val preferencesName = "nuvio_mdblist_sync"
    private const val payloadKey = "mdblist_sync_snapshot"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual override suspend fun load(profileId: Int): String? =
        preferences?.getString(ProfileScopedKey.of(payloadKey, profileId), null)

    actual override suspend fun save(profileId: Int, payload: String, checkScope: () -> Unit) {
        checkScope()
        preferences?.edit()?.putString(ProfileScopedKey.of(payloadKey, profileId), payload)?.apply()
    }

    actual override suspend fun remove(profileId: Int, checkScope: () -> Unit) {
        checkScope()
        preferences?.edit()?.remove(ProfileScopedKey.of(payloadKey, profileId))?.apply()
    }

    actual fun clearAll() {
        preferences?.edit()?.clear()?.apply()
    }
}
