package com.nuvio.app.features.simkl

import android.content.Context
import android.content.SharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object SimklAuthStorage {
    private const val preferencesName = "nuvio_simkl_auth"
    private const val payloadKey = "simkl_auth_payload"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

    actual fun loadPayload(profileId: Int): String? =
        preferences?.getString(ProfileScopedKey.of(payloadKey, profileId), null)

    actual fun savePayload(profileId: Int, payload: String) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(payloadKey, profileId), payload)
            ?.apply()
    }

    actual fun removeProfile(profileId: Int) {
        preferences
            ?.edit()
            ?.remove(ProfileScopedKey.of(payloadKey, profileId))
            ?.apply()
    }
}
