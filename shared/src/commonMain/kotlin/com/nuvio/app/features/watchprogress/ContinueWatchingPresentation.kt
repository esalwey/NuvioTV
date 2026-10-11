package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.watching.domain.daysUntilExplicitRelease
import com.nuvio.app.features.watching.domain.isReleasedBy

/*
 * Presentation rules of the Continue Watching row that depend on the viewer's Continue Watching
 * preferences: which artwork a card shows, whether it is blurred as a spoiler, and how the row is
 * ordered. Ported from mobile's `HomeContinueWatchingSection` / `buildHomeContinueWatchingItems`,
 * as plain functions over `WatchProgressEntry` so the Swift row stays a thin renderer.
 *
 * These are top-level functions with the entry as an explicit argument (not extensions) so the
 * Swift call sites read `ContinueWatchingPresentationKt.fn(entry:...)`.
 */

private fun firstNonBlank(vararg values: String?): String? =
    values.firstOrNull { value -> !value.isNullOrBlank() }?.trim()

private fun WatchProgressEntry.isUpNextCard(): Boolean = source == WatchProgressSourceNextUp

/**
 * Artwork of a landscape card (Card and Wide styles): the episode still first when the viewer
 * prefers thumbnails, then the backdrop, then the poster. Without that preference the backdrop of
 * the series leads, so every episode of a show reads as the show.
 */
fun continueWatchingCardArtworkUrl(entry: WatchProgressEntry, useEpisodeThumbnails: Boolean): String? =
    if (useEpisodeThumbnails && entry.isEpisode) {
        firstNonBlank(entry.episodeThumbnail, entry.background, entry.poster)
    } else {
        firstNonBlank(entry.background, entry.poster, entry.episodeThumbnail)
    }

/**
 * Artwork of a portrait card (Poster style): always the title's poster, never an episode still
 * (a 16:9 still cropped into 2:3 reads as noise). Falls back to the backdrop only when the title
 * has no poster at all.
 */
fun continueWatchingPosterArtworkUrl(entry: WatchProgressEntry): String? =
    firstNonBlank(entry.poster, entry.background, entry.episodeThumbnail)

/**
 * Whether [artworkUrl] should be blurred as a spoiler (mobile `shouldBlurContinueWatchingArtwork`):
 * only an episode still, only for an episode the viewer has not watched yet (an Up Next card, or
 * progress short of the completion threshold), and only when the setting is on.
 */
fun shouldBlurContinueWatchingArtwork(
    entry: WatchProgressEntry,
    blurUnwatched: Boolean,
    useEpisodeThumbnails: Boolean,
    artworkUrl: String?,
): Boolean {
    if (!blurUnwatched || !useEpisodeThumbnails || entry.isEffectivelyCompleted) return false
    val thumbnail = entry.episodeThumbnail?.trim()?.takeIf(String::isNotBlank) ?: return false
    val artwork = artworkUrl?.trim()?.takeIf(String::isNotBlank) ?: return false
    val unwatched = entry.isUpNextCard() ||
        entry.progressFraction < WatchProgressCompletionPercentThreshold / 100f
    return unwatched && artwork == thumbnail
}

/**
 * Whole days until an Up Next card's episode airs, or null when the card is not an Up Next card,
 * has no known release date, or the episode has already aired (0 = today).
 */
fun continueWatchingDaysUntilAir(entry: WatchProgressEntry, todayIsoDate: String): Int? {
    if (!entry.isUpNextCard()) return null
    val released = entry.released?.takeIf(String::isNotBlank) ?: return null
    if (isReleasedBy(todayIsoDate = todayIsoDate, releasedDate = released)) return null
    return daysUntilExplicitRelease(todayIsoDate = todayIsoDate, releasedDate = released)?.coerceAtLeast(0)
}

/** An Up Next card whose episode has not aired yet. */
fun isUnairedContinueWatchingCard(entry: WatchProgressEntry, todayIsoDate: String): Boolean {
    if (!entry.isUpNextCard()) return false
    val released = entry.released?.takeIf(String::isNotBlank) ?: return false
    return !isReleasedBy(todayIsoDate = todayIsoDate, releasedDate = released)
}

/**
 * Orders the row for [mode] (mobile `buildHomeContinueWatchingItems` / `splitUpcomingItems`).
 * [entries] arrive most-recent first, one card per title.
 *
 * - [ContinueWatchingSortMode.DEFAULT]: recency, unchanged.
 * - [ContinueWatchingSortMode.STREAMING_STYLE]: released cards by recency, then unaired Up Next
 *   cards by air date (soonest first, unknown dates last).
 * - [ContinueWatchingSortMode.SPLIT_UPCOMING]: unaired Up Next cards leave the row. tvOS already
 *   has a dedicated Upcoming row (followed shows' next airing episodes), which is where they live.
 */
fun applyContinueWatchingSortMode(
    entries: List<WatchProgressEntry>,
    mode: ContinueWatchingSortMode,
    todayIsoDate: String,
): List<WatchProgressEntry> {
    if (mode == ContinueWatchingSortMode.DEFAULT || entries.isEmpty()) return entries
    val (unaired, released) = entries.partition { entry -> isUnairedContinueWatchingCard(entry, todayIsoDate) }
    if (unaired.isEmpty()) return entries
    return when (mode) {
        ContinueWatchingSortMode.DEFAULT -> entries
        ContinueWatchingSortMode.SPLIT_UPCOMING -> released
        ContinueWatchingSortMode.STREAMING_STYLE -> released + unaired.sortedBy { entry ->
            // ISO dates compare lexically; a blank date cannot be here (unaired needs one).
            entry.released.orEmpty()
        }
    }
}
