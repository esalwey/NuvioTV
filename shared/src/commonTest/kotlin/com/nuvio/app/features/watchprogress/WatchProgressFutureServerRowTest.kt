package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watching.sync.ProgressDeltaEvent
import com.nuvio.app.features.watching.sync.ProgressSyncRecord
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * CW legacy diagnosis (REMAINING_FIX #3): a server row dated in the future (written by a device
 * whose clock is ahead) is undated locally, so it can no longer outrank the rows written since.
 */
class WatchProgressFutureServerRowTest {
    private val now = WatchProgressClock.nowEpochMs()
    private val showId = "tt0903747"

    private fun episode(
        episode: Int,
        updatedAt: Long,
        position: Long = 1_200_000L,
        completed: Boolean = false,
    ): WatchProgressEntry = WatchProgressEntry(
        contentType = "series",
        parentMetaId = showId,
        parentMetaType = "series",
        videoId = "$showId:1:$episode",
        title = "Breaking Bad",
        seasonNumber = 1,
        episodeNumber = episode,
        lastPositionMs = if (completed) 2_700_000L else position,
        durationMs = 2_800_000L,
        lastUpdatedEpochMs = updatedAt,
        isCompleted = completed,
    )

    private fun serverRecord(episode: Int, lastWatched: Long, position: Long = 300_000L) = ProgressSyncRecord(
        contentId = showId,
        contentType = "series",
        videoId = "$showId:1:$episode",
        season = 1,
        episode = episode,
        position = position,
        duration = 2_800_000L,
        lastWatched = lastWatched,
    )

    private fun upsertEvent(episode: Int, lastWatched: Long, position: Long = 300_000L) = ProgressDeltaEvent(
        eventId = 1L,
        operation = "upsert",
        progressKey = "${showId}_s1e$episode",
        contentId = showId,
        contentType = "series",
        videoId = "$showId:1:$episode",
        season = 1,
        episode = episode,
        position = position,
        duration = 2_800_000L,
        lastWatched = lastWatched,
    )

    @Test
    fun `more than ten minutes ahead of the clock is undated`() {
        assertEquals(0L, serverLastWatchedForLocalUse(now + 10 * 60_000L + 1L, now))
        assertEquals(now + 10 * 60_000L, serverLastWatchedForLocalUse(now + 10 * 60_000L, now))
        assertEquals(now - 86_400_000L, serverLastWatchedForLocalUse(now - 86_400_000L, now))
        assertEquals(0L, serverLastWatchedForLocalUse(0L, now))
    }

    // The snapshot merge

    @Test
    fun `the snapshot merge keeps an unsynced local row over a future-dated server copy`() {
        val local = episode(episode = 3, updatedAt = now - 60_000L)

        val merged = WatchProgressRepository.mergeWatchProgressEntriesPreservingUnsynced(
            serverEntries = listOf(serverRecord(episode = 3, lastWatched = now + 3_600_000L)),
            localEntries = listOf(local),
            dirtyProgressKeys = setOf(local.resolvedProgressKey()),
        )

        // The local row wins and keeps its key, so it stays dirty and the backlog push rewrites
        // the account's copy.
        assertEquals(local.withResolvedProgressKey(), merged[local.resolvedProgressKey()])
    }

    @Test
    fun `a future-dated server row no longer holds its series card`() {
        // The account's S1E3 comes from a device hours ahead; this TV then finished S1E7.
        val finished = episode(episode = 7, updatedAt = now - 60_000L, completed = true)

        val merged = WatchProgressRepository.mergeWatchProgressEntriesPreservingUnsynced(
            serverEntries = listOf(serverRecord(episode = 3, lastWatched = now + 6 * 3_600_000L)),
            localEntries = listOf(finished),
            dirtyProgressKeys = setOf(finished.resolvedProgressKey()),
        )

        val future = assertNotNull(merged["${showId}_s1e3"])
        assertEquals(0L, future.lastUpdatedEpochMs)
        // S1E7 is the series' newest row, and it is finished: no stale S1E3 card.
        assertTrue(merged.values.toList().continueWatchingEntries().isEmpty())
    }

    @Test
    fun `a server row within the tolerance keeps its date and wins as before`() {
        val local = episode(episode = 3, updatedAt = now - 60_000L)
        val lastWatched = now + 5 * 60_000L

        val merged = WatchProgressRepository.mergeWatchProgressEntriesPreservingUnsynced(
            serverEntries = listOf(serverRecord(episode = 3, lastWatched = lastWatched)),
            localEntries = listOf(local),
            dirtyProgressKeys = setOf(local.resolvedProgressKey()),
        )

        assertEquals(lastWatched, merged[local.resolvedProgressKey()]?.lastUpdatedEpochMs)
    }

    // The delta decision

    @Test
    fun `a future-dated delta upsert leaves an unsynced local row alone`() {
        val current = episode(episode = 3, updatedAt = now - 60_000L)

        val decision = WatchProgressRepository.decideWatchProgressDeltaEvent(
            current = current,
            event = upsertEvent(episode = 3, lastWatched = now + 3_600_000L),
            isLocalDirty = true,
        )

        assertEquals(WatchProgressDeltaDecisionType.PRESERVE_LOCAL, decision.type)
    }

    @Test
    fun `a future-dated delta upsert of a synced row lands undated, and only once`() {
        val current = episode(episode = 3, updatedAt = now - 60_000L)
        val event = upsertEvent(episode = 3, lastWatched = now + 3_600_000L)

        val decision = WatchProgressRepository.decideWatchProgressDeltaEvent(
            current = current,
            event = event,
            isLocalDirty = false,
        )
        assertEquals(WatchProgressDeltaDecisionType.UPSERT, decision.type)
        val updated = assertNotNull(decision.updatedEntry)
        assertEquals(0L, updated.lastUpdatedEpochMs)
        assertEquals(300_000L, updated.lastPositionMs)

        // The same event on the next pull is nothing new.
        val again = WatchProgressRepository.decideWatchProgressDeltaEvent(
            current = updated,
            event = event,
            isLocalDirty = false,
        )
        assertEquals(WatchProgressDeltaDecisionType.IGNORE, again.type)
    }

    // Episode marks (review)

    @Test
    fun `a watched mark dated ahead of the clock no longer hides the in-progress card`() {
        // A device hours ahead marked S1E3 watched; this TV then played S1E4 half way.
        val inProgress = episode(episode = 4, updatedAt = now - 60_000L)
        val futureMark = WatchedItem(
            id = showId,
            type = "series",
            name = "Breaking Bad",
            season = 1,
            episode = 3,
            markedAtEpochMs = now + 6 * 3_600_000L,
        )

        fun seeds(nowEpochMs: Long?) = buildContinueWatchingNextUpSeeds(
            progressEntries = listOf(inProgress),
            watchedItems = listOf(futureMark),
            inProgressEntries = listOf(inProgress).continueWatchingEntries(),
            preferFurthestEpisode = true,
            dismissedNextUpKeys = emptySet(),
            recencyCutoffEpochMs = null,
            limit = 20,
            canonicalSeriesId = { id -> id.trim() },
            nowEpochMs = nowEpochMs,
        )

        // Dated in the future, the mark beats the card: an Up Next S1E4 seed that would take the
        // series' place on the row.
        assertEquals(listOf(3), seeds(nowEpochMs = null).map { it.episodeNumber })
        // Against the clock it is undated, and the in-progress card keeps the series.
        assertTrue(seeds(nowEpochMs = now).isEmpty())
    }

    @Test
    fun `a watched mark within the tolerance keeps its date`() {
        assertEquals(now + 5 * 60_000L, undatedWhenAheadOfClock(now + 5 * 60_000L, now))
        assertEquals(0L, undatedWhenAheadOfClock(now + 11 * 60_000L, now))
    }
}
