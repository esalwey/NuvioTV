package com.nuvio.app.features.details

enum class SeasonViewMode {
    Posters,
    Text,
    ;

    fun toggled(): SeasonViewMode = when (this) {
        Posters -> Text
        Text -> Posters
    }

    companion object {
        fun parse(raw: String?): SeasonViewMode? = when (raw?.lowercase()) {
            "posters" -> Posters
            "text" -> Text
            else -> null
        }

        fun persist(mode: SeasonViewMode): String = when (mode) {
            Posters -> "posters"
            Text -> "text"
        }
    }
}

expect object SeasonViewModeStorage {
    fun load(): SeasonViewMode?
    fun save(mode: SeasonViewMode)
}

/**
 * String-keyed access for the Apple apps ("posters" / "text"): Swift hands over the persisted key
 * instead of naming PascalCase enum entries, whose ObjC export names are not worth depending on.
 */
object SeasonViewModeKeys {
    fun load(): String = SeasonViewMode.persist(SeasonViewModeStorage.load() ?: SeasonViewMode.Posters)

    fun save(key: String) {
        SeasonViewMode.parse(key)?.let { SeasonViewModeStorage.save(it) }
    }
}
