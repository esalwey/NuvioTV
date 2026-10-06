package com.nuvio.app.features.watched

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** CW sync #2: which watched marks the one-time post-pull backlog push sends. */
class WatchedBacklogTest {
    @Test
    fun `sends only the still-dirty marks, most recent first`() {
        val items = listOf(
            mark(episode = 1, markedAt = 1_000L),
            mark(episode = 2, markedAt = 3_000L),
            mark(episode = 3, markedAt = 2_000L),
            mark(episode = 4, markedAt = 9_000L),
        ).associateBy { watchedItemKey(it.type, it.id, it.season, it.episode) }
        val dirty = items.filterValues { it.episode != 4 }.keys + watchedItemKey("series", "tt0944947", 1, 99)

        val backlog = selectDirtyWatchedBacklog(items = items, dirtyKeys = dirty)

        assertEquals(listOf(2, 3, 1), backlog.map { it.episode })
    }

    @Test
    fun `is capped to the most recent marks`() {
        val items = (1..250)
            .map { number -> mark(episode = number, markedAt = 1_700_000_000_000L + number) }
            .associateBy { watchedItemKey(it.type, it.id, it.season, it.episode) }

        val backlog = selectDirtyWatchedBacklog(items = items, dirtyKeys = items.keys)

        assertEquals(WATCHED_BACKLOG_PUSH_LIMIT, backlog.size)
        assertEquals(250, backlog.first().episode)
        assertEquals(51, backlog.last().episode)
    }

    @Test
    fun `nothing dirty sends nothing`() {
        val item = mark(episode = 1, markedAt = 1_000L)
        assertTrue(
            selectDirtyWatchedBacklog(
                items = mapOf(watchedItemKey(item.type, item.id, item.season, item.episode) to item),
                dirtyKeys = emptySet(),
            ).isEmpty(),
        )
    }

    // Review of #2: the backlog must not mark watched again what another device unmarked after the
    // mark was made. The deletes of a delta pull withdraw the marks they supersede from sync.

    @Test
    fun `an unmark of its key withdraws an older unsynced mark`() {
        val stale = mark(episode = 3, markedAt = 1_000L)
        val synced = mark(episode = 1, markedAt = 500L)
        val items = listOf(stale, synced).associateBy(::keyOf)

        val withdrawn = dirtyWatchedKeysWithdrawnByServerDeletes(
            items = items,
            dirtyKeys = setOf(keyOf(stale)),
            deletedKeys = setOf(keyOf(stale)),
            deletedContentIds = setOf("tt0944947"),
            markedBeforeEpochMs = PULL_STARTED_AT,
        )

        assertEquals(setOf(keyOf(stale)), withdrawn)
    }

    @Test
    fun `a show marked unwatched elsewhere withdraws the marks of its other episodes too`() {
        // The account held E1 and E2, both deleted here too by the pull. The TV's E5 never reached it.
        val tvOnly = mark(episode = 5, markedAt = 1_000L)
        val otherShow = mark(episode = 2, markedAt = 1_000L).copy(id = "tt0903747")
        val items = listOf(tvOnly, otherShow).associateBy(::keyOf)

        val withdrawn = dirtyWatchedKeysWithdrawnByServerDeletes(
            items = items,
            dirtyKeys = items.keys,
            deletedKeys = emptySet(),
            deletedContentIds = setOf("tt0944947"),
            markedBeforeEpochMs = PULL_STARTED_AT,
        )

        assertEquals(setOf(keyOf(tvOnly)), withdrawn)
    }

    @Test
    fun `one episode unmarked elsewhere leaves the show's other marks to the backlog`() {
        val tvOnly = mark(episode = 5, markedAt = 1_000L)
        val synced = mark(episode = 2, markedAt = 800L)
        val items = listOf(tvOnly, synced).associateBy(::keyOf)

        val withdrawn = dirtyWatchedKeysWithdrawnByServerDeletes(
            items = items,
            dirtyKeys = setOf(keyOf(tvOnly)),
            deletedKeys = emptySet(),
            deletedContentIds = setOf("tt0944947"),
            markedBeforeEpochMs = PULL_STARTED_AT,
        )

        assertTrue(withdrawn.isEmpty())
    }

    @Test
    fun `a mark made during the pull is kept`() {
        val fresh = mark(episode = 3, markedAt = PULL_STARTED_AT + 1L)
        val items = mapOf(keyOf(fresh) to fresh)

        val withdrawn = dirtyWatchedKeysWithdrawnByServerDeletes(
            items = items,
            dirtyKeys = items.keys,
            deletedKeys = items.keys,
            deletedContentIds = setOf("tt0944947"),
            markedBeforeEpochMs = PULL_STARTED_AT,
        )

        assertTrue(withdrawn.isEmpty())
    }

    private fun keyOf(item: WatchedItem): String = watchedItemKey(item.type, item.id, item.season, item.episode)

    private companion object {
        const val PULL_STARTED_AT = 1_790_000_000_000L
    }

    private fun mark(episode: Int, markedAt: Long) = WatchedItem(
        id = "tt0944947",
        type = "series",
        name = "Game of Thrones",
        season = 1,
        episode = episode,
        markedAtEpochMs = markedAt,
    )
}
