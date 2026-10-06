package com.nuvio.app.features.settings

enum class AppLanguage(
    val code: String,
) {
    DEVICE("device"),
    ARABIC("ar"),
    BULGARIAN("bg"),
    CZECH("cs"),
    ENGLISH("en"),
    FRENCH("fr"),
    GERMAN("de"),
    GREEK("el"),
    HEBREW("he"),
    HUNGARIAN("hu"),
    INDONESIAN("id"),
    ITALIAN("it"),
    POLISH("pl"),
    PORTUGUESE_BRAZIL("pt-BR"),
    PORTUGUESE("pt"),
    ROMANIAN("ro"),
    SLOVAK("sk"),
    SPANISH("es"),
    TURKISH("tr"),
    NORWEGIAN("nb"),
    DUTCH("nl"),
    JAPANESE("ja"),
    VIETNAMESE("vi"),
    ;

    companion object {
        fun fromCode(code: String?): AppLanguage =
            entries.firstOrNull { it.code.equals(code, ignoreCase = true) } ?: DEVICE
    }
}
