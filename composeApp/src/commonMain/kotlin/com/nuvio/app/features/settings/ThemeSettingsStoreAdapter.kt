package com.nuvio.app.features.settings

import kotlinx.serialization.json.JsonObject

/** Installs the composeApp [ThemeSettingsStorage] behind the shared [ThemeSettingsStore] seam. */
object ThemeSettingsStoreAdapter {
    fun install() {
        ThemeSettingsStoreProvider.store = object : ThemeSettingsStore {
            override fun loadSelectedTheme(): String? = ThemeSettingsStorage.loadSelectedTheme()
            override fun saveSelectedTheme(themeName: String) = ThemeSettingsStorage.saveSelectedTheme(themeName)
            override fun loadAmoledEnabled(): Boolean? = ThemeSettingsStorage.loadAmoledEnabled()
            override fun saveAmoledEnabled(enabled: Boolean) = ThemeSettingsStorage.saveAmoledEnabled(enabled)
            override fun loadLiquidGlassNativeTabBarEnabled(): Boolean? = ThemeSettingsStorage.loadLiquidGlassNativeTabBarEnabled()
            override fun saveLiquidGlassNativeTabBarEnabled(enabled: Boolean) = ThemeSettingsStorage.saveLiquidGlassNativeTabBarEnabled(enabled)
            override fun loadSelectedAppLanguage(): String? = ThemeSettingsStorage.loadSelectedAppLanguage()
            override fun saveSelectedAppLanguage(languageCode: String) = ThemeSettingsStorage.saveSelectedAppLanguage(languageCode)
            override fun applySelectedAppLanguage(languageCode: String) = ThemeSettingsStorage.applySelectedAppLanguage(languageCode)
            override fun loadNavBarStyle(): String? = ThemeSettingsStorage.loadNavBarStyle()
            override fun saveNavBarStyle(styleKey: String) = ThemeSettingsStorage.saveNavBarStyle(styleKey)
            override fun exportToSyncPayload(): JsonObject = ThemeSettingsStorage.exportToSyncPayload()
            override fun replaceFromSyncPayload(payload: JsonObject) = ThemeSettingsStorage.replaceFromSyncPayload(payload)
        }
    }
}
