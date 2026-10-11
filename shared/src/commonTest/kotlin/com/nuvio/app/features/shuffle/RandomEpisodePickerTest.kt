package com.nuvio.app.features.shuffle

import com.nuvio.app.features.details.MetaVideo
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

class RandomEpisodePickerTest {
    @Test
    fun `unwatched pool excludes watched episodes`() {
        val picker = picker((1..4).map(::episode), watched = setOf(1 to 1, 1 to 2))

        assertEquals(4, picker.count(true))
        assertEquals(2, picker.count(false))
        assertEquals(setOf(3, 4), (1..2).map { picker.pick(false)?.episode }.toSet())
    }

    @Test
    fun `watched episodes need explicit inclusion when caught up`() {
        val picker = picker(listOf(episode(1)), watched = setOf(1 to 1))

        assertEquals(0, picker.count(false))
        assertNull(picker.pick(false))
        assertEquals(episode(1), picker.pick(true))
    }

    @Test
    fun `every episode appears before repeats and a new cycle avoids an immediate repeat`() {
        val episodes = (1..20).map(::episode)
        val picker = picker(episodes)
        val firstCycle = episodes.map { picker.pick(true) }
        val secondCycle = episodes.map { picker.pick(true) }

        assertEquals(episodes.toSet(), firstCycle.toSet())
        assertEquals(episodes.toSet(), secondCycle.toSet())
        assertNotEquals(firstCycle.last(), secondCycle.first())
    }

    @Test
    fun `history carries over to a picker built from refreshed metadata`() {
        val original = picker((1..4).map(::episode))
        val first = original.pick(true)
        val second = original.pick(true)
        val updated = picker((1..4).map { episode(it).copy(title = "Updated $it") })

        updated.inheritHistoryFrom(original)

        val next = (1..2).map { updated.pick(true)?.id }.toSet()
        assertFalse(first?.id in next)
        assertFalse(second?.id in next)
        assertEquals(2, next.size)
    }

    @Test
    fun `selection spans seasons and skips specials, unreleased and unusable episodes`() {
        val available = episode(1)
        val secondSeason = episode(1).copy(id = "show:2:1", season = 2)
        val picker = picker(
            listOf(
                available,
                secondSeason,
                episode(2).copy(available = false),
                episode(3).copy(released = "2999-01-01T00:00:00Z"),
                episode(4).copy(season = 0),
                episode(5).copy(season = null),
                episode(6).copy(episode = null),
                episode(0),
                episode(7).copy(id = " "),
            ),
        )

        assertEquals(2, picker.count(true))
        assertEquals(setOf(available, secondSeason), (1..2).map { picker.pick(true) }.toSet())
    }

    @Test
    fun `duplicates do not bias the selection`() {
        val first = episode(1)
        val picker = picker(listOf(first, first.copy(id = "alternate"), first.copy(episode = 2), episode(3)))

        assertEquals(2, picker.count(true))
        assertEquals(setOf(first, episode(3)), (1..2).map { picker.pick(true) }.toSet())
    }

    @Test
    fun `unknown release dates stay eligible and empty or single pools are safe`() {
        val unknown = episode(1).copy(released = null)
        assertEquals(unknown, picker(listOf(unknown)).pick(false))
        assertNull(picker(emptyList()).pick(true))
        val single = picker(listOf(episode(1)))
        repeat(3) { assertEquals(episode(1), single.pick(false)) }
    }

    @Test
    fun `shuffle takes unwatched first then widens to every episode`() {
        val videos = (1..3).map(::episode)
        val random = Random(7)
        val today = "2024-01-01"

        val picks = (1..2).map {
            EpisodeShuffle.pick("shuffle-a", videos, setOf(1 to 1), random, today)?.episode
        }
        assertEquals(setOf(2, 3), picks.toSet())

        val caughtUp = (1..3).map {
            EpisodeShuffle.pick("shuffle-b", videos, setOf(1 to 1, 1 to 2, 1 to 3), random, today)?.episode
        }
        assertEquals(setOf(1, 2, 3), caughtUp.toSet())
        EpisodeShuffle.clear()
    }

    @Test
    fun `episode keys parse season and episode and drop malformed entries`() {
        assertEquals(setOf(1 to 2, 3 to 4), parseEpisodeKeys(setOf("1:2", "3:4", "x:1", "5", "")))
    }

    private fun picker(
        episodes: List<MetaVideo>,
        watched: Set<Pair<Int, Int>> = emptySet(),
    ) = RandomEpisodePicker(
        contentId = "show",
        videos = episodes,
        watchedEpisodes = watched,
        random = Random(42),
        todayIsoDate = "2024-01-01",
    )

    private fun episode(number: Int) = MetaVideo(
        id = "show:1:$number",
        title = "Episode $number",
        released = "2020-01-01",
        season = 1,
        episode = number,
    )
}
