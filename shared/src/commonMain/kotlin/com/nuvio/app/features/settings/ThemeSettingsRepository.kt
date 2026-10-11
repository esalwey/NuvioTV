package com.nuvio.app.features.settings

import com.nuvio.app.core.ui.AppTheme
import com.nuvio.app.core.ui.CustomThemeColors
import com.nuvio.app.core.ui.NativeTabControllerProvider
import com.nuvio.app.core.ui.parseHexColor
import com.nuvio.app.core.ui.resolvedNativeAccentHex
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

object ThemeSettingsRepository {
    private val _selectedTheme = MutableStateFlow(AppTheme.WHITE)
    val selectedTheme: StateFlow<AppTheme> = _selectedTheme.asStateFlow()

    private val _customThemeColors = MutableStateFlow(CustomThemeColors.Default)
    val customThemeColors: StateFlow<CustomThemeColors> = _customThemeColors.asStateFlow()

    private val _amoledEnabled = MutableStateFlow(false)
    val amoledEnabled: StateFlow<Boolean> = _amoledEnabled.asStateFlow()

    private val _liquidGlassNativeTabBarEnabled = MutableStateFlow(false)
    val liquidGlassNativeTabBarEnabled: StateFlow<Boolean> = _liquidGlassNativeTabBarEnabled.asStateFlow()

    private val _selectedAppLanguage = MutableStateFlow(AppLanguage.DEVICE)
    val selectedAppLanguage: StateFlow<AppLanguage> = _selectedAppLanguage.asStateFlow()

    private val _navBarStyle = MutableStateFlow(NavBarStyle.ADAPTIVE)
    val navBarStyle: StateFlow<NavBarStyle> = _navBarStyle.asStateFlow()

    private var hasLoaded = false

    fun ensureLoaded() {
        if (hasLoaded) return
        loadFromDisk()
    }

    /**
     * Synchronous read of the current theme name for Swift callers — the generic
     * `StateFlow<AppTheme>` bridges to Swift as an untyped protocol without a usable `value`
     * member, and tvOS's `AppThemeModel` must seed its initial `@Published` name from the STORED
     * theme at init (a hard-coded seed guaranteed a whole-tree `.id()` remount seconds after
     * every cold launch for any profile whose theme differed — the beta.15 "doubled hero" report).
     * Call `ensureLoaded()` first.
     */
    fun currentThemeName(): String = _selectedTheme.value.name

    /**
     * Synchronous identity of the effective theme for Swift: the enum name, or for
     * [AppTheme.CUSTOM] `CUSTOM:<accent RRGGBB>:<focus RRGGBB>` so editing the custom color changes
     * the key (and so remounts the app root) even though the selected theme stays CUSTOM.
     */
    fun currentThemeKey(): String {
        val theme = _selectedTheme.value
        if (theme != AppTheme.CUSTOM) return theme.name
        val colors = _customThemeColors.value
        return "CUSTOM:" + colors.accentHex.removePrefix("#") + ":" + colors.focusHex.removePrefix("#")
    }

    /** The stored custom accent as `#RRGGBB` (the editor's starting value). */
    fun currentCustomThemeHex(): String = _customThemeColors.value.accentHex

    /** Current app language code ("device" or a BCP 47 code), for Swift. */
    fun currentAppLanguageCode(): String = _selectedAppLanguage.value.code

    fun onProfileChanged() {
        loadFromDisk()
    }

    fun clearLocalState() {
        hasLoaded = false
        _selectedTheme.value = AppTheme.WHITE
        _customThemeColors.value = CustomThemeColors.Default
        _amoledEnabled.value = false
        _liquidGlassNativeTabBarEnabled.value = false
        NativeTabControllerProvider.controller.publishAccentColor(AppTheme.WHITE.resolvedNativeAccentHex(CustomThemeColors.Default))
        NativeTabControllerProvider.controller.publishLiquidGlassEnabled(false)
        _selectedAppLanguage.value = AppLanguage.DEVICE
        _navBarStyle.value = NavBarStyle.ADAPTIVE
    }

    private fun loadFromDisk() {
        hasLoaded = true
        val stored = ThemeSettingsStoreProvider.store.loadSelectedTheme()
        val theme = if (stored != null) {
            try {
                AppTheme.valueOf(stored)
            } catch (_: IllegalArgumentException) {
                AppTheme.WHITE
            }
        } else {
            AppTheme.WHITE
        }
        val custom = CustomThemeColors.decode(ThemeSettingsStoreProvider.store.loadCustomThemeColors())
        _customThemeColors.value = custom
        _selectedTheme.value = theme
        NativeTabControllerProvider.controller.publishAccentColor(theme.resolvedNativeAccentHex(custom))
        _amoledEnabled.value = ThemeSettingsStoreProvider.store.loadAmoledEnabled() ?: false
        val liquidGlassEnabled = ThemeSettingsStoreProvider.store.loadLiquidGlassNativeTabBarEnabled() ?: false
        _liquidGlassNativeTabBarEnabled.value = liquidGlassEnabled
        NativeTabControllerProvider.controller.publishLiquidGlassEnabled(liquidGlassEnabled)
        val appLanguage = AppLanguage.fromCode(ThemeSettingsStoreProvider.store.loadSelectedAppLanguage())
        ThemeSettingsStoreProvider.store.applySelectedAppLanguage(appLanguage.code)
        _selectedAppLanguage.value = appLanguage
        _navBarStyle.value = NavBarStyle.fromKey(ThemeSettingsStoreProvider.store.loadNavBarStyle())
    }

    fun setTheme(theme: AppTheme) {
        ensureLoaded()
        if (_selectedTheme.value == theme) return
        _selectedTheme.value = theme
        ThemeSettingsStoreProvider.store.saveSelectedTheme(theme.name)
        NativeTabControllerProvider.controller.publishAccentColor(
            theme.resolvedNativeAccentHex(_customThemeColors.value),
        )
    }

    /** Stores [colors] and selects [AppTheme.CUSTOM]. */
    fun setCustomTheme(colors: CustomThemeColors) {
        ensureLoaded()
        ThemeSettingsStoreProvider.store.saveCustomThemeColors(colors.encode())
        _customThemeColors.value = colors
        ThemeSettingsStoreProvider.store.saveSelectedTheme(AppTheme.CUSTOM.name)
        _selectedTheme.value = AppTheme.CUSTOM
        NativeTabControllerProvider.controller.publishAccentColor(AppTheme.CUSTOM.resolvedNativeAccentHex(colors))
    }

    /**
     * Swift entry point of the Custom theme editor: a single `#RRGGBB` accent. Returns false (and
     * changes nothing) when [hex] is not a valid color.
     */
    fun setCustomThemeHex(hex: String): Boolean {
        val rgb = parseHexColor(hex) ?: return false
        setCustomTheme(CustomThemeColors.solid(rgb))
        return true
    }

    fun setAmoled(enabled: Boolean) {
        ensureLoaded()
        if (_amoledEnabled.value == enabled) return
        _amoledEnabled.value = enabled
        ThemeSettingsStoreProvider.store.saveAmoledEnabled(enabled)
    }

    fun setLiquidGlassNativeTabBar(enabled: Boolean) {
        ensureLoaded()
        if (_liquidGlassNativeTabBarEnabled.value == enabled) return
        _liquidGlassNativeTabBarEnabled.value = enabled
        ThemeSettingsStoreProvider.store.saveLiquidGlassNativeTabBarEnabled(enabled)
        NativeTabControllerProvider.controller.publishLiquidGlassEnabled(enabled)
    }

    /** Swift entry point: unknown codes resolve to [AppLanguage.DEVICE]. */
    fun setAppLanguageCode(code: String) {
        setAppLanguage(AppLanguage.fromCode(code))
    }

    fun setAppLanguage(language: AppLanguage) {
        ensureLoaded()
        if (_selectedAppLanguage.value == language) return
        ThemeSettingsStoreProvider.store.saveSelectedAppLanguage(language.code)
        ThemeSettingsStoreProvider.store.applySelectedAppLanguage(language.code)
        _selectedAppLanguage.value = language
    }

    fun setNavBarStyle(style: NavBarStyle) {
        ensureLoaded()
        if (_navBarStyle.value == style) return
        _navBarStyle.value = style
        ThemeSettingsStoreProvider.store.saveNavBarStyle(style.key)
    }
}
