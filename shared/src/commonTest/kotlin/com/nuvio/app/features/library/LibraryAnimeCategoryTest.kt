package com.nuvio.app.features.library

import kotlin.test.Test
import kotlin.test.assertEquals

/** Upstream 96618a86: anime tagged via `mediaCategory` gets its own type tab; `type` stays as-is. */
class LibraryAnimeCategoryTest {

    @Test
    fun animeCategoryDrivesTypeTabsWithoutChangingType() {
        val watchlist = LibrarySection(
            type = "watchlist",
            displayTitle = "Watchlist",
            items = listOf(
                item("movie-1"),
                item("series-1", type = "series"),
                item("anime-1", type = "series", mediaCategory = "anime"),
            ),
        )

        val all = buildLibraryVerticalProjection(
            sections = listOf(watchlist),
            sourceMode = LibrarySourceMode.SIMKL,
            selectedSectionKey = "watchlist",
            selectedType = null,
            sortOption = LibrarySortOption.TITLE_ASC,
        )
        assertEquals(listOf("anime", "movie", "series"), all.availableTypes)

        val anime = buildLibraryVerticalProjection(
            sections = listOf(watchlist),
            sourceMode = LibrarySourceMode.SIMKL,
            selectedSectionKey = "watchlist",
            selectedType = "anime",
            sortOption = LibrarySortOption.TITLE_ASC,
        )
        assertEquals(listOf("anime-1"), anime.entries.map { it.item.id })
        assertEquals("series", anime.entries.single().item.type)

        val series = buildLibraryVerticalProjection(
            sections = listOf(watchlist),
            sourceMode = LibrarySourceMode.SIMKL,
            selectedSectionKey = "watchlist",
            selectedType = "series",
            sortOption = LibrarySortOption.TITLE_ASC,
        )
        assertEquals(listOf("series-1"), series.entries.map { it.item.id })
    }

    private fun item(
        id: String,
        type: String = "movie",
        mediaCategory: String? = null,
    ): LibraryItem = LibraryItem(
        id = id,
        type = type,
        name = id,
        savedAtEpochMs = 0L,
        mediaCategory = mediaCategory,
    )
}
