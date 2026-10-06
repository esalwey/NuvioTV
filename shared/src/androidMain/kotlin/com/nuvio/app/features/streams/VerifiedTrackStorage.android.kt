package com.nuvio.app.features.streams

import android.content.Context
import android.content.SharedPreferences

/** Fork (VERIFIED-LANGUAGES): in memory until [initialize] runs. */
actual object VerifiedTrackStorage {
    private const val preferencesName = "nuvio_verified_tracks"
    private const val preferencesKey = "verified_tracks"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

    actual fun loadPayload(): String? = preferences?.getString(preferencesKey, null)

    actual fun savePayload(payload: String) {
        preferences?.edit()?.putString(preferencesKey, payload)?.apply()
    }

    actual fun clear() {
        preferences?.edit()?.remove(preferencesKey)?.apply()
    }
}
