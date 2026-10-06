package com.nuvio.app.features.streams

import com.nuvio.app.core.storage.ProfileScopedKey
import platform.Foundation.NSUserDefaults

/** Fork (STREAM-INSIGHT): `stream_ranking_preferences_<profile>` in the standard defaults. */
actual object StreamRankingSettingsStorage {
    private const val preferencesKey = "stream_ranking_preferences"

    actual fun loadPayload(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(ProfileScopedKey.of(preferencesKey))

    actual fun savePayload(payload: String) {
        NSUserDefaults.standardUserDefaults.setObject(payload, forKey = ProfileScopedKey.of(preferencesKey))
    }

    actual fun clear() {
        NSUserDefaults.standardUserDefaults.removeObjectForKey(ProfileScopedKey.of(preferencesKey))
    }
}
