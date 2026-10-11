package com.nuvio.app.core.poster

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey
import com.nuvio.app.core.storage.jvmSharedPreferences

actual object CustomPosterUrlStorage {
    private const val preferencesName = "nuvio_custom_poster_url"
    private const val patternKey = "custom_poster_url_pattern"
    private const val enabledScreensKey = "custom_poster_enabled_screens"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadPattern(): String? =
        preferences?.getString(ProfileScopedKey.of(patternKey), null)

    actual fun savePattern(pattern: String?) {
        write(ProfileScopedKey.of(patternKey), pattern?.trim())
    }

    actual fun loadEnabledScreens(): String? =
        preferences?.getString(ProfileScopedKey.of(enabledScreensKey), null)

    actual fun saveEnabledScreens(keys: String?) {
        write(ProfileScopedKey.of(enabledScreensKey), keys)
    }

    private fun write(key: String, value: String?) {
        preferences
            ?.edit()
            ?.putString(key, value?.takeIf(String::isNotBlank))
            ?.apply()
    }
}
