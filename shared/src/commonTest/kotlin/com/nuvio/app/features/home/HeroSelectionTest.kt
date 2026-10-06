package com.nuvio.app.features.home

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** BUG-42: the hero head must not move because a later catalog batch grew the pool. */
class HeroSelectionTest {

    private data class Item(val id: String, val rev: Int = 0)

    /** Full ranking (what the caller feeds back as `previous`). */
    private fun rank(previous: List<Item>, pool: List<Item>, limit: Int = 8, seed: Int = 1) =
        stableHeroSelection(previous, pool, limit, Random(seed)) { it.id }

    /** The carousel slice the caller shows. */
    private fun select(previous: List<Item>, pool: List<Item>, limit: Int = 8, seed: Int = 1) =
        rank(previous, pool, limit, seed).take(limit)

    @Test
    fun headStaysStableAsThePoolGrows() {
        val batch1 = (1..5).map { Item("i$it") }
        val first = rank(emptyList(), batch1)
        val batch2 = batch1 + (6..30).map { Item("i$it") }
        val second = rank(first, batch2)
        // The reserved half (limit / 2 = 4) keeps its order; the head above all.
        assertEquals(first.take(4), second.take(4))
        assertEquals(8, second.take(8).size)
        // Same pool again → identical ranking (no churn).
        assertEquals(second, rank(second, batch2))
    }

    @Test
    fun laterBatchesStillReachTheCarouselWhenTheFirstFilledIt() {
        val batch1 = (1..18).map { Item("a$it") } // one catalog page can fill all eight slots
        val first = rank(emptyList(), batch1)
        assertEquals(8, first.take(8).size)
        val batch2 = batch1 + (1..18).map { Item("b$it") } // the second Hero Source lands
        val second = rank(first, batch2)
        val carousel = second.take(8)
        assertEquals(first.first(), carousel.first())
        assertEquals(first.take(4), carousel.take(4))
        assertTrue(carousel.any { it.id.startsWith("b") }, "second source must get slots: $carousel")
        assertEquals(second, rank(second, batch2)) // stable afterwards
    }

    @Test
    fun aSmallBatchNeverUnderfills() {
        val pool = (1..8).map { Item("i$it") }
        val first = rank(emptyList(), pool)
        val second = rank(first, pool + Item("x"))
        assertEquals(8, second.take(8).size)
        assertEquals(first.take(4), second.take(4))
        assertTrue(second.take(8).any { it.id == "x" })
        // …and a third publish with the same pool is a no-op (no churn).
        assertEquals(second, rank(second, pool + Item("x")))
    }

    @Test
    fun noNewcomersKeepsEveryPreviousSlot() {
        val pool = (1..8).map { Item("i$it") }
        val first = rank(emptyList(), pool)
        assertEquals(first, rank(first, pool))
    }

    @Test
    fun newcomersAreAppendedAndRemovedItemsDropped() {
        val previous = listOf(Item("a"), Item("b"), Item("c"))
        val pool = listOf(Item("c"), Item("x"), Item("a"), Item("y"))
        val result = select(previous, pool)
        assertEquals(listOf("a", "c"), result.take(2).map { it.id })
        assertEquals(setOf("x", "y"), result.drop(2).map { it.id }.toSet())
    }

    @Test
    fun instancesComeFromThePoolNotFromPrevious() {
        val previous = listOf(Item("a", rev = 1))
        val pool = listOf(Item("a", rev = 2), Item("b"))
        assertEquals(Item("a", rev = 2), select(previous, pool).first())
    }

    @Test
    fun emptyPreviousReshufflesDeterministicallyBySeed() {
        val pool = (1..20).map { Item("i$it") }
        val a = select(emptyList(), pool, seed = 42)
        val b = select(emptyList(), pool, seed = 42)
        val c = select(emptyList(), pool, seed = 43)
        assertEquals(a, b)
        assertTrue(a != c || pool.size < 2)
        assertEquals(8, a.size)
    }

    @Test
    fun previousItemsSurviveLosingHeroSourceStatusWhileStillLoaded() {
        val previous = listOf(Item("a", rev = 1), Item("b"))
        val heroPool = listOf(Item("c"), Item("d"))            // "a"/"b" no longer hero sources…
        val anyLoaded = listOf(Item("a", rev = 2), Item("c"), Item("d")) // …but "a" is still on a row
        val result = stableHeroSelection(previous, heroPool, 8, Random(1), keepFrom = anyLoaded) { it.id }
        assertEquals("a", result.first().id)
        assertEquals(2, result.first().rev) // fresh instance from keepFrom
        assertEquals(setOf("c", "d"), result.drop(1).map { it.id }.toSet()) // "b" gone entirely
    }

    @Test
    fun limitAndEmptyPoolAreRespected() {
        assertEquals(emptyList(), select(listOf(Item("a")), emptyList()))
        assertEquals(3, select(emptyList(), (1..10).map { Item("i$it") }, limit = 3).size)
        assertEquals(emptyList(), select(emptyList(), listOf(Item("a")), limit = 0))
    }

    // ---------------------------------------------------------------------------------------
    // BUG-86 (Wave H): the committed head is pinned for the session.
    // ---------------------------------------------------------------------------------------

    private fun pin(ranking: List<Item>, committedKey: String?, keepFrom: List<Item>) =
        pinCommittedHead(ranking, committedKey, keepFrom) { it.id }

    @Test
    fun noCommittedHeadLeavesTheRankingUntouched() {
        val ranking = listOf(Item("a"), Item("b"))
        assertEquals(ranking, pin(ranking, committedKey = null, keepFrom = ranking))
    }

    @Test
    fun aCommittedHeadAlreadyAtTheFrontIsNotReallocated() {
        val ranking = listOf(Item("a"), Item("b"))
        assertTrue(pin(ranking, committedKey = "a", keepFrom = ranking) === ranking)
    }

    @Test
    fun theCommittedHeadIsMovedBackToTheFrontWhenTheRankingReorders() {
        // Hole D: the burst re-normalizes the hero sources and the head slides down the ranking.
        val ranking = listOf(Item("x"), Item("y"), Item("a", rev = 2))
        val pinned = pin(ranking, committedKey = "a", keepFrom = ranking)
        assertEquals(listOf("a", "x", "y"), pinned.map { it.id })
        assertEquals(2, pinned.first().rev)
    }

    @Test
    fun theCommittedHeadSurvivesAnEmptyRankingWhenItIsStillInKeepFrom() {
        // Its own section is being re-fetched, so the pool is momentarily empty.
        val pinned = pin(emptyList(), committedKey = "a", keepFrom = listOf(Item("a", rev = 3)))
        assertEquals(listOf("a"), pinned.map { it.id })
        assertEquals(3, pinned.first().rev)
    }

    @Test
    fun theCommittedHeadSurvivesAPoolThatNoLongerContainsIt() {
        val ranking = listOf(Item("x"), Item("y"))
        val keepFrom = listOf(Item("x"), Item("y"), Item("a"))
        assertEquals(listOf("a", "x", "y"), pin(ranking, "a", keepFrom).map { it.id })
    }

    @Test
    fun theCommittedHeadIsDroppedWhenItIsInNeitherRankingNorKeepFrom() {
        // Its origin catalog left the definition set: the one non-user reason a head may move.
        val ranking = listOf(Item("x"), Item("y"))
        assertEquals(ranking, pin(ranking, committedKey = "a", keepFrom = ranking))
    }

    @Test
    fun theCommittedHeadIsDroppedByTheReleaseFilterOnlyWhenTrulyUnreleased() {
        val released = MetaPreview(id = "tt1", type = "movie", name = "Out", releaseInfo = "2019")
        // 2099, not 2999: ReleaseInfoUtils' year regex only recognises 19xx/20xx.
        val unreleased = MetaPreview(id = "tt2", type = "movie", name = "Later", releaseInfo = "2099")
        val today = "2026-09-04"

        // Callers release-filter keepFrom before pinning, exactly as publishCurrentStateLocked does.
        val filtered = listOf(released, unreleased).filterReleasedItems(today)
        assertEquals(listOf("movie:tt1"), filtered.map { it.stableKey() })

        val kept = pinCommittedHead(emptyList(), released.stableKey(), filtered, MetaPreview::stableKey)
        assertEquals(listOf("movie:tt1"), kept.map { it.stableKey() })

        val dropped = pinCommittedHead(emptyList(), unreleased.stableKey(), filtered, MetaPreview::stableKey)
        assertEquals(emptyList(), dropped)
    }
}
