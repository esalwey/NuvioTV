package com.nuvio.app.features.settings

import com.nuvio.app.core.ui.AppTheme
import com.nuvio.app.core.ui.CustomThemeColors
import kotlinx.serialization.json.JsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ThemeSettingsRepositoryTest {

    private class MemoryStore : ThemeSettingsStore {
        var theme: String? = null
        var custom: String? = null
        var language: String? = null
        var appliedLanguage: String? = null
        override fun loadSelectedTheme() = theme
        override fun saveSelectedTheme(themeName: String) { theme = themeName }
        override fun loadCustomThemeColors() = custom
        override fun saveCustomThemeColors(colors: String) { custom = colors }
        override fun loadAmoledEnabled(): Boolean? = null
        override fun saveAmoledEnabled(enabled: Boolean) {}
        override fun loadLiquidGlassNativeTabBarEnabled(): Boolean? = null
        override fun saveLiquidGlassNativeTabBarEnabled(enabled: Boolean) {}
        override fun loadSelectedAppLanguage() = language
        override fun saveSelectedAppLanguage(languageCode: String) { language = languageCode }
        override fun applySelectedAppLanguage(languageCode: String) { appliedLanguage = languageCode }
        override fun loadNavBarStyle(): String? = null
        override fun saveNavBarStyle(styleKey: String) {}
        override fun exportToSyncPayload() = JsonObject(emptyMap())
        override fun replaceFromSyncPayload(payload: JsonObject) {}
    }

    private lateinit var store: MemoryStore
    private lateinit var previous: ThemeSettingsStore

    @BeforeTest
    fun install() {
        previous = ThemeSettingsStoreProvider.store
        store = MemoryStore()
        ThemeSettingsStoreProvider.store = store
        ThemeSettingsRepository.clearLocalState()
    }

    @AfterTest
    fun restore() {
        ThemeSettingsRepository.clearLocalState()
        ThemeSettingsStoreProvider.store = previous
    }

    @Test
    fun unknownStoredThemeFallsBackWithoutCrashing() {
        store.theme = "NOT_A_THEME"
        ThemeSettingsRepository.ensureLoaded()
        assertEquals(AppTheme.WHITE.name, ThemeSettingsRepository.currentThemeKey())
    }

    @Test
    fun newBuiltInThemesPersistByName() {
        ThemeSettingsRepository.ensureLoaded()
        ThemeSettingsRepository.setTheme(AppTheme.ROSE_GOLD)
        assertEquals("ROSE_GOLD", store.theme)
        assertEquals("ROSE_GOLD", ThemeSettingsRepository.currentThemeKey())
    }

    @Test
    fun customHexSelectsCustomAndPersists() {
        ThemeSettingsRepository.ensureLoaded()
        assertTrue(ThemeSettingsRepository.setCustomThemeHex("#2255aa"))
        assertEquals("CUSTOM", store.theme)
        assertEquals(CustomThemeColors.solid(0x2255AA).encode(), store.custom)
        assertEquals("#2255AA", ThemeSettingsRepository.currentCustomThemeHex())
        assertTrue(ThemeSettingsRepository.currentThemeKey().startsWith("CUSTOM:2255AA:"))
    }

    @Test
    fun invalidCustomHexChangesNothing() {
        ThemeSettingsRepository.ensureLoaded()
        assertFalse(ThemeSettingsRepository.setCustomThemeHex("zzz"))
        assertEquals(null, store.custom)
        assertEquals(null, store.theme)
    }

    @Test
    fun editingCustomColorChangesTheKeyEvenWhenAlreadyCustom() {
        ThemeSettingsRepository.ensureLoaded()
        ThemeSettingsRepository.setCustomThemeHex("#2255AA")
        val first = ThemeSettingsRepository.currentThemeKey()
        ThemeSettingsRepository.setCustomThemeHex("#AA5522")
        assertTrue(first != ThemeSettingsRepository.currentThemeKey())
    }

    @Test
    fun customColorsReloadFromDisk() {
        store.theme = "CUSTOM"
        store.custom = CustomThemeColors.solid(0x112233).encode()
        ThemeSettingsRepository.ensureLoaded()
        assertEquals("#112233", ThemeSettingsRepository.currentCustomThemeHex())
        assertTrue(ThemeSettingsRepository.currentThemeKey().startsWith("CUSTOM:112233:"))
    }

    @Test
    fun appLanguageCodeIsStoredAndApplied() {
        ThemeSettingsRepository.ensureLoaded()
        ThemeSettingsRepository.setAppLanguageCode("fr")
        assertEquals("fr", store.language)
        assertEquals("fr", store.appliedLanguage)
        assertEquals("fr", ThemeSettingsRepository.currentAppLanguageCode())
        ThemeSettingsRepository.setAppLanguageCode("device")
        assertEquals("device", ThemeSettingsRepository.currentAppLanguageCode())
        ThemeSettingsRepository.setAppLanguageCode("garbage")
        assertEquals("device", ThemeSettingsRepository.currentAppLanguageCode())
    }
}
