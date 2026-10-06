package com.nuvio.app.features.watchprogress

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** CW sync #2: which rows the one-time post-pull backlog push sends. */
class WatchProgressBacklogTest {
    @Test
    fun `sends only the still-dirty rows, newest first`() {
        val e1 = episode(episode = 1, updatedAt = 1_000L)
        val e2 = episode(episode = 2, updatedAt = 3_000L)
        val e3 = episode(episode = 3, updatedAt = 2_000L)
        val acknowledged = episode(episode = 4, updatedAt = 9_000L)

        val backlog = selectDirtyWatchProgressBacklog(
            entries = listOf(e1, e2, e3, acknowledged),
            dirtyProgressKeys = setOf(e1.resolvedProgressKey(), e2.resolvedProgressKey(), e3.resolvedProgressKey()),
        )

        assertEquals(listOf(2, 3, 1), backlog.map { it.episodeNumber })
    }

    @Test
    fun `is capped to the newest rows`() {
        val entries = (1..250).map { number -> episode(episode = number, updatedAt = number * 1_000L) }

        val backlog = selectDirtyWatchProgressBacklog(
            entries = entries,
            dirtyProgressKeys = entries.mapTo(mutableSetOf()) { it.resolvedProgressKey() },
        )

        assertEquals(WATCH_PROGRESS_BACKLOG_PUSH_LIMIT, backlog.size)
        assertEquals(250, backlog.first().episodeNumber)
        assertEquals(51, backlog.last().episodeNumber)
    }

    @Test
    fun `leaves out rows the server could not store`() {
        val noVideo = episode(episode = 1, updatedAt = 1_000L).copy(videoId = " ")
        val noContent = episode(episode = 2, updatedAt = 2_000L).copy(parentMetaId = "", progressKey = "orphan")
        val fine = episode(episode = 3, updatedAt = 3_000L)

        val backlog = selectDirtyWatchProgressBacklog(
            entries = listOf(noVideo, noContent, fine),
            dirtyProgressKeys = setOf(noVideo.resolvedProgressKey(), "orphan", fine.resolvedProgressKey()),
        )

        assertEquals(listOf(fine.resolvedProgressKey()), backlog.map { it.resolvedProgressKey() })
    }

    @Test
    fun `nothing dirty sends nothing`() {
        assertTrue(
            selectDirtyWatchProgressBacklog(
                entries = listOf(episode(episode = 1, updatedAt = 1_000L)),
                dirtyProgressKeys = emptySet(),
            ).isEmpty(),
        )
    }

    // Review of #2: the backlog must not put back what another device removed after the row was
    // written. The deletes of a delta pull withdraw the rows they supersede from sync.

    @Test
    fun `a delete of its key withdraws an older unsynced row`() {
        val stale = episode(episode = 3, updatedAt = 1_000L)
        val synced = episode(episode = 1, updatedAt = 500L)

        val withdrawn = dirtyProgressKeysWithdrawnByServerDeletes(
            entries = listOf(stale, synced),
            dirtyProgressKeys = setOf(stale.resolvedProgressKey()),
            deletedProgressKeys = setOf(stale.resolvedProgressKey()),
            deletedContentIds = setOf("tt0944947"),
            writtenBeforeEpochMs = PULL_STARTED_AT,
        )

        assertEquals(setOf(stale.resolvedProgressKey()), withdrawn)
    }

    @Test
    fun `a show removed from Continue Watching elsewhere withdraws its other episodes too`() {
        // The phone only had E1, which the pull just deleted here too. The TV's E5 never reached
        // the account, and pushing it would put the removed show back on the phone.
        val tvOnly = episode(episode = 5, updatedAt = 1_000L)
        val otherShow = episode(episode = 2, updatedAt = 1_000L).copy(
            parentMetaId = "tt0903747",
            videoId = "tt0903747:1:2",
        )

        val withdrawn = dirtyProgressKeysWithdrawnByServerDeletes(
            entries = listOf(tvOnly, otherShow),
            dirtyProgressKeys = setOf(tvOnly.resolvedProgressKey(), otherShow.resolvedProgressKey()),
            deletedProgressKeys = setOf(episode(episode = 1, updatedAt = 0L).resolvedProgressKey()),
            deletedContentIds = setOf("tt0944947"),
            writtenBeforeEpochMs = PULL_STARTED_AT,
        )

        assertEquals(setOf(tvOnly.resolvedProgressKey()), withdrawn)
    }

    @Test
    fun `an episode cleared elsewhere leaves the show's other rows to the backlog`() {
        // E1 was marked watched on the phone (which clears its progress), and the account still
        // holds E2: this was not a removal of the show.
        val tvOnly = episode(episode = 5, updatedAt = 1_000L)
        val synced = episode(episode = 2, updatedAt = 800L)

        val withdrawn = dirtyProgressKeysWithdrawnByServerDeletes(
            entries = listOf(tvOnly, synced),
            dirtyProgressKeys = setOf(tvOnly.resolvedProgressKey()),
            deletedProgressKeys = setOf(episode(episode = 1, updatedAt = 0L).resolvedProgressKey()),
            deletedContentIds = setOf("tt0944947"),
            writtenBeforeEpochMs = PULL_STARTED_AT,
        )

        assertTrue(withdrawn.isEmpty())
    }

    @Test
    fun `a row written during the pull is kept`() {
        val playing = episode(episode = 3, updatedAt = PULL_STARTED_AT)

        val withdrawn = dirtyProgressKeysWithdrawnByServerDeletes(
            entries = listOf(playing),
            dirtyProgressKeys = setOf(playing.resolvedProgressKey()),
            deletedProgressKeys = setOf(playing.resolvedProgressKey()),
            deletedContentIds = setOf("tt0944947"),
            writtenBeforeEpochMs = PULL_STARTED_AT,
        )

        assertTrue(withdrawn.isEmpty())
    }

    @Test
    fun `no delete withdraws nothing`() {
        val stale = episode(episode = 3, updatedAt = 1_000L)

        assertTrue(
            dirtyProgressKeysWithdrawnByServerDeletes(
                entries = listOf(stale),
                dirtyProgressKeys = setOf(stale.resolvedProgressKey()),
                deletedProgressKeys = emptySet(),
                deletedContentIds = emptySet(),
                writtenBeforeEpochMs = PULL_STARTED_AT,
            ).isEmpty(),
        )
    }

    private companion object {
        const val PULL_STARTED_AT = 5_000L
    }

    private fun episode(episode: Int, updatedAt: Long) = WatchProgressEntry(
        contentType = "series",
        parentMetaId = "tt0944947",
        parentMetaType = "series",
        videoId = "tt0944947:1:$episode",
        title = "Game of Thrones",
        seasonNumber = 1,
        episodeNumber = episode,
        lastPositionMs = 60_000L,
        durationMs = 3_600_000L,
        lastUpdatedEpochMs = updatedAt,
    )
}
