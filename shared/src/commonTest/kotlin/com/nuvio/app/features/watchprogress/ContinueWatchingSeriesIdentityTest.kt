package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.watched.WatchedItem
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * CW alias fix (REMAINING_FIX #2): one show stored under a TMDB and an IMDb id is one series for
 * the Continue Watching row, and only for its display.
 */
class ContinueWatchingSeriesIdentityTest {
    private val tmdbId = "tmdb:1396"
    private val imdbId = "tt0903747"

    /** The mapping the row learns for Breaking Bad; everything else is its own series. */
    private val breakingBad: (String) -> String = { id ->
        when (id.trim()) {
            tmdbId -> imdbId
            else -> id.trim()
        }
    }
    private val unmapped: (String) -> String = { id -> id.trim() }

    @AfterTest
    fun clearIdentity() {
        ContinueWatchingSeriesIdentity.clear()
    }

    private fun episode(
        showId: String,
        episode: Int,
        updatedAt: Long,
        completed: Boolean = false,
    ): WatchProgressEntry = WatchProgressEntry(
        contentType = "series",
        parentMetaId = showId,
        parentMetaType = "series",
        videoId = "$showId:1:$episode",
        title = "Breaking Bad",
        seasonNumber = 1,
        episodeNumber = episode,
        lastPositionMs = if (completed) 2_700_000L else 600_000L,
        durationMs = 2_800_000L,
        lastUpdatedEpochMs = updatedAt,
        isCompleted = completed,
    )

    private fun movie(id: String, updatedAt: Long): WatchProgressEntry = WatchProgressEntry(
        contentType = "movie",
        parentMetaId = id,
        parentMetaType = "movie",
        videoId = id,
        title = id,
        lastPositionMs = 600_000L,
        durationMs = 6_000_000L,
        lastUpdatedEpochMs = updatedAt,
    )

    private fun row(entries: List<WatchProgressEntry>, canonical: (String) -> String) =
        buildContinueWatchingRowEntries(
            entries = entries,
            isDroppedShow = { false },
            recencyCutoffEpochMs = null,
            canonicalSeriesId = canonical,
        )

    private fun seeds(
        entries: List<WatchProgressEntry>,
        canonical: (String) -> String,
        watchedItems: List<WatchedItem> = emptyList(),
    ) = buildContinueWatchingNextUpSeeds(
        progressEntries = entries,
        watchedItems = watchedItems,
        inProgressEntries = row(entries, canonical),
        preferFurthestEpisode = true,
        dismissedNextUpKeys = emptySet(),
        recencyCutoffEpochMs = null,
        limit = 20,
        canonicalSeriesId = canonical,
    )

    // The row

    @Test
    fun `a show under a TMDB and an IMDb id is one card, the newest row of both`() {
        val legacy = episode(tmdbId, episode = 1, updatedAt = 1_000L)
        val chain = episode(imdbId, episode = 5, updatedAt = 5_000L)

        val result = row(listOf(legacy, chain), breakingBad)

        assertEquals(listOf("$imdbId:1:5"), result.map { it.videoId })
    }

    @Test
    fun `the newest row wins whichever id it was stored under`() {
        val chain = episode(imdbId, episode = 5, updatedAt = 5_000L)
        val resumedFromTheOldCard = episode(tmdbId, episode = 6, updatedAt = 6_000L)

        val result = row(listOf(chain, resumedFromTheOldCard), breakingBad)

        // The card keeps its own stored id: it launches under the id its progress was written with.
        assertEquals(listOf("$tmdbId:1:6"), result.map { it.videoId })
        assertEquals(tmdbId, result.single().parentMetaId)
    }

    @Test
    fun `a finished chain leaves no card and one Up Next seed`() {
        // The legacy card, then a chain under the IMDb id that ended on the Up Next card.
        val legacy = episode(tmdbId, episode = 1, updatedAt = 1_000L)
        val chainEnd = episode(imdbId, episode = 5, updatedAt = 5_000L, completed = true)
        val entries = listOf(legacy, chainEnd)

        assertTrue(row(entries, breakingBad).isEmpty())
        val result = seeds(entries, breakingBad)
        assertEquals(1, result.size)
        assertEquals(imdbId, result.single().contentId)
        assertEquals(5, result.single().episodeNumber)
    }

    @Test
    fun `a finished episode under each id is still one seed, the most recent`() {
        val legacyDone = episode(tmdbId, episode = 2, updatedAt = 2_000L, completed = true)
        val chainEnd = episode(imdbId, episode = 5, updatedAt = 5_000L, completed = true)

        val result = seeds(listOf(legacyDone, chainEnd), breakingBad)

        assertEquals(listOf(imdbId to 5), result.map { it.contentId to it.episodeNumber })
    }

    @Test
    fun `an in-progress card under one id suppresses the seed of the other`() {
        val chainEnd = episode(imdbId, episode = 5, updatedAt = 5_000L, completed = true)
        val resumed = episode(tmdbId, episode = 6, updatedAt = 6_000L)

        assertTrue(seeds(listOf(chainEnd, resumed), breakingBad).isEmpty())
    }

    @Test
    fun `unmapped ids stay separate series as before`() {
        val legacy = episode(tmdbId, episode = 1, updatedAt = 1_000L)
        val chainEnd = episode(imdbId, episode = 5, updatedAt = 5_000L, completed = true)
        val entries = listOf(legacy, chainEnd)

        assertEquals(listOf("$tmdbId:1:1"), row(entries, unmapped).map { it.videoId })
        // The legacy card's in-progress row does not suppress the other id's seed.
        assertEquals(listOf(imdbId), seeds(entries, unmapped).map { it.contentId })
        // The row's default grouping is the learned one, and nothing is learned yet.
        assertEquals(
            row(entries, unmapped),
            buildContinueWatchingRowEntries(entries = entries, isDroppedShow = { false }, recencyCutoffEpochMs = null),
        )
    }

    @Test
    fun `the merged row keeps one card per series next to Up Next cards`() {
        val inProgress = episode(tmdbId, episode = 6, updatedAt = 6_000L)
        val upNextOfTheOtherId = episode(imdbId, episode = 6, updatedAt = 5_000L).copy(
            lastPositionMs = 0L,
            source = WatchProgressSourceNextUp,
        )
        val otherShowUpNext = episode("tt0944947", episode = 2, updatedAt = 4_000L).copy(
            lastPositionMs = 0L,
            source = WatchProgressSourceNextUp,
        )

        val merged = mergeContinueWatchingNextUp(
            inProgressEntries = listOf(inProgress),
            nextUpEntries = listOf(upNextOfTheOtherId, otherShowUpNext),
            canonicalSeriesId = breakingBad,
        )
        val unmerged = mergeContinueWatchingNextUp(
            inProgressEntries = listOf(inProgress),
            nextUpEntries = listOf(upNextOfTheOtherId, otherShowUpNext),
            canonicalSeriesId = unmapped,
        )

        assertEquals(listOf("$tmdbId:1:6", "tt0944947:1:2"), merged.map { it.videoId })
        assertEquals(3, unmerged.size)
    }

    @Test
    fun `a movie is never grouped with a series of the same id`() {
        // tmdb movie 1396 and tmdb series 1396 are different titles.
        val movieCard = movie(tmdbId, updatedAt = 6_000L)
        val seriesCard = episode(imdbId, episode = 2, updatedAt = 5_000L)

        val result = row(listOf(movieCard, seriesCard), breakingBad)
        val merged = mergeContinueWatchingNextUp(
            inProgressEntries = result,
            nextUpEntries = listOf(episode("tt0944947", 1, 1_000L).copy(source = WatchProgressSourceNextUp)),
            canonicalSeriesId = breakingBad,
        )

        assertEquals(listOf(tmdbId, imdbId), result.map { it.parentMetaId })
        assertEquals(listOf(tmdbId, imdbId, "tt0944947"), merged.map { it.parentMetaId })
    }

    // Removal

    @Test
    fun `removing a series card removes every id of the series`() {
        val entries = listOf(
            episode(tmdbId, episode = 1, updatedAt = 1_000L),
            episode(tmdbId, episode = 2, updatedAt = 2_000L),
            episode(imdbId, episode = 5, updatedAt = 5_000L),
            episode("tt0944947", episode = 3, updatedAt = 3_000L),
        )

        assertEquals(
            listOf(imdbId, tmdbId),
            continueWatchingSeriesContentIds(entries, card = entries[2], canonicalSeriesId = breakingBad),
        )
        assertEquals(
            listOf(tmdbId, imdbId),
            continueWatchingSeriesContentIds(entries, card = entries[0], canonicalSeriesId = breakingBad),
        )
        assertEquals(
            listOf(imdbId),
            continueWatchingSeriesContentIds(entries, card = entries[2], canonicalSeriesId = unmapped),
        )
    }

    @Test
    fun `removing a movie card never takes a series`() {
        val movieCard = movie(tmdbId, updatedAt = 6_000L)
        val entries = listOf(movieCard, episode(imdbId, episode = 2, updatedAt = 5_000L))

        assertEquals(listOf(tmdbId), continueWatchingSeriesContentIds(entries, movieCard, breakingBad))
    }

    // The identity map

    private fun seriesMeta(id: String, imdbId: String?, type: String = "series") = MetaDetails(
        id = id,
        type = type,
        name = "Breaking Bad",
        imdbId = imdbId,
        videos = listOf(MetaVideo(id = "$id:1:1", title = "Pilot", season = 1, episode = 1)),
    )

    @Test
    fun `a series meta maps the requested and the meta id to its IMDb id`() {
        assertTrue(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = "tmdb:tv:1396", imdbId = imdbId)))

        assertEquals(imdbId, ContinueWatchingSeriesIdentity.canonical(" $tmdbId "))
        assertEquals(imdbId, ContinueWatchingSeriesIdentity.canonical("tmdb:tv:1396"))
        assertEquals(imdbId, ContinueWatchingSeriesIdentity.canonical(imdbId))
        assertTrue(ContinueWatchingSeriesIdentity.isResolved(tmdbId))
        assertEquals(2, ContinueWatchingSeriesIdentity.aliasCount())
        // Learning it again changes nothing.
        assertFalse(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = "tmdb:tv:1396", imdbId = imdbId)))
    }

    @Test
    fun `the meta id counts when the addon names no IMDb id`() {
        // An addon that answers a tmdb request with its IMDb-keyed meta.
        assertTrue(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = imdbId, imdbId = null)))

        assertEquals(imdbId, ContinueWatchingSeriesIdentity.canonical(tmdbId))
    }

    @Test
    fun `nothing is learned without an IMDb id, for a movie, or for an IMDb id`() {
        val versionBefore = ContinueWatchingSeriesIdentity.version.value

        assertFalse(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = null)))
        assertFalse(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = "tt", type = "series")))
        assertFalse(ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = imdbId, type = "movie")))
        // An IMDb id is canonical already: it is never regrouped under another one.
        assertFalse(ContinueWatchingSeriesIdentity.record("tt0000001", seriesMeta(id = "tt0000001", imdbId = imdbId)))

        assertEquals(tmdbId, ContinueWatchingSeriesIdentity.canonical(tmdbId))
        assertEquals("tt0000001", ContinueWatchingSeriesIdentity.canonical("tt0000001"))
        assertFalse(ContinueWatchingSeriesIdentity.isResolved(tmdbId))
        assertEquals(versionBefore, ContinueWatchingSeriesIdentity.version.value)
    }

    @Test
    fun `a learned id moves the version and clear forgets it`() {
        val versionBefore = ContinueWatchingSeriesIdentity.version.value

        ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = imdbId))
        assertTrue(ContinueWatchingSeriesIdentity.version.value > versionBefore)

        ContinueWatchingSeriesIdentity.clear()
        assertEquals(tmdbId, ContinueWatchingSeriesIdentity.canonical(tmdbId))
        assertEquals(0, ContinueWatchingSeriesIdentity.aliasCount())
    }

    @Test
    fun `the row groups with what the map learned`() {
        ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = tmdbId, imdbId = imdbId))
        val entries = listOf(episode(tmdbId, 1, 1_000L), episode(imdbId, 5, 5_000L))

        val result = buildContinueWatchingRowEntries(entries = entries, isDroppedShow = { false }, recencyCutoffEpochMs = null)
        val legacyRow = entries.continueWatchingEntries()

        assertEquals(listOf("$imdbId:1:5"), result.map { it.videoId })
        // Only the row groups by the learned id: the legacy list, enrichment and mobile do not.
        assertEquals(2, legacyRow.size)
    }

    // The warm-up

    @Test
    fun `the warm-up looks up the row's series cards stored under a TMDB id, most recent first`() {
        val rowEntries = listOf(
            episode(tmdbId, episode = 2, updatedAt = 9_000L),
            episode(imdbId, episode = 5, updatedAt = 8_000L),
            episode("kitsu:1", episode = 1, updatedAt = 7_000L),
            episode("tmdb:", episode = 1, updatedAt = 6_000L),
            movie("tmdb:550", updatedAt = 5_000L),
            episode("tmdb:42", episode = 1, updatedAt = 4_000L),
            episode("tmdb:43", episode = 1, updatedAt = 3_000L),
            episode("tmdb:44", episode = 1, updatedAt = 2_000L),
        )

        val keys = selectSeriesIdentityWarmUpKeys(
            rowEntries = rowEntries,
            isResolved = { id -> id == "tmdb:42" },
        )

        // The IMDb id, the anime id, the malformed id and the resolved one are left out, and the
        // movie is no series.
        assertEquals(
            listOf(
                WatchProgressMetadataKey(metaId = tmdbId, metaType = "series"),
                WatchProgressMetadataKey(metaId = "tmdb:43", metaType = "series"),
                WatchProgressMetadataKey(metaId = "tmdb:44", metaType = "series"),
            ),
            keys,
        )
    }

    @Test
    fun `an old alias card behind many IMDb cards is still looked up`() {
        val recentImdbCards = (1..40).map { number -> episode("tt${1_000_000 + number}", 1, 10_000L + number) }
        val oldAliasCard = episode(tmdbId, episode = 1, updatedAt = 1_000L)

        val keys = selectSeriesIdentityWarmUpKeys(
            rowEntries = recentImdbCards + oldAliasCard,
            isResolved = ContinueWatchingSeriesIdentity::isResolved,
        )

        assertEquals(listOf(tmdbId), keys.map(WatchProgressMetadataKey::metaId))
    }

    @Test
    fun `the warm-up budget is per profile load, not per row build`() {
        val budget = SeriesIdentityWarmUpBudget(maxIds = 3, maxAttemptsPerId = 2, retryDelayMs = 1_000L)
        val ids = (1..5).map { number -> "tmdb:$number" }

        val first = budget.claim(ids, nowEpochMs = 0L)
        assertEquals(listOf("tmdb:1", "tmdb:2", "tmdb:3"), first.ids)
        // Every later build asks again: nothing more once the budget is spent.
        assertTrue(budget.claim(ids, nowEpochMs = 10L).ids.isEmpty())

        // A fetched meta is done for the load; a lookup that fetched nothing is tried again once
        // its delay is over, while attempts remain.
        budget.finish(first.generation, "tmdb:1", fetched = true, nowEpochMs = 20L)
        budget.finish(first.generation, "tmdb:2", fetched = false, nowEpochMs = 20L)
        assertTrue(budget.claim(ids, nowEpochMs = 500L).ids.isEmpty())
        assertEquals(listOf("tmdb:2"), budget.claim(ids, nowEpochMs = 1_020L).ids)
        budget.finish(first.generation, "tmdb:2", fetched = false, nowEpochMs = 1_100L)
        assertTrue(budget.claim(ids, nowEpochMs = 60_000L).ids.isEmpty(), "out of attempts")
        assertEquals(3, budget.claimedCount())

        // A profile load starts over; a lookup of the previous load reports into nothing.
        budget.reset()
        assertFalse(budget.isCurrent(first.generation))
        budget.finish(first.generation, "tmdb:3", fetched = true, nowEpochMs = 60_000L)
        assertEquals(listOf("tmdb:1", "tmdb:2", "tmdb:3"), budget.claim(ids, nowEpochMs = 60_000L).ids)
    }

    @Test
    fun `ids of other families are never grouped nor looked up`() {
        // An anime database files each season as its own entry, all naming one IMDb series.
        assertFalse(ContinueWatchingSeriesIdentity.record("kitsu:7442", seriesMeta(id = "kitsu:7442", imdbId = "tt2560140")))
        assertFalse(ContinueWatchingSeriesIdentity.record("mal:16498", seriesMeta(id = "mal:16498", imdbId = "tt2560140")))

        assertEquals("kitsu:7442", ContinueWatchingSeriesIdentity.canonical("kitsu:7442"))
        assertTrue(ContinueWatchingSeriesIdentity.isResolved("kitsu:7442"))
        assertTrue(
            selectSeriesIdentityWarmUpKeys(
                rowEntries = listOf(episode("kitsu:7442", 1, 1_000L), episode("mal:16498", 1, 900L)),
                isResolved = ContinueWatchingSeriesIdentity::isResolved,
            ).isEmpty(),
        )
    }

    @Test
    fun `the learned ids survive a profile load and are forgotten on sign-out`() {
        try {
            WatchProgressRepository.ensureLoaded()
            ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = imdbId, imdbId = imdbId))

            WatchProgressRepository.onProfileChanged(ProfileRepository.activeProfileId + 5)

            // Metadata, not the profile: Home's Up Next cache that taught it is still there too.
            assertEquals(imdbId, ContinueWatchingSeriesIdentity.canonical(tmdbId))
        } finally {
            WatchProgressRepository.clearLocalState()
        }
        assertEquals(tmdbId, ContinueWatchingSeriesIdentity.canonical(tmdbId))
    }

    // Confirmation, and what the removal takes

    @Test
    fun `a mapping is confirmed when the meta answered for the IMDb id itself`() {
        // The repository's TMDB conversion: the tmdb request was answered with the tt meta.
        ContinueWatchingSeriesIdentity.record(tmdbId, seriesMeta(id = imdbId, imdbId = imdbId))
        assertTrue(ContinueWatchingSeriesIdentity.isConfirmed(tmdbId))

        // An add-on's claim about its own tmdb meta.
        ContinueWatchingSeriesIdentity.record("tmdb:1399", seriesMeta(id = "tmdb:1399", imdbId = "tt0944947"))
        assertFalse(ContinueWatchingSeriesIdentity.isConfirmed("tmdb:1399"))
        assertTrue(ContinueWatchingSeriesIdentity.isConfirmed("tt0944947"), "an IMDb id is its own")

        // A later confirmed answer confirms it without regrouping anything...
        assertFalse(ContinueWatchingSeriesIdentity.record("tmdb:1399", seriesMeta(id = "tt0944947", imdbId = null)))
        assertTrue(ContinueWatchingSeriesIdentity.isConfirmed("tmdb:1399"))
        // ...and another add-on's claim never replaces a confirmed mapping.
        assertFalse(ContinueWatchingSeriesIdentity.record("tmdb:1399", seriesMeta(id = "tmdb:1399", imdbId = "tt0000009")))
        assertEquals("tt0944947", ContinueWatchingSeriesIdentity.canonical("tmdb:1399"))
    }

    @Test
    fun `an alias only an add-on's imdb_id names is removed only when it carries the card's title`() {
        val unconfirmed: (String) -> Boolean = { id -> id.trim() != tmdbId }
        val sameShow = listOf(episode(tmdbId, 1, 1_000L), episode(imdbId, 5, 5_000L))
        val otherShow = listOf(
            episode(tmdbId, 1, 1_000L).copy(title = "Better Call Saul"),
            episode(imdbId, 5, 5_000L),
        )
        val leftOut = mutableListOf<String>()

        assertEquals(
            listOf(imdbId, tmdbId),
            continueWatchingSeriesContentIds(sameShow, sameShow[1], breakingBad, isConfirmedAlias = unconfirmed),
        )
        // A wrong imdb_id groups two shows on the row; removing one must not delete the other.
        assertEquals(
            listOf(imdbId),
            continueWatchingSeriesContentIds(
                otherShow,
                otherShow[1],
                breakingBad,
                isConfirmedAlias = unconfirmed,
                onAliasLeftOut = { alias -> leftOut += alias },
            ),
        )
        assertEquals(listOf(tmdbId), leftOut)
        // Confirmed by the TMDB conversion: removed together whatever the titles.
        assertEquals(
            listOf(imdbId, tmdbId),
            continueWatchingSeriesContentIds(otherShow, otherShow[1], breakingBad, isConfirmedAlias = { true }),
        )
    }

    // Up Next dismissal across ids

    private fun mark(showId: String, episode: Int, markedAt: Long): WatchedItem = WatchedItem(
        id = showId,
        type = "series",
        name = "Breaking Bad",
        season = 1,
        episode = episode,
        markedAtEpochMs = markedAt,
    )

    private fun dismissKeys(
        card: WatchProgressEntry,
        watchedItems: List<WatchedItem>,
        progressEntries: List<WatchProgressEntry> = emptyList(),
        inProgressEntries: List<WatchProgressEntry> = emptyList(),
    ): Set<String> = continueWatchingNextUpSeriesDismissKeys(
        card = card,
        progressEntries = progressEntries,
        watchedItems = watchedItems,
        inProgressEntries = inProgressEntries,
        preferFurthestEpisode = true,
        dismissedNextUpKeys = emptySet(),
        recencyCutoffEpochMs = null,
        canonicalSeriesId = breakingBad,
    )

    private fun seedsDismissing(watchedItems: List<WatchedItem>, dismissed: Set<String>) =
        buildContinueWatchingNextUpSeeds(
            progressEntries = emptyList(),
            watchedItems = watchedItems,
            inProgressEntries = emptyList(),
            preferFurthestEpisode = true,
            dismissedNextUpKeys = dismissed,
            recencyCutoffEpochMs = null,
            limit = 20,
            canonicalSeriesId = breakingBad,
        )

    @Test
    fun `removing a series dismisses the Up Next seeds of all its ids`() {
        // Episode marks under the old TMDB id (S1E3) and under the IMDb id (S1E8).
        val marks = listOf(mark(tmdbId, 3, 3_000L), mark(imdbId, 8, 8_000L), mark("tt0944947", 2, 2_000L))
        assertEquals(
            listOf(imdbId to 8, "tt0944947" to 2),
            seedsDismissing(marks, emptySet()).map { it.contentId to it.episodeNumber },
        )

        // The Up Next card the row shows for the series, under the IMDb id.
        val upNextCard = episode(imdbId, episode = 9, updatedAt = 8_000L).copy(
            lastPositionMs = 0L,
            source = WatchProgressSourceNextUp,
        )
        val keys = dismissKeys(card = upNextCard, watchedItems = marks)

        assertEquals(setOf(nextUpDismissKey(imdbId, 1, 8), nextUpDismissKey(tmdbId, 1, 3)), keys)
        // The newest seed alone: the other id's older one takes its place ("Up Next S1E4").
        assertEquals(
            listOf(tmdbId to 3, "tt0944947" to 2),
            seedsDismissing(marks, setOf(nextUpDismissKey(imdbId, 1, 8))).map { it.contentId to it.episodeNumber },
        )
        // All of them: no seed of the series is left, and the other show keeps its own.
        assertEquals(listOf("tt0944947"), seedsDismissing(marks, keys).map { it.contentId })
        // Asked from a card under the TMDB id, the same keys.
        assertEquals(keys, dismissKeys(card = episode(" $tmdbId ", episode = 4, updatedAt = 1_000L), watchedItems = marks))
        // A movie card has no Up Next card, whatever series shares its id.
        assertTrue(dismissKeys(card = movie(tmdbId, updatedAt = 9_000L), watchedItems = marks).isEmpty())
    }

    @Test
    fun `the series' own in-progress card hides none of its seeds from the dismissal`() {
        val marks = listOf(mark(tmdbId, 3, 3_000L), mark(imdbId, 8, 8_000L))
        val resumed = episode(imdbId, episode = 9, updatedAt = 9_000L)

        val keys = dismissKeys(
            card = resumed,
            watchedItems = marks,
            progressEntries = listOf(resumed),
            inProgressEntries = listOf(resumed),
        )

        assertEquals(setOf(nextUpDismissKey(imdbId, 1, 8), nextUpDismissKey(tmdbId, 1, 3)), keys)
    }
}
