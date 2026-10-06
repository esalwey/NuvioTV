package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.watched.WatchedItem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ContinueWatchingNextUpTest {
    private fun episode(
        showId: String,
        seasonNumber: Int,
        episodeNumber: Int,
        lastUpdatedEpochMs: Long,
        completed: Boolean,
    ): WatchProgressEntry = WatchProgressEntry(
        contentType = "series",
        parentMetaId = showId,
        parentMetaType = "series",
        videoId = "$showId:$seasonNumber:$episodeNumber",
        title = showId,
        seasonNumber = seasonNumber,
        episodeNumber = episodeNumber,
        lastPositionMs = if (completed) 100_000L else 10_000L,
        durationMs = 100_000L,
        lastUpdatedEpochMs = lastUpdatedEpochMs,
        isCompleted = completed,
    )

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

    private fun seeds(
        progressEntries: List<WatchProgressEntry>,
        watchedItems: List<WatchedItem> = emptyList(),
        inProgressEntries: List<WatchProgressEntry> = progressEntries.continueWatchingEntries(),
        dismissed: Set<String> = emptySet(),
        cutoff: Long? = null,
    ) = buildContinueWatchingNextUpSeeds(
        progressEntries = progressEntries,
        watchedItems = watchedItems,
        inProgressEntries = inProgressEntries,
        preferFurthestEpisode = true,
        dismissedNextUpKeys = dismissed,
        recencyCutoffEpochMs = cutoff,
        limit = 20,
    )

    private val show = MetaDetails(
        id = "show",
        type = "series",
        name = "The Show",
        poster = "poster.jpg",
        background = "backdrop.jpg",
        logo = "logo.png",
        videos = listOf(
            MetaVideo(id = "show:1:1", title = "Pilot", season = 1, episode = 1, released = "2026-03-01"),
            MetaVideo(id = "show:1:2", title = "Second", season = 1, episode = 2, released = "2026-03-08", thumbnail = "e2.jpg", overview = "Two."),
            MetaVideo(id = "show:1:3", title = "Finale", season = 1, episode = 3, released = "2026-03-15"),
        ),
    )

    @Test
    fun finished_episode_seeds_its_series() {
        val result = seeds(listOf(episode("show", 1, 1, 100L, completed = true)))

        assertEquals(1, result.size)
        assertEquals("show", result.single().contentId)
        assertEquals(1, result.single().episodeNumber)
        assertEquals("show|1|1", result.single().dismissKey)
    }

    @Test
    fun newer_in_progress_card_suppresses_the_seed() {
        val result = seeds(
            listOf(
                episode("show", 1, 1, 100L, completed = true),
                episode("show", 1, 2, 200L, completed = false),
            ),
        )

        assertTrue(result.isEmpty())
    }

    @Test
    fun explicit_episode_mark_newer_than_the_resume_point_seeds_the_series() {
        val result = seeds(
            progressEntries = listOf(episode("show", 1, 1, 100L, completed = false)),
            watchedItems = listOf(
                WatchedItem(id = "show", type = "series", name = "The Show", season = 1, episode = 2, markedAtEpochMs = 300L),
            ),
        )

        assertEquals(listOf(2), result.map { it.episodeNumber })
    }

    @Test
    fun dismissed_cutoff_and_movies_yield_no_seed() {
        val entries = listOf(
            episode("dismissed", 1, 1, 500L, completed = true),
            episode("old", 1, 1, 50L, completed = true),
            movie("movie", 400L).copy(isCompleted = true, lastPositionMs = 100_000L),
            episode("kept", 1, 4, 300L, completed = true),
        )

        val result = seeds(entries, dismissed = setOf("dismissed|1|1"), cutoff = 100L)

        assertEquals(listOf("kept"), result.map { it.contentId })
    }

    @Test
    fun seeds_are_most_recent_first_one_per_series() {
        val result = seeds(
            listOf(
                episode("a", 1, 1, 100L, completed = true),
                episode("b", 1, 1, 300L, completed = true),
                episode("a", 1, 2, 200L, completed = true),
            ),
        )

        assertEquals(listOf("b" to 1, "a" to 2), result.map { it.contentId to it.episodeNumber })
    }

    @Test
    fun card_is_the_next_released_episode_with_series_identity() {
        val finished = episode("show", 1, 1, 100L, completed = true)
        val seed = seeds(listOf(finished)).single()

        val card = show.continueWatchingNextUpEntry(
            seed = seed,
            progressEntries = listOf(finished),
            watchedItems = emptyList(),
            todayIsoDate = "2026-03-30",
            preferFurthestEpisode = true,
        )

        assertNotNull(card)
        assertEquals("show:1:2", card.videoId)
        assertEquals("The Show", card.title)
        assertEquals("Second", card.episodeTitle)
        assertEquals("e2.jpg", card.episodeThumbnail)
        assertEquals("backdrop.jpg", card.background)
        assertEquals("logo.png", card.logo)
        assertEquals("Two.", card.pauseDescription)
        assertEquals(2, card.episodeNumber)
        assertEquals(100L, card.lastUpdatedEpochMs)
        assertEquals(0L, card.lastPositionMs)
        assertEquals(WatchProgressSourceNextUp, card.source)
    }

    @Test
    fun finale_and_unreleased_next_episode_give_no_card() {
        val finale = episode("show", 1, 3, 100L, completed = true)
        assertNull(
            show.continueWatchingNextUpEntry(
                seed = seeds(listOf(finale)).single(),
                progressEntries = listOf(finale),
                watchedItems = emptyList(),
                todayIsoDate = "2026-03-30",
                preferFurthestEpisode = true,
            ),
        )

        val unreleased = show.copy(
            videos = show.videos.map { video ->
                if ((video.episode ?: 0) >= 2) video.copy(released = "2099-01-01") else video
            },
        )
        val first = episode("show", 1, 1, 100L, completed = true)
        assertNull(
            unreleased.continueWatchingNextUpEntry(
                seed = seeds(listOf(first)).single(),
                progressEntries = listOf(first),
                watchedItems = emptyList(),
                todayIsoDate = "2026-03-30",
                preferFurthestEpisode = true,
            ),
        )
    }

    @Test
    fun merge_sorts_by_recency_and_keeps_one_card_per_title() {
        val inProgress = listOf(
            episode("show", 1, 2, 300L, completed = false),
            movie("movie", 100L),
        )
        val nextUp = listOf(
            episode("show", 1, 3, 300L, completed = false).copy(source = WatchProgressSourceNextUp),
            episode("other", 2, 1, 200L, completed = false).copy(source = WatchProgressSourceNextUp),
        )

        val row = mergeContinueWatchingNextUp(inProgressEntries = inProgress, nextUpEntries = nextUp)

        assertEquals(listOf("show:1:2", "other:2:1", "movie"), row.map { it.videoId })
    }
}
