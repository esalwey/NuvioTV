package com.nuvio.app.core.poster

import android.content.Context
import android.content.SharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object CustomPosterUrlStorage {
    private const val preferencesName = "nuvio_custom_poster_url"
    private const val patternKey = "custom_poster_url_pattern"
    private const val enabledScreensKey = "custom_poster_enabled_screens"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

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
            ?.apply {
                if (value.isNullOrBlank()) remove(key) else putString(key, value)
            }
            ?.apply()
    }
}
