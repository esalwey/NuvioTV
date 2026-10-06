package com.nuvio.app.features.watchprogress

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Ported from upstream `RemoteProgressWriteDeduplicatorTest` (composeApp) — shared/'s
 * `WatchProgressRepository.upsert()` reuses the same dedup gate on both the cross-profile and
 * local-profile write paths.
 */
class RemoteProgressWriteDeduplicatorTest {
    @Test
    fun `identical progress is suppressed inside dedupe window`() {
        val deduplicator = RemoteProgressWriteDeduplicator(windowMs = 5_000L)
        val entry = progressEntry(positionMs = 30_000L, updatedAtEpochMs = 1_000L)

        assertTrue(deduplicator.shouldSend(profileId = 1, entry = entry, nowEpochMs = 1_000L))
        assertFalse(
            deduplicator.shouldSend(
                profileId = 1,
                entry = entry.copy(lastUpdatedEpochMs = 1_100L),
                nowEpochMs = 1_100L,
            ),
        )
    }

    @Test
    fun `changed progress is sent inside dedupe window`() {
        val deduplicator = RemoteProgressWriteDeduplicator(windowMs = 5_000L)
        val entry = progressEntry(positionMs = 30_000L, updatedAtEpochMs = 1_000L)

        assertTrue(deduplicator.shouldSend(profileId = 1, entry = entry, nowEpochMs = 1_000L))
        assertTrue(
            deduplicator.shouldSend(
                profileId = 1,
                entry = entry.copy(lastPositionMs = 31_000L, lastUpdatedEpochMs = 1_100L),
                nowEpochMs = 1_100L,
            ),
        )
    }

    @Test
    fun `identical progress is sent after dedupe window`() {
        val deduplicator = RemoteProgressWriteDeduplicator(windowMs = 5_000L)
        val entry = progressEntry(positionMs = 30_000L, updatedAtEpochMs = 1_000L)

        assertTrue(deduplicator.shouldSend(profileId = 1, entry = entry, nowEpochMs = 1_000L))
        assertTrue(
            deduplicator.shouldSend(
                profileId = 1,
                entry = entry.copy(lastUpdatedEpochMs = 6_000L),
                nowEpochMs = 6_000L,
            ),
        )
    }

    // Fork-only (Codex 2026-08-24 P1): a failed push rolls its key back so identical rewrites
    // inside the window are no longer suppressed.
    @Test
    fun `cleared key sends identical progress inside dedupe window`() {
        val deduplicator = RemoteProgressWriteDeduplicator(windowMs = 5_000L)
        val entry = progressEntry(positionMs = 30_000L, updatedAtEpochMs = 1_000L)

        assertTrue(deduplicator.shouldSend(profileId = 1, entry = entry, nowEpochMs = 1_000L))
        deduplicator.clearEntry(profileId = 1, progressKey = entry.resolvedProgressKey())
        assertTrue(
            deduplicator.shouldSend(
                profileId = 1,
                entry = entry.copy(lastUpdatedEpochMs = 1_100L),
                nowEpochMs = 1_100L,
            ),
        )
    }

    private fun progressEntry(
        positionMs: Long,
        updatedAtEpochMs: Long,
    ) = WatchProgressEntry(
        contentType = "series",
        parentMetaId = "tt123",
        parentMetaType = "series",
        videoId = "tt123:1:1",
        title = "Episode",
        seasonNumber = 1,
        episodeNumber = 1,
        lastPositionMs = positionMs,
        durationMs = 60_000L,
        lastUpdatedEpochMs = updatedAtEpochMs,
    )
}
