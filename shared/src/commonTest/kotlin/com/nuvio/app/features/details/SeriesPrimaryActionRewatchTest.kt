package com.nuvio.app.features.details

import com.nuvio.app.features.watched.releasedMainSeasonEpisodes
import com.nuvio.app.features.watched.toEpisodeWatchedItem
import com.nuvio.app.features.watched.toSeriesWatchedItem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

// Ported from upstream 2b8be69cd (#1932) — composeApp's SeriesPlaybackResolverTest there.
class SeriesPrimaryActionRewatchTest {
    private val meta = MetaDetails(
        id = "show",
        type = "series",
        name = "Show",
        videos = listOf(
            MetaVideo(id = "show:0:1", title = "Special", season = 0, episode = 1, released = "2026-02-01"),
            MetaVideo(id = "show:1:1", title = "Pilot", season = 1, episode = 1, released = "2026-03-01"),
            MetaVideo(id = "show:1:2", title = "Finale", season = 1, episode = 2, released = "2026-03-08"),
        ),
    )
    private val todayIsoDate = "2026-03-30"
    private val fullyWatched = listOf(meta.toSeriesWatchedItem(markedAtEpochMs = 200L)) +
        meta.releasedMainSeasonEpisodes(todayIsoDate).map { episode ->
            meta.toEpisodeWatchedItem(episode, markedAtEpochMs = 200L)
        }

    @Test
    fun seriesPrimaryAction_restarts_at_first_episode_when_series_is_marked_watched() {
        val action = meta.seriesPrimaryAction(
            entries = emptyList(),
            watchedItems = fullyWatched,
            todayIsoDate = todayIsoDate,
            allowRewatch = true,
        )

        assertNotNull(action, "A watched series must still select an episode for the Play button")
        assertEquals("show:1:1", action.videoId)
        assertEquals(1, action.seasonNumber)
        assertEquals(1, action.episodeNumber)
        assertEquals("Pilot", action.episodeTitle)
        assertEquals("Play S1E1", action.label)
        assertNull(action.resumePositionMs)
    }

    @Test
    fun seriesPrimaryAction_offers_nothing_for_a_watched_series_without_rewatch() {
        val action = meta.seriesPrimaryAction(
            entries = emptyList(),
            watchedItems = fullyWatched,
            todayIsoDate = todayIsoDate,
        )

        assertNull(action)
    }
}
