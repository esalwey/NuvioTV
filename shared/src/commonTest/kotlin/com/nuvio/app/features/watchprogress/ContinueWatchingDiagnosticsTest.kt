package com.nuvio.app.features.watchprogress

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** CW legacy diagnosis (REMAINING_FIX #1): the Continue Watching report of Settings > About. */
class ContinueWatchingDiagnosticsTest {
    private val now = 1_800_000_000_000L

    private fun episode(
        showId: String,
        episode: Int,
        updatedAt: Long,
        title: String = "Breaking Bad",
        completed: Boolean = false,
    ): WatchProgressEntry = WatchProgressEntry(
        contentType = "series",
        parentMetaId = showId,
        parentMetaType = "series",
        videoId = "$showId:1:$episode",
        title = title,
        seasonNumber = 1,
        episodeNumber = episode,
        lastPositionMs = if (completed) 2_700_000L else 600_000L,
        durationMs = 2_800_000L,
        lastUpdatedEpochMs = updatedAt,
        isCompleted = completed,
    )

    private fun report(
        entries: List<WatchProgressEntry>,
        rowEntries: List<WatchProgressEntry> = entries.continueWatchingEntries(),
        dirtyKeys: Set<String> = emptySet(),
        maxLines: Int = ContinueWatchingDiagnosticsMaxLines,
    ): List<String> = buildContinueWatchingDiagnosticLines(
        header = listOf("header"),
        entries = entries,
        dirtyKeys = dirtyKeys,
        rowEntries = rowEntries,
        nowEpochMs = now,
        maxLines = maxLines,
    )

    private fun List<String>.cardLine(showId: String): String = single { it.startsWith("card $showId ") }

    @Test
    fun `a card dated ahead of the clock is flagged FUTURE`() {
        val future = episode("tt0903747", episode = 2, updatedAt = now + 3_600_000L)
        val present = episode("tt0944947", episode = 3, updatedAt = now - 30_000L, title = "Game of Thrones")

        val lines = report(listOf(future, present))

        // The marker comes right after the id, where a narrow screen never cuts it.
        assertTrue(lines.cardLine("tt0903747").startsWith("card tt0903747 FUTURE S1E2 "), lines.cardLine("tt0903747"))
        assertTrue("d=+60m" in lines.cardLine("tt0903747"), lines.cardLine("tt0903747"))
        assertFalse("FUTURE" in lines.cardLine("tt0944947"))
        // The row behind the card carries the flag too.
        assertTrue(lines.any { it.startsWith("row tt0903747 ") && it.endsWith(" FUTURE") })
    }

    @Test
    fun `a minute of clock skew is not FUTURE`() {
        val lines = report(listOf(episode("tt0903747", episode = 2, updatedAt = now + 59_000L)))

        assertFalse("FUTURE" in lines.cardLine("tt0903747"))
    }

    @Test
    fun `the same title under another id is flagged ALIAS`() {
        // The legacy card under the TMDB id and the chain under the IMDb id: two cards of one show.
        val legacy = episode("tmdb:1396", episode = 1, updatedAt = now - 86_400_000L)
        val chain = episode("tt0903747", episode = 5, updatedAt = now - 60_000L)
        val other = episode("tt0944947", episode = 3, updatedAt = now - 120_000L, title = "Game of Thrones")

        val lines = report(listOf(legacy, chain, other))

        assertTrue(lines.cardLine("tmdb:1396").startsWith("card tmdb:1396 ALIAS? "))
        assertTrue(lines.cardLine("tt0903747").startsWith("card tt0903747 ALIAS? "))
        assertFalse("ALIAS?" in lines.cardLine("tt0944947"))
    }

    @Test
    fun `an alias whose rows are all finished is still found and listed`() {
        // The chain ended on the Up Next card: its series has no card any more, only the legacy one.
        val legacy = episode("tmdb:1396", episode = 1, updatedAt = now - 86_400_000L)
        val chainEnd = episode("tt0903747", episode = 5, updatedAt = now - 60_000L, completed = true)

        val lines = report(listOf(legacy, chainEnd))

        assertEquals(listOf("tmdb:1396"), lines.filter { it.startsWith("card ") }.map { it.split(' ')[1] })
        assertTrue(" ALIAS? " in lines.cardLine("tmdb:1396"))
        assertTrue(lines.any { it.startsWith("row tt0903747 ") && " done=1 " in it })
    }

    @Test
    fun `a title that is only the id is no alias evidence`() {
        // Rows pulled before their metadata resolved carry their id as the title.
        val first = episode("tmdb:1396", episode = 1, updatedAt = now - 5_000L, title = "tmdb:1396")
        val second = episode("tmdb:1397", episode = 1, updatedAt = now - 6_000L, title = "tmdb:1397")

        val lines = report(listOf(first, second))

        assertTrue(lines.none { "ALIAS?" in it })
    }

    @Test
    fun `row lines show the key, the dirty state and the position`() {
        val synced = episode("tt0903747", episode = 1, updatedAt = now - 7_200_000L, completed = true)
        val opaque = episode("tt0903747", episode = 2, updatedAt = now - 30_000L).copy(progressKey = "srv-42")

        val lines = report(listOf(synced, opaque), dirtyKeys = setOf("srv-42"))

        assertEquals(
            listOf(
                "row tt0903747 k=srv-42 v=syn S1E2 d=-30s done=0 dirty=1 600/2800s",
                "row tt0903747 k=syn v=syn S1E1 d=-2h done=1 dirty=0 2700/2800s",
            ),
            lines.filter { it.startsWith("row ") },
        )
    }

    @Test
    fun `the report is capped with a count of what it left out`() {
        val entries = (1..40).map { number ->
            episode("tt$number", episode = 1, updatedAt = now - number * 1_000L, title = "Show $number")
        }

        val lines = report(entries, maxLines = 20)

        assertEquals(20, lines.size)
        assertEquals("header", lines.first())
        assertTrue(lines.last().endsWith("more lines not shown"), lines.last())
    }

    // With the row's series grouping (REMAINING_FIX #2).

    private val breakingBad: (String) -> String = { id ->
        if (id.trim() == "tmdb:1396") "tt0903747" else id.trim()
    }

    private fun groupedReport(
        entries: List<WatchProgressEntry>,
        nextUpSeeds: List<ContinueWatchingNextUpSeed> = emptyList(),
    ): List<String> = buildContinueWatchingDiagnosticLines(
        header = listOf("header"),
        entries = entries,
        dirtyKeys = emptySet(),
        rowEntries = buildContinueWatchingRowEntries(
            entries = entries,
            isDroppedShow = { false },
            recencyCutoffEpochMs = null,
            canonicalSeriesId = breakingBad,
        ),
        nowEpochMs = now,
        nextUpSeeds = nextUpSeeds,
        canonicalSeriesId = breakingBad,
    )

    @Test
    fun `ids the row groups together are MERGED, not ALIAS`() {
        val legacy = episode("tmdb:1396", episode = 1, updatedAt = now - 86_400_000L)
        val chain = episode("tt0903747", episode = 5, updatedAt = now - 60_000L)

        val lines = groupedReport(listOf(legacy, chain))

        assertEquals(
            listOf("card tt0903747 MERGED S1E5 d=-60s local \"Breaking Bad\""),
            lines.filter { it.startsWith("card ") },
        )
        // The merged id's rows follow the card's.
        assertEquals(listOf("tt0903747", "tmdb:1396"), lines.filter { it.startsWith("row ") }.map { it.split(' ')[1] })
    }

    @Test
    fun `a card stored under another id shows the IMDb id it is grouped under`() {
        val resumed = episode("tmdb:1396", episode = 6, updatedAt = now - 10_000L)
        val chainEnd = episode("tt0903747", episode = 5, updatedAt = now - 60_000L, completed = true)
        val seed = ContinueWatchingNextUpSeed(
            contentId = "tmdb:1396",
            contentType = "series",
            seasonNumber = 1,
            episodeNumber = 5,
            markedAtEpochMs = now - 60_000L,
        )

        val lines = groupedReport(listOf(resumed, chainEnd), nextUpSeeds = listOf(seed))

        assertEquals(
            listOf("card tmdb:1396 id=tt0903747 MERGED S1E6 d=-10s local \"Breaking Bad\""),
            lines.filter { it.startsWith("card ") },
        )
        assertEquals(listOf("seed tmdb:1396 id=tt0903747 S1E5 d=-60s up=?"), lines.filter { it.startsWith("seed ") })
    }

    @Test
    fun `a seed line says what its Up Next card resolved to`() {
        val chainEnd = episode("tt0903747", episode = 5, updatedAt = now - 60_000L, completed = true)
        val resolved = ContinueWatchingNextUpSeed("tt0903747", "series", 1, 5, now - 60_000L)
        val empty = ContinueWatchingNextUpSeed("tt0944947", "series", 8, 6, now - 120_000L)
        val failed = ContinueWatchingNextUpSeed("tt0386676", "series", 2, 3, now - 180_000L)

        val lines = buildContinueWatchingDiagnosticLines(
            header = listOf("header"),
            entries = listOf(chainEnd),
            dirtyKeys = emptySet(),
            rowEntries = emptyList(),
            nowEpochMs = now,
            nextUpSeeds = listOf(resolved, empty, failed),
            nextUpOutcomes = mapOf(resolved.dismissKey to "S1E6", empty.dismissKey to "none"),
        )

        assertEquals(
            listOf(
                "seed tt0903747 S1E5 d=-60s up=S1E6",
                "seed tt0944947 S8E6 d=-2m up=none",
                "seed tt0386676 S2E3 d=-3m up=?",
            ),
            lines.filter { it.startsWith("seed ") },
        )
    }

    @Test
    fun `a long title comes last and is cut`() {
        val card = episode(
            "tt7631058",
            episode = 4,
            updatedAt = now - 30_000L,
            title = "The Lord of the Rings: The Rings of Power",
        )

        val lines = report(listOf(card))

        assertEquals("card tt7631058 S1E4 d=-30s local \"The Lord of the Rin…\"", lines.cardLine("tt7631058"))
    }

    @Test
    fun `ages read at a glance`() {
        assertEquals("-40s", diagnosticAge(now - 40_000L, now))
        assertEquals("-12m", diagnosticAge(now - 12 * 60_000L, now))
        assertEquals("-5h", diagnosticAge(now - 5 * 3_600_000L, now))
        assertEquals("-30d", diagnosticAge(now - 30 * 86_400_000L, now))
        assertEquals("+2h", diagnosticAge(now + 2 * 3_600_000L, now))
        assertEquals("t0", diagnosticAge(0L, now))
    }
}
