package com.nuvio.app.features.search

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Upstream ab57cf1b coverage for [resolveDiscoverCatalog], the pure half of "the Discover tab
 * remembers the last-picked catalog across cold starts": the persisted preference wins while the
 * catalog still exists, the in-memory selection is the next fallback, and the first source is the
 * last resort. Upstream carries the first two cases in its SearchRequestStateTest, which has no
 * counterpart here — the fork replaced `canReuseRequestState`/`DiscoverRequestKey` with
 * `canReuseDiscoverState`.
 */
class DiscoverCatalogResolutionTest {

    @Test
    fun `preferred discover catalog is restored ahead of current fallback`() {
        val fallback = discoverCatalog(key = "fallback", type = "movie")
        val preferred = discoverCatalog(key = "preferred", type = "series")

        val selected = resolveDiscoverCatalog(
            sources = listOf(fallback, preferred),
            preferredCatalogKey = preferred.key,
            currentCatalogKey = fallback.key,
        )

        assertEquals(preferred, selected)
    }

    @Test
    fun `current discover catalog remains when preference is unavailable`() {
        val current = discoverCatalog(key = "current", type = "movie")

        val selected = resolveDiscoverCatalog(
            sources = listOf(discoverCatalog(key = "first", type = "movie"), current),
            preferredCatalogKey = "unavailable",
            currentCatalogKey = current.key,
        )

        assertEquals(current, selected)
    }

    @Test
    fun `first source wins when neither key resolves`() {
        val first = discoverCatalog(key = "first", type = "movie")

        assertEquals(
            first,
            resolveDiscoverCatalog(
                sources = listOf(first, discoverCatalog(key = "second", type = "series")),
                preferredCatalogKey = null,
                currentCatalogKey = "gone",
            ),
        )
        assertNull(
            resolveDiscoverCatalog(
                sources = emptyList(),
                preferredCatalogKey = "preferred",
                currentCatalogKey = "current",
            ),
        )
    }

    private fun discoverCatalog(key: String, type: String): DiscoverCatalogOption =
        DiscoverCatalogOption(
            key = key,
            addonName = "Addon",
            manifestUrl = "https://example.com/manifest.json",
            type = type,
            catalogId = key,
            catalogName = key,
        )
}
