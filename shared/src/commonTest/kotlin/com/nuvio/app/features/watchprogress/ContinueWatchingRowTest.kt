package com.nuvio.app.features.watchprogress

import kotlin.test.Test
import kotlin.test.assertEquals

class ContinueWatchingRowTest {
    private val nothingDropped: (String) -> Boolean = { false }

    private fun movie(id: String, lastUpdatedEpochMs: Long): WatchProgressEntry = WatchProgressEntry(
        contentType = "movie",
        parentMetaId = id,
        parentMetaType = "movie",
        videoId = id,
        title = id,
        lastPositionMs = 10_000L,
        durationMs = 100_000L,
        lastUpdatedEpochMs = lastUpdatedEpochMs,
    )

    private fun episode(
        showId: String,
        seasonNumber: Int,
        episodeNumber: Int,
        lastUpdatedEpochMs: Long,
    ): WatchProgressEntry = WatchProgressEntry(
        contentType = "series",
        parentMetaId = showId,
        parentMetaType = "series",
        videoId = "$showId:$seasonNumber:$episodeNumber",
        title = showId,
        seasonNumber = seasonNumber,
        episodeNumber = episodeNumber,
        lastPositionMs = 10_000L,
        durationMs = 100_000L,
        lastUpdatedEpochMs = lastUpdatedEpochMs,
    )

    @Test
    fun scan_limit_matches_mobile_home_limit() {
        assertEquals(300, ContinueWatchingRowScanLimit)
    }

    @Test
    fun filters_out_dropped_shows() {
        val result = buildContinueWatchingRowEntries(
            entries = listOf(
                episode("show-dropped", 1, 2, 300L),
                episode("show-kept", 1, 2, 200L),
                movie("movie-a", 100L),
            ),
            isDroppedShow = { contentId -> contentId == "show-dropped" },
            recencyCutoffEpochMs = null,
        )

        assertEquals(listOf("show-kept:1:2", "movie-a"), result.map { it.videoId })
    }

    @Test
    fun null_cutoff_applies_no_recency_window() {
        val entries = listOf(
            movie("movie-new", 1_000_000L),
            movie("movie-ancient", 1L),
        )

        val result = buildContinueWatchingRowEntries(
            entries = entries,
            isDroppedShow = nothingDropped,
            recencyCutoffEpochMs = null,
        )

        assertEquals(listOf("movie-new", "movie-ancient"), result.map { it.videoId })
    }

    @Test
    fun cutoff_drops_only_strictly_older_entries() {
        val result = buildContinueWatchingRowEntries(
            entries = listOf(
                movie("movie-after", 501L),
                movie("movie-at-cutoff", 500L),
                movie("movie-before", 499L),
            ),
            isDroppedShow = nothingDropped,
            recencyCutoffEpochMs = 500L,
        )

        assertEquals(listOf("movie-after", "movie-at-cutoff"), result.map { it.videoId })
    }

    @Test
    fun keeps_only_the_latest_episode_per_series() {
        val result = buildContinueWatchingRowEntries(
            entries = listOf(
                episode("show", 1, 1, 100L),
                episode("show", 1, 2, 400L),
                episode("show", 1, 3, 200L),
            ),
            isDroppedShow = nothingDropped,
            recencyCutoffEpochMs = null,
        )

        assertEquals(listOf("show:1:2"), result.map { it.videoId })
    }

    @Test
    fun caps_the_result_at_the_requested_limit_keeping_the_most_recent() {
        val result = buildContinueWatchingRowEntries(
            entries = (1..5).map { index -> movie("movie-$index", index * 100L) },
            isDroppedShow = nothingDropped,
            recencyCutoffEpochMs = null,
            limit = 3,
        )

        assertEquals(listOf("movie-5", "movie-4", "movie-3"), result.map { it.videoId })
    }

    @Test
    fun orders_survivors_by_recency_regardless_of_input_order() {
        val result = buildContinueWatchingRowEntries(
            entries = listOf(
                movie("movie-old", 100L),
                episode("show", 2, 5, 900L),
                movie("movie-mid", 400L),
            ),
            isDroppedShow = nothingDropped,
            recencyCutoffEpochMs = null,
        )

        assertEquals(listOf("show:2:5", "movie-mid", "movie-old"), result.map { it.videoId })
    }
}
