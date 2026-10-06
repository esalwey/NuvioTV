package com.nuvio.app.features.streams

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences

// JVM actual (test target only), same layout as the Android one.
actual object VerifiedTrackStorage {
    private const val preferencesKey = "verified_tracks"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences("nuvio_verified_tracks")

    actual fun loadPayload(): String? = preferences?.getString(preferencesKey, null)

    actual fun savePayload(payload: String) {
        preferences?.edit()?.putString(preferencesKey, payload)?.apply()
    }

    actual fun clear() {
        preferences?.edit()?.remove(preferencesKey)?.apply()
    }
}
