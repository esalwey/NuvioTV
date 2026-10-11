package com.nuvio.app.core.ui

enum class AppTheme {
    GOLD,
    JADE,
    ROSE_GOLD,
    ARCTIC_BLUE,
    GRAPHITE,
    CUSTOM,
    CRIMSON,
    OCEAN,
    VIOLET,
    EMERALD,
    AMBER,
    ROSE,
    WHITE,
}

/**
 * The native (UIKit/Android) tab-bar accent color for each theme, as a hex string. Kept here in
 * the UI-free shared module (mirrors ThemeColors' palette in composeApp) so ThemeSettingsRepository
 * can publish it without depending on Compose-heavy ThemeColors.
 *
 * [AppTheme.CUSTOM] resolves against the user's stored colors; this property answers with the
 * default custom palette. Use [resolvedNativeAccentHex] with the active [CustomThemeColors]
 * when the stored value matters.
 */
val AppTheme.nativeAccentHex: String
    get() = when (this) {
        AppTheme.GOLD -> "#FFD45C"
        AppTheme.JADE -> "#7BF08D"
        AppTheme.ROSE_GOLD -> "#FFB37A"
        AppTheme.ARCTIC_BLUE -> "#4DE3FF"
        AppTheme.GRAPHITE -> "#F3F5F7"
        AppTheme.CUSTOM -> CustomThemeColors.Default.focusHex
        AppTheme.CRIMSON -> "#E53935"
        AppTheme.OCEAN -> "#1E88E5"
        AppTheme.VIOLET -> "#8E24AA"
        AppTheme.EMERALD -> "#43A047"
        AppTheme.AMBER -> "#FB8C00"
        AppTheme.ROSE -> "#D81B60"
        AppTheme.WHITE -> "#F5F5F5"
    }

/** Accent hex for [AppTheme.CUSTOM] follows [custom]; every other theme is fixed. */
fun AppTheme.resolvedNativeAccentHex(custom: CustomThemeColors): String =
    if (this == AppTheme.CUSTOM) custom.focusHex else nativeAccentHex
