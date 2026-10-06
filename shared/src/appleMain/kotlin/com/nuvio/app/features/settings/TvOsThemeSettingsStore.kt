package com.nuvio.app.features.settings

import com.nuvio.app.core.storage.ProfileScopedKey
import com.nuvio.app.core.sync.decodeSyncBoolean
import com.nuvio.app.core.sync.decodeSyncString
import com.nuvio.app.core.sync.encodeSyncBoolean
import com.nuvio.app.core.sync.encodeSyncString
import com.nuvio.app.core.ui.AppTheme
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import platform.Foundation.NSUserDefaults

/**
 * tvOS [ThemeSettingsStore] adapter (NSUserDefaults, profile-scoped keys) — a port of composeApp's
 * iOS `ThemeSettingsStorage` actual, so theme/appearance settings persist and ride the profile
 * settings sync (the tvOS blob is platform-scoped via `p_platform = "tv"`).
 *
 * Differences from mobile:
 *  - The default theme is CRIMSON (the tvOS app's launch look), not WHITE.
 *  - `applySelectedAppLanguage` is a no-op — the tvOS app is English-only for now, and we don't
 *    touch the process's AppleLanguages.
 *
 * Installed by [com.nuvio.app.core.bootstrap.installTvOsSharedProviders].
 */
object TvOsThemeSettingsStore : ThemeSettingsStore {
    private const val selectedThemeKey = "selected_theme"
    private const val amoledEnabledKey = "amoled_enabled"
    private const val liquidGlassNativeTabBarEnabledKey = "liquid_glass_native_tab_bar_enabled"
    private const val selectedAppLanguageKey = "selected_app_language"
    private const val navBarStyleKey = "nav_bar_style"
    private val profileScopedSyncKeys = listOf(
        selectedThemeKey,
        amoledEnabledKey,
        liquidGlassNativeTabBarEnabledKey,
        navBarStyleKey,
    )

    override fun loadSelectedTheme(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(ProfileScopedKey.of(selectedThemeKey))
            ?: AppTheme.CRIMSON.name

    override fun saveSelectedTheme(themeName: String) {
        NSUserDefaults.standardUserDefaults.setObject(themeName, forKey = ProfileScopedKey.of(selectedThemeKey))
    }

    override fun loadAmoledEnabled(): Boolean? {
        val defaults = NSUserDefaults.standardUserDefaults
        val key = ProfileScopedKey.of(amoledEnabledKey)
        return if (defaults.objectForKey(key) != null) defaults.boolForKey(key) else null
    }

    override fun saveAmoledEnabled(enabled: Boolean) {
        NSUserDefaults.standardUserDefaults.setBool(enabled, forKey = ProfileScopedKey.of(amoledEnabledKey))
    }

    override fun loadLiquidGlassNativeTabBarEnabled(): Boolean? {
        val defaults = NSUserDefaults.standardUserDefaults
        val key = ProfileScopedKey.of(liquidGlassNativeTabBarEnabledKey)
        return if (defaults.objectForKey(key) != null) defaults.boolForKey(key) else null
    }

    override fun saveLiquidGlassNativeTabBarEnabled(enabled: Boolean) {
        NSUserDefaults.standardUserDefaults.setBool(
            enabled,
            forKey = ProfileScopedKey.of(liquidGlassNativeTabBarEnabledKey),
        )
    }

    override fun loadSelectedAppLanguage(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(selectedAppLanguageKey)

    override fun saveSelectedAppLanguage(languageCode: String) {
        NSUserDefaults.standardUserDefaults.setObject(languageCode, forKey = selectedAppLanguageKey)
    }

    override fun loadNavBarStyle(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(ProfileScopedKey.of(navBarStyleKey))

    override fun saveNavBarStyle(styleKey: String) {
        NSUserDefaults.standardUserDefaults.setObject(styleKey, forKey = ProfileScopedKey.of(navBarStyleKey))
    }

    override fun applySelectedAppLanguage(languageCode: String) {
        // English-only tvOS app — don't rewrite AppleLanguages.
    }

    override fun exportToSyncPayload(): JsonObject = buildJsonObject {
        loadSelectedTheme()?.let { put(selectedThemeKey, encodeSyncString(it)) }
        loadAmoledEnabled()?.let { put(amoledEnabledKey, encodeSyncBoolean(it)) }
        loadLiquidGlassNativeTabBarEnabled()?.let { put(liquidGlassNativeTabBarEnabledKey, encodeSyncBoolean(it)) }
        loadNavBarStyle()?.let { put(navBarStyleKey, encodeSyncString(it)) }
    }

    override fun replaceFromSyncPayload(payload: JsonObject) {
        profileScopedSyncKeys.forEach { key ->
            NSUserDefaults.standardUserDefaults.removeObjectForKey(ProfileScopedKey.of(key))
        }
        payload.decodeSyncString(selectedThemeKey)?.let(::saveSelectedTheme)
        payload.decodeSyncBoolean(amoledEnabledKey)?.let(::saveAmoledEnabled)
        payload.decodeSyncBoolean(liquidGlassNativeTabBarEnabledKey)?.let(::saveLiquidGlassNativeTabBarEnabled)
        payload.decodeSyncString(navBarStyleKey)?.let(::saveNavBarStyle)
    }
}
