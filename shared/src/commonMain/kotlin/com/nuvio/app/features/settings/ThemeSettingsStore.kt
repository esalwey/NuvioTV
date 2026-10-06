package com.nuvio.app.features.settings

import kotlinx.serialization.json.JsonObject
import kotlin.concurrent.Volatile

/**
 * Compose-free seam over the platform [ThemeSettingsStorage] (which stays in composeApp because its
 * Android actual depends on androidx.appcompat for runtime locale switching). ThemeSettingsRepository
 * and ProfileSettingsSync talk to persisted theme/appearance settings through this interface.
 *
 * Default is a no-op (settings don't persist), so a target with no adapter installed — e.g. tvOS
 * today — still works on defaults.
 */
interface ThemeSettingsStore {
    fun loadSelectedTheme(): String?
    fun saveSelectedTheme(themeName: String)
    fun loadAmoledEnabled(): Boolean?
    fun saveAmoledEnabled(enabled: Boolean)
    fun loadLiquidGlassNativeTabBarEnabled(): Boolean?
    fun saveLiquidGlassNativeTabBarEnabled(enabled: Boolean)
    fun loadSelectedAppLanguage(): String?
    fun saveSelectedAppLanguage(languageCode: String)
    fun applySelectedAppLanguage(languageCode: String)
    fun loadNavBarStyle(): String?
    fun saveNavBarStyle(styleKey: String)
    fun exportToSyncPayload(): JsonObject
    fun replaceFromSyncPayload(payload: JsonObject)
}

/** Process-wide holder for the active [ThemeSettingsStore]. composeApp installs the real one. */
object ThemeSettingsStoreProvider {
    @Volatile
    var store: ThemeSettingsStore = NoOpThemeSettingsStore
}

private object NoOpThemeSettingsStore : ThemeSettingsStore {
    override fun loadSelectedTheme(): String? = null
    override fun saveSelectedTheme(themeName: String) {}
    override fun loadAmoledEnabled(): Boolean? = null
    override fun saveAmoledEnabled(enabled: Boolean) {}
    override fun loadLiquidGlassNativeTabBarEnabled(): Boolean? = null
    override fun saveLiquidGlassNativeTabBarEnabled(enabled: Boolean) {}
    override fun loadNavBarStyle(): String? = null
    override fun saveNavBarStyle(styleKey: String) {}
    override fun loadSelectedAppLanguage(): String? = null
    override fun saveSelectedAppLanguage(languageCode: String) {}
    override fun applySelectedAppLanguage(languageCode: String) {}
    override fun exportToSyncPayload(): JsonObject = JsonObject(emptyMap())
    override fun replaceFromSyncPayload(payload: JsonObject) {}
}
