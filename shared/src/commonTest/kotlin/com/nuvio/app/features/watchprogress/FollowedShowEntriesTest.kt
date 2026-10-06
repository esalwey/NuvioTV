package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.upcoming.collectUpcomingShowRefs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * BUG-76: the Upcoming row seeds from progress ∪ library and must not change when the user flips
 * the watch-progress SOURCE — that row is an air-date calendar keyed off shows the user follows,
 * not off whichever provider currently owns Continue Watching.
 */
class FollowedShowEntriesTest {
    private fun episode(showId: String, lastUpdatedEpochMs: Long): WatchProgressEntry =
        WatchProgressEntry(
            contentType = "series",
            parentMetaId = showId,
            parentMetaType = "series",
            videoId = "$showId:1:1",
            title = showId,
            seasonNumber = 1,
            episodeNumber = 1,
            lastPositionMs = 10_000L,
            durationMs = 100_000L,
            lastUpdatedEpochMs = lastUpdatedEpochMs,
        )

    @Test
    fun union_keeps_local_entries_when_the_provider_has_no_history() {
        val local = listOf(episode("tt-local", 1_000L))

        val followed = unionFollowedShowEntries(nuvioEntries = local, providerEntries = emptyList())

        assertEquals(local, followed)
    }

    @Test
    fun union_keeps_a_show_known_only_to_a_now_inactive_provider() {
        // The case that makes this fix actually work for a Trakt user: Trakt-imported history
        // lives in Trakt's snapshot and never in the local store, so after flipping to an empty
        // Simkl the followed set must still carry it — otherwise Upcoming empties anyway.
        val local = emptyList<WatchProgressEntry>()
        val trakt = listOf(episode("tt-trakt-only", 5_000L))
        val simkl = emptyList<WatchProgressEntry>()

        val followed = unionFollowedShowEntries(
            nuvioEntries = local,
            providerEntries = trakt + simkl,
        )

        assertEquals(listOf("tt-trakt-only"), followed.map { it.parentMetaId })
    }

    @Test
    fun union_dedupes_a_show_two_providers_both_know_keeping_the_newer_row() {
        val shared = "tt-both-providers"
        val trakt = listOf(episode(shared, 5_000L))
        val simkl = listOf(episode(shared, 8_000L))

        val followed = unionFollowedShowEntries(
            nuvioEntries = emptyList(),
            providerEntries = trakt + simkl,
        )

        assertEquals(1, followed.size)
        assertEquals(8_000L, followed.single().lastUpdatedEpochMs)
    }

    @Test
    fun union_prefers_the_more_recent_row_for_a_show_local_and_provider_both_know() {
        val shared = "tt-shared"
        val local = listOf(episode(shared, 1_000L))
        val provider = listOf(episode(shared, 9_000L))

        val followed = unionFollowedShowEntries(nuvioEntries = local, providerEntries = provider)

        assertEquals(1, followed.size)
        assertEquals(9_000L, followed.single().lastUpdatedEpochMs)
    }

    @Test
    fun union_carries_local_only_shows_alongside_provider_rows() {
        val local = listOf(episode("tt-local", 1_000L))
        val provider = listOf(episode("tt-provider", 2_000L))

        val followed = unionFollowedShowEntries(nuvioEntries = local, providerEntries = provider)

        assertEquals(
            setOf("tt-local", "tt-provider"),
            followed.mapTo(mutableSetOf()) { it.parentMetaId },
        )
    }

    /**
     * The regression itself, stated as the contrast that caused it: the SOURCE projection empties
     * when a provider owns the source and has no history (correct for Continue Watching), while
     * the followed set — and therefore the Upcoming seed — must not.
     */
    @Test
    fun a_source_flip_to_an_empty_provider_empties_continue_watching_but_not_the_upcoming_seed() {
        val local = listOf(episode("tt-followed", 1_000L))
        val emptySimkl = emptyList<WatchProgressEntry>()

        val continueWatchingEntries = projectWatchProgressSourceEntries(
            source = WatchProgressSource.SIMKL,
            nuvioEntries = local,
            providerEntries = emptySimkl,
        )
        val followed = unionFollowedShowEntries(nuvioEntries = local, providerEntries = emptySimkl)

        assertTrue(continueWatchingEntries.isEmpty(), "the source projection is expected to empty")
        assertEquals(local, followed, "the followed set must survive the flip")

        // And the seed the Upcoming sweep actually builds survives with it.
        val refsBefore = collectUpcomingShowRefs(
            progressEntries = local,
            libraryItems = emptyList(),
        )
        val refsAfter = collectUpcomingShowRefs(
            progressEntries = followed,
            libraryItems = emptyList(),
        )
        assertEquals(refsBefore.map { it.key }, refsAfter.map { it.key })
        assertTrue(refsAfter.isNotEmpty(), "the Upcoming seed must not go empty on a source flip")
    }
}
