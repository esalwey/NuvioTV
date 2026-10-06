package com.nuvio.app.core.ui

enum class AppTheme {
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
 */
val AppTheme.nativeAccentHex: String
    get() = when (this) {
        AppTheme.CRIMSON -> "#E53935"
        AppTheme.OCEAN -> "#1E88E5"
        AppTheme.VIOLET -> "#8E24AA"
        AppTheme.EMERALD -> "#43A047"
        AppTheme.AMBER -> "#FB8C00"
        AppTheme.ROSE -> "#D81B60"
        AppTheme.WHITE -> "#F5F5F5"
    }
