package com.nuvio.app.features.library

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class LibraryFilteringTest {

    private val library = listOf(
        item("heat", year = "1995", genres = listOf("Crime", "Drama")),
        item("alien", year = "1979", genres = listOf("Horror", "Sci-Fi")),
        item("dune", year = "2021", genres = listOf("Sci-Fi", "Adventure")),
        item("dark", type = "series", year = "2017\u20132020", genres = listOf("Drama", "sci-fi")),
        item("naruto", type = "series", mediaCategory = "anime", year = "2002", genres = listOf("Adventure")),
        item("unknown", genres = emptyList(), year = null),
    )

    private fun filter(
        type: String? = null,
        genre: String? = null,
        year: String? = null,
        watched: LibraryWatchedFilter = LibraryWatchedFilter.ALL,
        watchedIds: Set<String> = emptySet(),
    ) = filterLibraryItems(library, type, genre, year, watched, watchedIds)

    @Test
    fun `no filter keeps everything and lists facets`() {
        val result = filter()

        assertEquals(library.map { it.id }, result.items.map { it.id })
        assertEquals(listOf("anime" to 1, "movie" to 4, "series" to 1), result.types.map { it.key to it.count })
        assertEquals(
            listOf("Adventure", "Crime", "Drama", "Horror", "Sci-Fi"),
            result.genres.map { it.key },
        )
        assertEquals(3, result.genres.first { it.key == "Sci-Fi" }.count)
        assertEquals(listOf("2021", "2017", "2002", "1995", "1979"), result.years.map { it.key })
    }

    @Test
    fun `release year is read from release info`() {
        assertEquals(2017, libraryReleaseYear(item("a", year = "2017\u20132020")))
        assertEquals(1979, libraryReleaseYear(item("b", year = "Released 1979")))
        assertNull(libraryReleaseYear(item("c", year = "tba")))
        assertNull(libraryReleaseYear(item("d", year = null)))
    }

    @Test
    fun `type filter uses media category and narrows the other facets`() {
        val result = filter(type = "anime")

        assertEquals(listOf("naruto"), result.items.map { it.id })
        assertEquals("anime", result.selectedType)
        assertEquals(listOf("Adventure"), result.genres.map { it.key })
        assertEquals(listOf("2002"), result.years.map { it.key })
    }

    @Test
    fun `genre filter ignores case and combines with year`() {
        val result = filter(genre = "SCI-FI", year = "2021")

        assertEquals(listOf("dune"), result.items.map { it.id })
        assertEquals("Sci-Fi", result.selectedGenre)
        assertEquals("2021", result.selectedYear)
    }

    @Test
    fun `a selection that no other filter allows is dropped instead of emptying the grid`() {
        val result = filter(type = "anime", genre = "Horror")

        assertNull(result.selectedGenre)
        assertEquals(listOf("naruto"), result.items.map { it.id })
    }

    @Test
    fun `watched filter splits on watched ids`() {
        val watchedIds = setOf("heat", "dark")

        assertEquals(
            listOf("heat", "dark"),
            filter(watched = LibraryWatchedFilter.WATCHED, watchedIds = watchedIds).items.map { it.id },
        )
        assertEquals(
            listOf("alien", "dune", "naruto", "unknown"),
            filter(watched = LibraryWatchedFilter.UNWATCHED, watchedIds = watchedIds).items.map { it.id },
        )
    }

    private fun item(
        id: String,
        type: String = "movie",
        mediaCategory: String? = null,
        year: String? = null,
        genres: List<String> = emptyList(),
    ) = LibraryItem(
        id = id,
        type = type,
        name = id,
        releaseInfo = year,
        genres = genres,
        mediaCategory = mediaCategory,
        savedAtEpochMs = 0L,
    )
}
