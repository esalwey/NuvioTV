package com.nuvio.app.features.settings

import com.nuvio.app.core.ui.AppTheme
import com.nuvio.app.core.ui.NativeTabControllerProvider
import com.nuvio.app.core.ui.nativeAccentHex
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

object ThemeSettingsRepository {
    private val _selectedTheme = MutableStateFlow(AppTheme.WHITE)
    val selectedTheme: StateFlow<AppTheme> = _selectedTheme.asStateFlow()

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

    fun onProfileChanged() {
        loadFromDisk()
    }

    fun clearLocalState() {
        hasLoaded = false
        _selectedTheme.value = AppTheme.WHITE
        _amoledEnabled.value = false
        _liquidGlassNativeTabBarEnabled.value = false
        NativeTabControllerProvider.controller.publishAccentColor(AppTheme.WHITE.nativeTabAccentHex())
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
        _selectedTheme.value = theme
        NativeTabControllerProvider.controller.publishAccentColor(theme.nativeTabAccentHex())
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
        NativeTabControllerProvider.controller.publishAccentColor(theme.nativeTabAccentHex())
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

private fun AppTheme.nativeTabAccentHex(): String =
    this.nativeAccentHex
