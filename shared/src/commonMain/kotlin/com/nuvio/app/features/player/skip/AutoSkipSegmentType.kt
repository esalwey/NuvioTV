package com.nuvio.app.features.player.skip

/**
 * The skip-segment kinds a viewer can have skipped automatically (Settings > Playback > Automatic
 * Skipping). Stored values match the phone app's `auto_skip_segment_types` profile setting, so the
 * selection syncs between devices.
 *
 * Post-credits scenes are deliberately not a kind: they are never skipped on their own.
 */
enum class AutoSkipSegmentType(val storedValue: String) {
    INTRO("intro"),
    RECAP("recap"),
    OUTRO("outro"),
    MOVIE_CREDITS("movie-credits");

    companion object {
        fun fromStoredValue(value: String): AutoSkipSegmentType? =
            entries.firstOrNull { it.storedValue == value }

        /**
         * The kind a provider's [SkipInterval.type] belongs to (AniSkip "op"/"ed", Anime-Skip
         * "mixed-op"/"mixed-ed", IntroDB "intro"/"recap"/"outro", ...), or null for a type that is
         * never skipped automatically ("post-credits", unknown types).
         */
        fun fromSkipIntervalType(type: String): AutoSkipSegmentType? = when (type.trim().lowercase()) {
            "op", "opening", "mixed-op", "intro" -> INTRO
            "recap" -> RECAP
            "ed", "ending", "mixed-ed", "outro", "credits" -> OUTRO
            "movie-credits" -> MOVIE_CREDITS
            else -> null
        }
    }
}
