package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ContinueWatchingPresentationTest {
    private val today = "2026-03-30"

    private fun entry(
        id: String,
        updated: Long,
        nextUp: Boolean = false,
        released: String? = null,
        episode: Boolean = true,
        thumbnail: String? = "still.jpg",
        completed: Boolean = false,
        position: Long = 10_000L,
    ) = WatchProgressEntry(
        contentType = if (episode) "series" else "movie",
        parentMetaId = id,
        parentMetaType = if (episode) "series" else "movie",
        videoId = "$id:1:2",
        title = id,
        poster = "poster.jpg",
        background = "backdrop.jpg",
        seasonNumber = if (episode) 1 else null,
        episodeNumber = if (episode) 2 else null,
        episodeThumbnail = thumbnail,
        lastPositionMs = if (nextUp) 0L else position,
        durationMs = if (nextUp) 0L else 100_000L,
        lastUpdatedEpochMs = updated,
        isCompleted = completed,
        source = if (nextUp) WatchProgressSourceNextUp else WatchProgressSourceLocal,
        released = released,
    )

    @Test
    fun card_artwork_prefers_the_episode_still_only_when_asked() {
        val e = entry("a", 1L)
        assertEquals("still.jpg", continueWatchingCardArtworkUrl(e, useEpisodeThumbnails = true))
        assertEquals("backdrop.jpg", continueWatchingCardArtworkUrl(e, useEpisodeThumbnails = false))
        assertEquals("poster.jpg", continueWatchingPosterArtworkUrl(e))
    }

    @Test
    fun card_artwork_falls_through_blank_values() {
        val e = entry("a", 1L, thumbnail = "  ").copy(background = null)
        assertEquals("poster.jpg", continueWatchingCardArtworkUrl(e, useEpisodeThumbnails = true))
        val movie = entry("m", 1L, episode = false, thumbnail = null)
        assertEquals("backdrop.jpg", continueWatchingCardArtworkUrl(movie, useEpisodeThumbnails = true))
    }

    @Test
    fun blur_applies_to_unwatched_episode_stills_only() {
        val upNext = entry("a", 1L, nextUp = true)
        val art = continueWatchingCardArtworkUrl(upNext, useEpisodeThumbnails = true)
        assertTrue(shouldBlurContinueWatchingArtwork(upNext, true, true, art))
        assertFalse(shouldBlurContinueWatchingArtwork(upNext, false, true, art))
        assertFalse(shouldBlurContinueWatchingArtwork(upNext, true, false, art))
        // The artwork is the backdrop, not the still: nothing to hide.
        assertFalse(shouldBlurContinueWatchingArtwork(upNext, true, true, "backdrop.jpg"))
        // Almost finished or finished: spoilers are moot.
        val finished = entry("b", 1L, position = 95_000L)
        assertFalse(shouldBlurContinueWatchingArtwork(finished, true, true, "still.jpg"))
        val inProgress = entry("c", 1L, position = 20_000L)
        assertTrue(shouldBlurContinueWatchingArtwork(inProgress, true, true, "still.jpg"))
    }

    @Test
    fun unaired_cards_are_up_next_cards_with_a_future_date() {
        assertTrue(isUnairedContinueWatchingCard(entry("a", 1L, nextUp = true, released = "2099-01-01"), today))
        assertFalse(isUnairedContinueWatchingCard(entry("a", 1L, nextUp = true, released = "2020-01-01"), today))
        assertFalse(isUnairedContinueWatchingCard(entry("a", 1L, nextUp = true, released = null), today))
        assertFalse(isUnairedContinueWatchingCard(entry("a", 1L, nextUp = false, released = "2099-01-01"), today))
        assertNotNull(continueWatchingDaysUntilAir(entry("a", 1L, nextUp = true, released = "2099-01-01"), today))
        assertNull(continueWatchingDaysUntilAir(entry("a", 1L, nextUp = true, released = "2020-01-01"), today))
        assertNull(continueWatchingDaysUntilAir(entry("a", 1L, nextUp = false, released = "2099-01-01"), today))
    }

    private val row = listOf(
        entry("late", 500L, nextUp = true, released = "2099-06-01"),
        entry("watching", 400L),
        entry("soon", 300L, nextUp = true, released = "2099-02-01"),
        entry("aired", 200L, nextUp = true, released = "2020-01-01"),
    )

    @Test
    fun default_mode_keeps_the_row_untouched() {
        assertEquals(row, applyContinueWatchingSortMode(row, ContinueWatchingSortMode.DEFAULT, today))
    }

    @Test
    fun streaming_style_puts_unaired_last_by_air_date() {
        val ids = applyContinueWatchingSortMode(row, ContinueWatchingSortMode.STREAMING_STYLE, today)
            .map { it.parentMetaId }
        assertEquals(listOf("watching", "aired", "soon", "late"), ids)
    }

    @Test
    fun split_mode_drops_unaired_cards_from_the_row() {
        val ids = applyContinueWatchingSortMode(row, ContinueWatchingSortMode.SPLIT_UPCOMING, today)
            .map { it.parentMetaId }
        assertEquals(listOf("watching", "aired"), ids)
    }

    @Test
    fun a_row_without_unaired_cards_is_returned_as_is() {
        val released = row.filterNot { it.parentMetaId == "late" || it.parentMetaId == "soon" }
        assertEquals(released, applyContinueWatchingSortMode(released, ContinueWatchingSortMode.SPLIT_UPCOMING, today))
    }

    @Test
    fun unaired_next_episode_card_carries_its_release_date_when_allowed() {
        val show = MetaDetails(
            id = "show",
            type = "series",
            name = "The Show",
            videos = listOf(
                MetaVideo(id = "show:1:1", title = "Pilot", season = 1, episode = 1, released = "2026-03-01"),
                MetaVideo(id = "show:1:2", title = "Second", season = 1, episode = 2, released = "2099-03-08"),
            ),
        )
        val finished = entry("show", 100L, completed = true, position = 100_000L).copy(
            videoId = "show:1:1",
            episodeNumber = 1,
            source = WatchProgressSourceLocal,
        )
        val seed = buildContinueWatchingNextUpSeeds(
            progressEntries = listOf(finished),
            watchedItems = emptyList(),
            inProgressEntries = emptyList(),
            preferFurthestEpisode = true,
            dismissedNextUpKeys = emptySet(),
            recencyCutoffEpochMs = null,
            limit = 20,
        ).single()

        fun card(showUnaired: Boolean) = show.continueWatchingNextUpEntry(
            seed = seed,
            progressEntries = listOf(finished),
            watchedItems = emptyList(),
            todayIsoDate = today,
            preferFurthestEpisode = true,
            showUnairedNextUp = showUnaired,
        )

        assertNull(card(showUnaired = false))
        assertEquals("2099-03-08", card(showUnaired = true)?.released)
    }
}
