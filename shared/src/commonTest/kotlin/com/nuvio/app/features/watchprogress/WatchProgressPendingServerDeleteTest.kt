package com.nuvio.app.features.watchprogress

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * CW alias fix (review): the server delete of a removal waits for the pull lock, so a pull that
 * read the account before the removal must not put the removed rows back while it is pending.
 */
class WatchProgressPendingServerDeleteTest {
    private fun episode(episode: Int, updatedAt: Long): WatchProgressEntry = WatchProgressEntry(
        contentType = "series",
        parentMetaId = "tmdb:1396",
        parentMetaType = "series",
        videoId = "tmdb:1396:1:$episode",
        title = "Breaking Bad",
        seasonNumber = 1,
        episodeNumber = episode,
        lastPositionMs = 600_000L,
        durationMs = 2_800_000L,
        lastUpdatedEpochMs = updatedAt,
    )

    @Test
    fun `a pull leaves out the rows whose removal has not reached the account`() {
        val removed = episode(episode = 3, updatedAt = 3_000L)
        val playedAgain = episode(episode = 4, updatedAt = 4_000L)
        val untouched = episode(episode = 5, updatedAt = 5_000L)

        val kept = withoutPendingServerDeletes(
            entries = listOf(removed, playedAgain, untouched),
            pendingDeleteKeys = setOf(removed.resolvedProgressKey(), playedAgain.resolvedProgressKey()),
            // Written here again since its removal: a new local write, which stays.
            dirtyProgressKeys = setOf(playedAgain.resolvedProgressKey()),
        )

        assertEquals(listOf(4, 5), kept.map { it.episodeNumber })
    }

    @Test
    fun `nothing pending keeps every row`() {
        val entries = listOf(episode(episode = 1, updatedAt = 1_000L), episode(episode = 2, updatedAt = 2_000L))

        assertEquals(entries, withoutPendingServerDeletes(entries, pendingDeleteKeys = emptySet(), dirtyProgressKeys = emptySet()))
    }
}
