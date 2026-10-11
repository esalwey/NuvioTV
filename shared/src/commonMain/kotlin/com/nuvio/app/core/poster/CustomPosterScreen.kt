package com.nuvio.app.core.poster

/** The surfaces a custom poster URL pattern can be applied to; each has its own on/off switch. */
enum class CustomPosterScreen(val key: String) {
    /** Home catalog rows and the catalog grids opened from them. */
    HOME("home"),

    /** Continue Watching and Upcoming. */
    CONTINUE_WATCHING("continue_watching"),

    /** Collection and folder screens. */
    COLLECTIONS("collections"),

    /** The Library screen. */
    LIBRARY("library"),

    /** Search results. */
    SEARCH("search"),

    /** Details: recommendations, collection parts and person credits. */
    DETAILS("details");

    companion object {
        /** Every screen enabled: the default state. */
        val ALL: Set<CustomPosterScreen> = entries.toSet()

        /** Stored form of "no screen enabled": an empty string would read as "never chosen". */
        const val NONE_KEY = "none"

        /**
         * Screens from the comma-joined form the profile blob and the local stores keep. Absent or
         * blank means "never chosen", so every screen; [NONE_KEY] means none. Unknown keys are dropped.
         */
        fun fromStoredString(value: String?): Set<CustomPosterScreen> {
            val keys = value?.split(',')?.map(String::trim)?.filter(String::isNotEmpty).orEmpty()
            if (keys.isEmpty()) return ALL
            return keys.mapNotNull { key -> entries.firstOrNull { it.key == key } }.toSet()
        }

        /** Comma-joined stored form, in declaration order so the string is stable. */
        fun toStoredString(screens: Set<CustomPosterScreen>): String =
            entries.filter { it in screens }.joinToString(",") { it.key }.ifEmpty { NONE_KEY }
    }
}
