package com.nuvio.app.features.streams

// JVM actual (test target only), same key layout as the Android actual.

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey
import com.nuvio.app.core.storage.jvmSharedPreferences

actual object StreamRankingSettingsStorage {
    private const val preferencesName = "nuvio_stream_ranking_settings"
    private const val preferencesKey = "stream_ranking_preferences"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadPayload(): String? =
        preferences?.getString(ProfileScopedKey.of(preferencesKey), null)

    actual fun savePayload(payload: String) {
        preferences?.edit()?.putString(ProfileScopedKey.of(preferencesKey), payload)?.apply()
    }

    actual fun clear() {
        preferences?.edit()?.remove(ProfileScopedKey.of(preferencesKey))?.apply()
    }
}
