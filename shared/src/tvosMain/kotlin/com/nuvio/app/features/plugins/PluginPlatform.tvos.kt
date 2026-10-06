package com.nuvio.app.features.plugins

import platform.Foundation.NSUserDefaults
import platform.Foundation.timeIntervalSince1970

internal object PluginStorage {
    private const val pluginsStateKey = "plugins_state"

    // Plugin state lives in files (see PluginStateFiles): the payload embeds scraper JS and
    // CFPreferences kills the app past ~4 MB of defaults. The defaults key is legacy-only,
    // migrated on load and removed on every save.
    fun loadState(profileId: Int): String? {
        PluginStateFiles.read(profileId)?.let { return it }
        val defaults = NSUserDefaults.standardUserDefaults
        val legacyKey = "${pluginsStateKey}_$profileId"
        val legacy = defaults.stringForKey(legacyKey) ?: return null
        PluginStateFiles.write(profileId, legacy)
        defaults.removeObjectForKey(legacyKey)
        return legacy
    }

    fun saveState(profileId: Int, payload: String) {
        PluginStateFiles.write(profileId, payload)
        NSUserDefaults.standardUserDefaults.removeObjectForKey("${pluginsStateKey}_$profileId")
    }

    fun loadScraperSettings(scraperId: String): String? =
        NSUserDefaults.standardUserDefaults.stringForKey("settings_${scraperId}")

    fun saveScraperSettings(scraperId: String, payload: String) {
        NSUserDefaults.standardUserDefaults.setObject(
            payload,
            forKey = "settings_${scraperId}",
        )
    }
}

// Deliberately "ios", not "tvos": plugin manifests gate scrapers via supportedPlatforms /
// disabledPlatforms lists that only know "android"/"ios" — reporting "tvos" would filter out
// every scraper. The tvOS runtime is API-identical to the iOS one (QuickJS + same bridges).
internal fun currentPluginPlatform(): String = "ios"

internal fun currentEpochMillis(): Long =
    (platform.Foundation.NSDate().timeIntervalSince1970 * 1000.0).toLong()
