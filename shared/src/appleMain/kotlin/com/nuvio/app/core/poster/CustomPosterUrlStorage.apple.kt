package com.nuvio.app.core.poster

import com.nuvio.app.core.storage.ProfileScopedKey
import platform.Foundation.NSUserDefaults

actual object CustomPosterUrlStorage {
    private const val patternKey = "custom_poster_url_pattern"
    private const val enabledScreensKey = "custom_poster_enabled_screens"

    actual fun loadPattern(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(ProfileScopedKey.of(patternKey))

    actual fun savePattern(pattern: String?) {
        write(ProfileScopedKey.of(patternKey), pattern?.trim())
    }

    actual fun loadEnabledScreens(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(ProfileScopedKey.of(enabledScreensKey))

    actual fun saveEnabledScreens(keys: String?) {
        write(ProfileScopedKey.of(enabledScreensKey), keys)
    }

    private fun write(key: String, value: String?) {
        val defaults = NSUserDefaults.standardUserDefaults
        if (value.isNullOrBlank()) {
            defaults.removeObjectForKey(key)
        } else {
            defaults.setObject(value, forKey = key)
        }
    }
}
