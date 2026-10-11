package com.nuvio.app.features.details

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MetaScreenSectionOrderTest {
    private fun items(
        order: List<MetaScreenSectionKey> = MetaScreenSectionLayout.syncedDefaultOrder,
        disabled: Set<MetaScreenSectionKey> = emptySet(),
    ): List<MetaScreenSectionItem> = order.mapIndexed { index, key ->
        MetaScreenSectionItem(
            key = key,
            title = key.name,
            description = "",
            enabled = key !in disabled,
            order = index,
        )
    }

    @Test
    fun `untouched synced order shows the television default`() {
        val effective = MetaScreenSectionLayout.effectiveItems(items()).map { it.key }
        assertEquals(MetaScreenSectionLayout.televisionDefaultOrder, effective)
        assertEquals(MetaScreenSectionKey.entries.toSet(), effective.toSet())
    }

    @Test
    fun `a changed order is followed to the letter`() {
        val custom = listOf(
            MetaScreenSectionKey.ACTIONS,
            MetaScreenSectionKey.OVERVIEW,
            MetaScreenSectionKey.CAST,
            MetaScreenSectionKey.EPISODES,
            MetaScreenSectionKey.PRODUCTION,
            MetaScreenSectionKey.COMMENTS,
            MetaScreenSectionKey.TRAILERS,
            MetaScreenSectionKey.DETAILS,
            MetaScreenSectionKey.COLLECTION,
            MetaScreenSectionKey.MORE_LIKE_THIS,
        )
        assertEquals(custom, MetaScreenSectionLayout.effectiveItems(items(custom)).map { it.key })
    }

    @Test
    fun `lower sections skip disabled ones and the header sections`() {
        val keys = MetaScreenSectionLayout.lowerSectionKeys(
            items(disabled = setOf(MetaScreenSectionKey.CAST, MetaScreenSectionKey.ACTIONS)),
        )
        assertEquals(
            listOf(
                MetaScreenSectionKey.PRODUCTION,
                MetaScreenSectionKey.EPISODES,
                MetaScreenSectionKey.COLLECTION,
                MetaScreenSectionKey.TRAILERS,
                MetaScreenSectionKey.MORE_LIKE_THIS,
                MetaScreenSectionKey.COMMENTS,
                MetaScreenSectionKey.DETAILS,
            ),
            keys,
        )
    }

    @Test
    fun `moving down swaps with the next movable section`() {
        val after = MetaScreenSectionLayout.orderAfterMoving(items(), MetaScreenSectionKey.EPISODES, up = false)
        assertEquals(
            listOf(
                MetaScreenSectionKey.ACTIONS,
                MetaScreenSectionKey.OVERVIEW,
                MetaScreenSectionKey.PRODUCTION,
                MetaScreenSectionKey.CAST,
                MetaScreenSectionKey.EPISODES,
                MetaScreenSectionKey.COLLECTION,
                MetaScreenSectionKey.TRAILERS,
                MetaScreenSectionKey.MORE_LIKE_THIS,
                MetaScreenSectionKey.COMMENTS,
                MetaScreenSectionKey.DETAILS,
            ),
            after,
        )
    }

    @Test
    fun `moving never crosses the header sections and stops at the ends`() {
        val stored = items()
        val atTop = MetaScreenSectionLayout.orderAfterMoving(stored, MetaScreenSectionKey.PRODUCTION, up = true)
        assertEquals(MetaScreenSectionLayout.televisionDefaultOrder, atTop)
        val atBottom = MetaScreenSectionLayout.orderAfterMoving(stored, MetaScreenSectionKey.DETAILS, up = false)
        assertEquals(MetaScreenSectionLayout.televisionDefaultOrder, atBottom)
        val header = MetaScreenSectionLayout.orderAfterMoving(stored, MetaScreenSectionKey.ACTIONS, up = false)
        assertEquals(MetaScreenSectionLayout.televisionDefaultOrder, header)
    }

    @Test
    fun `header sections interleaved in a synced order stay in their slots`() {
        val phoneOrder = listOf(
            MetaScreenSectionKey.CAST,
            MetaScreenSectionKey.ACTIONS,
            MetaScreenSectionKey.EPISODES,
            MetaScreenSectionKey.OVERVIEW,
            MetaScreenSectionKey.PRODUCTION,
            MetaScreenSectionKey.COMMENTS,
            MetaScreenSectionKey.TRAILERS,
            MetaScreenSectionKey.DETAILS,
            MetaScreenSectionKey.COLLECTION,
            MetaScreenSectionKey.MORE_LIKE_THIS,
        )
        val after = MetaScreenSectionLayout.orderAfterMoving(items(phoneOrder), MetaScreenSectionKey.EPISODES, up = true)
        assertEquals(MetaScreenSectionKey.ACTIONS, after[1])
        assertEquals(MetaScreenSectionKey.OVERVIEW, after[3])
        assertEquals(MetaScreenSectionKey.EPISODES, after[0])
        assertEquals(MetaScreenSectionKey.CAST, after[2])
        assertTrue(after.toSet() == MetaScreenSectionKey.entries.toSet())
    }

    @Test
    fun `isEnabled defaults to on for a missing section`() {
        assertTrue(MetaScreenSectionLayout.isEnabled(emptyList(), MetaScreenSectionKey.CAST))
    }
}
