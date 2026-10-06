package com.nuvio.app.features.simkl

import com.nuvio.app.features.watchprogress.TrackerOptimisticFailedStopRetentionMs
import com.nuvio.app.features.watchprogress.TrackerOptimisticProgressTtlMs
import com.nuvio.app.features.watchprogress.TrackerOptimisticStopInFlightHoldMs
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import com.nuvio.app.features.watchprogress.WatchProgressSourceSimklPlayback
import com.nuvio.app.features.watchprogress.buildContinueWatchingRowEntries
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** CW sync #3: local playback over the Simkl progress projection. */
class SimklOptimisticProgressOverlayTest {
    @Test
    fun `an autoplay chain moves Continue Watching although Simkl still has the first episode`() {
        // The symptom: Simkl's snapshot still ends at S1E1, paused at 40 %, while four episodes
        // autoplayed on the TV and every stop failed (each hand-off flushes the finished episode,
        // then its failed stop keeps the rows).
        val snapshot = listOf(simklRow(episode = 1, percent = 40f, updatedAt = minutes(10)))
        val overlay = SimklOptimisticProgressOverlay()
        listOf(1 to 60, 2 to 105, 3 to 150).forEach { (episode, at) ->
            overlay.put(PROFILE, localRow(episode = episode, completed = true, updatedAt = minutes(at)), minutes(at))
            overlay.hold(PROFILE, listOf("tt0944947"), minutes(at) + TrackerOptimisticFailedStopRetentionMs, minutes(at))
        }
        overlay.put(PROFILE, localRow(episode = 4, positionMin = 12, updatedAt = minutes(162)), minutes(162))

        val withoutOverlay = row(snapshot)
        val merged = overlay.merge(PROFILE, snapshot, minutes(163))

        assertEquals(listOf(1), withoutOverlay.map { it.episodeNumber })
        assertEquals(listOf(4, 3, 2, 1), merged.map { it.episodeNumber })
        assertTrue(merged.last().isCompleted, "the local completion replaces Simkl's paused S1E1")
        assertEquals(listOf(4), row(merged).map { it.episodeNumber })
    }

    @Test
    fun `a newer local row replaces Simkl's row of the same episode and takes its session key`() {
        val snapshot = listOf(simklRow(episode = 3, percent = 20f, updatedAt = minutes(10), sessionId = 777))
        val overlay = SimklOptimisticProgressOverlay()
        overlay.put(PROFILE, localRow(episode = 3, positionMin = 36, updatedAt = minutes(90)), minutes(90))

        val merged = overlay.merge(PROFILE, snapshot, minutes(91))

        val episode3 = merged.single()
        assertEquals(minutes(90), episode3.lastUpdatedEpochMs)
        assertEquals(36L * 60_000L, episode3.lastPositionMs)
        // A removal from Continue Watching still deletes the Simkl session behind the row.
        assertEquals("simkl-playback:777", episode3.progressKey)
    }

    @Test
    fun `a newer Simkl row wins over an older local one`() {
        // Watched further on the phone after the TV's session.
        val snapshot = listOf(simklRow(episode = 3, percent = 75f, updatedAt = minutes(200)))
        val overlay = SimklOptimisticProgressOverlay()
        overlay.put(PROFILE, localRow(episode = 3, positionMin = 20, updatedAt = minutes(100)), minutes(100))

        val merged = overlay.merge(PROFILE, snapshot, minutes(101))

        assertEquals(listOf(75f), merged.map { it.progressPercent })
    }

    @Test
    fun `a snapshot that confirms a row drops it, one that does not keeps it`() {
        val overlay = SimklOptimisticProgressOverlay()
        overlay.put(PROFILE, localRow(episode = 3, positionMin = 30, updatedAt = minutes(100)), minutes(100))

        // The stop failed: Simkl still has the old session.
        val stale = listOf(simklRow(episode = 3, percent = 20f, updatedAt = minutes(10)))
        assertFalse(overlay.reconcile(stale, minutes(101)))
        assertEquals(30L * 60_000L, overlay.merge(PROFILE, stale, minutes(101)).single().lastPositionMs)

        // The stop committed: a paused session at the same point (50 % of the hour).
        val committed = listOf(simklRow(episode = 3, percent = 50f, updatedAt = minutes(100)))
        assertTrue(overlay.reconcile(committed, minutes(101)))
        assertTrue(overlay.isEmpty)
        assertEquals(committed, overlay.merge(PROFILE, committed, minutes(101)))
    }

    @Test
    fun `rows expire after the TTL`() {
        val snapshot = listOf(simklRow(episode = 1, percent = 40f, updatedAt = minutes(10)))
        val overlay = SimklOptimisticProgressOverlay()
        overlay.put(PROFILE, localRow(episode = 2, positionMin = 5, updatedAt = minutes(100)), minutes(100))

        assertEquals(2, overlay.merge(PROFILE, snapshot, minutes(100) + TrackerOptimisticProgressTtlMs - 1).size)
        assertEquals(snapshot, overlay.merge(PROFILE, snapshot, minutes(100) + TrackerOptimisticProgressTtlMs))
    }

    @Test
    fun `a failed stop keeps the rows for a day, and a later flush does not shorten that`() {
        val snapshot = listOf(simklRow(episode = 1, percent = 40f, updatedAt = minutes(10)))
        val overlay = SimklOptimisticProgressOverlay()
        val now = minutes(100)
        overlay.put(PROFILE, localRow(episode = 2, positionMin = 30, updatedAt = now), now)

        assertEquals(1, overlay.hold(PROFILE, listOf("tt0944947"), now + TrackerOptimisticStopInFlightHoldMs, now))
        assertEquals(1, overlay.hold(PROFILE, listOf("tt0944947"), now + TrackerOptimisticFailedStopRetentionMs, now))
        // The app goes to the background on the end screen: the same position is flushed again.
        overlay.put(PROFILE, localRow(episode = 2, positionMin = 30, updatedAt = now + 60_000L), now + 60_000L)

        val twentyHoursLater = now + 20L * 60L * 60_000L
        val merged = overlay.merge(PROFILE, snapshot, twentyHoursLater)
        assertEquals(listOf(2, 1), merged.map { it.episodeNumber })
        assertEquals(listOf(2), row(merged).map { it.episodeNumber })
        assertEquals(snapshot, overlay.merge(PROFILE, snapshot, now + TrackerOptimisticFailedStopRetentionMs + 60_000L))
    }

    @Test
    fun `hold only touches the title's live rows`() {
        val overlay = SimklOptimisticProgressOverlay()
        overlay.put(PROFILE, localRow(episode = 2, positionMin = 30, updatedAt = minutes(100)), minutes(100))
        overlay.put(PROFILE, localRow(episode = 1, positionMin = 3, updatedAt = minutes(100), contentId = "tt0903747"), minutes(100))

        assertEquals(0, overlay.hold(PROFILE, listOf("tt9999999"), minutes(10_000), minutes(100)))
        assertEquals(0, overlay.hold(OTHER_PROFILE, listOf("tt0944947"), minutes(10_000), minutes(100)))
        assertEquals(1, overlay.hold(PROFILE, listOf(" tt0944947 "), minutes(10_000), minutes(100)))
        // Expired rows are not brought back.
        assertEquals(0, overlay.hold(PROFILE, listOf("tt0903747"), minutes(10_000), minutes(100) + TrackerOptimisticProgressTtlMs))
    }

    @Test
    fun `a delivered stop brings the held rows back to the plain TTL`() {
        val snapshot = listOf(simklRow(episode = 1, percent = 40f, updatedAt = minutes(10)))
        val overlay = SimklOptimisticProgressOverlay()
        val now = minutes(100)
        val heldUntil = now + TrackerOptimisticStopInFlightHoldMs
        overlay.put(PROFILE, localRow(episode = 2, completed = true, updatedAt = now), now)
        overlay.put(PROFILE, localRow(episode = 1, positionMin = 3, updatedAt = now, contentId = "tt0903747"), now)
        overlay.hold(PROFILE, listOf("tt0944947", "tt0903747"), heldUntil, now)

        val deliveredAt = now + 30_000L
        val ttlFromDelivery = deliveredAt + TrackerOptimisticProgressTtlMs
        assertEquals(0, overlay.release(OTHER_PROFILE, listOf("tt0944947"), ttlFromDelivery, heldUntil))
        assertEquals(1, overlay.release(PROFILE, listOf("tt0944947"), ttlFromDelivery, heldUntil))

        // The delivered title is gone once the TTL has run from the delivery; the other title is
        // still held, because its stop is still on the way.
        assertEquals(listOf("tt0903747", "tt0944947"), overlay.merge(PROFILE, snapshot, ttlFromDelivery).map { it.parentMetaId })
        // A row due to expire sooner is not extended.
        assertEquals(0, overlay.release(PROFILE, listOf("tt0903747"), heldUntil + 60_000L, heldUntil + 120_000L))
    }

    @Test
    fun `a delivered stop leaves the day-long hold of a failed one`() {
        val overlay = SimklOptimisticProgressOverlay()
        val now = minutes(100)
        overlay.put(PROFILE, localRow(episode = 2, completed = true, updatedAt = now), now)
        // E2's stop failed: its rows are kept for a day.
        overlay.hold(PROFILE, listOf("tt0944947"), now + TrackerOptimisticFailedStopRetentionMs, now)
        // A later stop of the show holds, then is delivered.
        val later = now + 60_000L
        val heldUntil = later + TrackerOptimisticStopInFlightHoldMs
        overlay.put(PROFILE, localRow(episode = 3, positionMin = 20, updatedAt = later), later)
        overlay.hold(PROFILE, listOf("tt0944947"), heldUntil, later)

        assertEquals(1, overlay.release(PROFILE, listOf("tt0944947"), later + TrackerOptimisticProgressTtlMs, heldUntil))

        val twoHoursLater = now + 2L * 60L * 60_000L
        assertEquals(listOf(2), overlay.merge(PROFILE, emptyList(), twoHoursLater).map { it.episodeNumber })
    }

    @Test
    fun `rows belong to the profile that wrote them`() {
        val snapshot = listOf(simklRow(episode = 1, percent = 40f, updatedAt = minutes(10)))
        val overlay = SimklOptimisticProgressOverlay()
        overlay.put(PROFILE, localRow(episode = 2, positionMin = 5, updatedAt = minutes(100)), minutes(100))

        assertEquals(snapshot, overlay.merge(OTHER_PROFILE, snapshot, minutes(101)))

        overlay.put(OTHER_PROFILE, localRow(episode = 7, positionMin = 5, updatedAt = minutes(102)), minutes(102))
        assertEquals(snapshot, overlay.merge(PROFILE, snapshot, minutes(103)))
        assertEquals(listOf(7, 1), overlay.merge(OTHER_PROFILE, snapshot, minutes(103)).map { it.episodeNumber })
    }

    @Test
    fun `a removal from Continue Watching drops the rows of those episodes`() {
        val overlay = SimklOptimisticProgressOverlay()
        overlay.put(PROFILE, localRow(episode = 2, positionMin = 5, updatedAt = minutes(100)), minutes(100))
        overlay.put(PROFILE, localRow(episode = 3, positionMin = 5, updatedAt = minutes(101)), minutes(101))
        overlay.put(PROFILE, localRow(episode = 4, positionMin = 5, updatedAt = minutes(102)), minutes(102))

        assertTrue(overlay.removeEpisodes(listOf(simklRow(episode = 3, percent = 10f, updatedAt = minutes(1)))))
        assertTrue(overlay.removeVideoIds(listOf("tt0944947:1:4")))
        assertFalse(overlay.removeVideoIds(listOf("tt0944947:1:9")))

        assertEquals(listOf(2), overlay.merge(PROFILE, emptyList(), minutes(102)).map { it.episodeNumber })
        assertTrue(overlay.clear())
        assertTrue(overlay.isEmpty)
    }

    @Test
    fun `an older write of an episode is ignored`() {
        val overlay = SimklOptimisticProgressOverlay()
        assertTrue(overlay.put(PROFILE, localRow(episode = 2, positionMin = 30, updatedAt = minutes(100)), minutes(100)))
        assertFalse(overlay.put(PROFILE, localRow(episode = 2, positionMin = 10, updatedAt = minutes(90)), minutes(100)))

        assertEquals(30L * 60_000L, overlay.merge(PROFILE, emptyList(), minutes(101)).single().lastPositionMs)
    }

    private fun row(entries: List<WatchProgressEntry>): List<WatchProgressEntry> =
        buildContinueWatchingRowEntries(
            entries = entries,
            isDroppedShow = { false },
            recencyCutoffEpochMs = null,
        )

    private fun minutes(value: Int): Long = BASE_EPOCH_MS + value * 60_000L

    private fun localRow(
        episode: Int,
        updatedAt: Long,
        positionMin: Int = 0,
        completed: Boolean = false,
        contentId: String = "tt0944947",
    ) = WatchProgressEntry(
        contentType = "series",
        parentMetaId = contentId,
        parentMetaType = "series",
        videoId = "$contentId:1:$episode",
        title = "Game of Thrones",
        seasonNumber = 1,
        episodeNumber = episode,
        lastPositionMs = if (completed) HOUR_MS else positionMin * 60_000L,
        durationMs = HOUR_MS,
        lastUpdatedEpochMs = updatedAt,
        isCompleted = completed,
        progressKey = "${contentId}_s1e$episode",
    )

    private fun simklRow(
        episode: Int,
        percent: Float,
        updatedAt: Long,
        sessionId: Long = 700L + episode,
    ) = WatchProgressEntry(
        contentType = "series",
        parentMetaId = "tt0944947",
        parentMetaType = "series",
        videoId = "tt0944947:1:$episode",
        title = "Game of Thrones",
        seasonNumber = 1,
        episodeNumber = episode,
        lastPositionMs = 0L,
        durationMs = 0L,
        lastUpdatedEpochMs = updatedAt,
        progressPercent = percent,
        source = WatchProgressSourceSimklPlayback,
        progressKey = "simkl-playback:$sessionId",
    )

    private companion object {
        const val PROFILE = 1
        const val OTHER_PROFILE = 2
        const val HOUR_MS = 3_600_000L
        const val BASE_EPOCH_MS = 1_790_000_000_000L
    }
}
