package com.nuvio.app.features.streams

import android.content.Context
import android.content.SharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

/** Fork (STREAM-INSIGHT): in memory (defaults) until [initialize] runs. */
actual object StreamRankingSettingsStorage {
    private const val preferencesName = "nuvio_stream_ranking_settings"
    private const val preferencesKey = "stream_ranking_preferences"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

    actual fun loadPayload(): String? =
        preferences?.getString(ProfileScopedKey.of(preferencesKey), null)

    actual fun savePayload(payload: String) {
        preferences?.edit()?.putString(ProfileScopedKey.of(preferencesKey), payload)?.apply()
    }

    actual fun clear() {
        preferences?.edit()?.remove(ProfileScopedKey.of(preferencesKey))?.apply()
    }
}
