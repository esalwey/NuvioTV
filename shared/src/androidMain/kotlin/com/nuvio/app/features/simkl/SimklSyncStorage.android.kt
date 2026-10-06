package com.nuvio.app.features.simkl

import android.content.Context
import android.content.SharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

internal actual object SimklSyncStorage {
    private const val preferencesName = "nuvio_simkl_sync"
    private const val payloadKey = "simkl_sync_snapshot"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

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
