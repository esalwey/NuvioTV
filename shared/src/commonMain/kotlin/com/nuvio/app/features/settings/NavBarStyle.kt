package com.nuvio.app.features.settings

// Fork split (like AppLanguage): upstream declares this enum in composeApp with a compose-resources
// labelRes per entry; the fork keeps the enum in :shared (ThemeSettingsRepository/ProfileSettingsSync
// reference it) and the labels live in composeApp NavBarStyleLabels.kt.
enum class NavBarStyle(
    val key: String,
) {
    ADAPTIVE("adaptive"),
    EXPANDED("expanded"),
    COMPACT("compact"),
    CLASSIC("classic"),
    ;

    companion object {
        fun fromKey(key: String?): NavBarStyle =
            entries.firstOrNull { it.key.equals(key, ignoreCase = true) } ?: ADAPTIVE
    }
}
