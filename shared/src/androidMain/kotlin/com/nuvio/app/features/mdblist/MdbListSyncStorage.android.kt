package com.nuvio.app.features.mdblist

import android.content.Context
import android.content.SharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object PlatformMdbListSyncStorage : MdbListSyncStorage {
    private const val preferencesName = "nuvio_mdblist_sync"
    private const val payloadKey = "mdblist_sync_snapshot"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.applicationContext.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

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
