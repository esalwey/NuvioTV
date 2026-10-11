package com.nuvio.app.features.library

/** Watched-state filter of the Library screen (ported from the Android TV Library). */
enum class LibraryWatchedFilter {
    ALL,
    WATCHED,
    UNWATCHED,
}

/** One selectable value of a Library filter, with how many items it would show. */
data class LibraryFilterOption(
    val key: String,
    val count: Int,
)

/**
 * Outcome of [filterLibraryItems]: the visible [items] (input order preserved, sorting is the
 * caller's job) plus the faceted options for every filter menu. Each filter's options count the
 * items that match all the OTHER active filters, so a menu never offers a value that would
 * produce an empty grid. A selection that is no longer offered comes back as null.
 */
data class LibraryFilterResult(
    val items: List<LibraryItem>,
    val types: List<LibraryFilterOption>,
    val genres: List<LibraryFilterOption>,
    val years: List<LibraryFilterOption>,
    val selectedType: String?,
    val selectedGenre: String?,
    val selectedYear: String?,
)

/** Lower-cased media category ("movie", "series", "anime", ...) used by the Type filter. */
fun libraryItemTypeKey(item: LibraryItem): String =
    (item.mediaCategory ?: item.type).trim().lowercase()

private fun libraryItemYearKey(item: LibraryItem): String? =
    libraryReleaseYear(item)?.toString()

private fun libraryItemHasGenre(item: LibraryItem, genre: String): Boolean =
    item.genres.any { it.trim().equals(genre, ignoreCase = true) }

/**
 * Applies the Type / Genre / Year / Watched filters to [items].
 *
 * [watchedIds] holds the ids of the titles the user finished (movies watched, series fully
 * watched); it is only read when [watched] is not [LibraryWatchedFilter.ALL].
 */
fun filterLibraryItems(
    items: List<LibraryItem>,
    type: String?,
    genre: String?,
    year: String?,
    watched: LibraryWatchedFilter,
    watchedIds: Set<String>,
): LibraryFilterResult {
    var selectedType = type?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
    var selectedGenre = genre?.trim()?.takeIf { it.isNotEmpty() }
    var selectedYear = year?.trim()?.takeIf { it.isNotEmpty() }

    var types = emptyList<LibraryFilterOption>()
    var genres = emptyList<LibraryFilterOption>()
    var years = emptyList<LibraryFilterOption>()

    // A selection no other filter allows any more (its facet is empty) is dropped. Two selections
    // can invalidate each other, so drop one per pass - Year, then Genre, then Type - and settle on
    // a fixed point. At most three drops are possible, hence four passes.
    for (@Suppress("UnusedVariable") pass in 0..3) {
        val matchesType = { item: LibraryItem -> selectedType == null || libraryItemTypeKey(item) == selectedType }
        val matchesGenre = { item: LibraryItem ->
            selectedGenre == null || libraryItemHasGenre(item, selectedGenre!!)
        }
        val matchesYear = { item: LibraryItem -> selectedYear == null || libraryItemYearKey(item) == selectedYear }

        types = items.filter { matchesGenre(it) && matchesYear(it) }
            .groupingBy(::libraryItemTypeKey).eachCount()
            .filterKeys { it.isNotBlank() }
            .map { (key, count) -> LibraryFilterOption(key, count) }
            .sortedBy { it.key }

        val genreCounts = LinkedHashMap<String, Int>()
        val genreLabels = HashMap<String, String>()
        items.filter { matchesType(it) && matchesYear(it) }.forEach { item ->
            item.genres.map { it.trim() }.filter { it.isNotEmpty() }.distinctBy { it.lowercase() }.forEach { name ->
                val folded = name.lowercase()
                val label = genreLabels.getOrPut(folded) { name }
                genreCounts[label] = (genreCounts[label] ?: 0) + 1
            }
        }
        genres = genreCounts.map { (key, count) -> LibraryFilterOption(key, count) }
            .sortedBy { it.key.lowercase() }

        years = items.filter { matchesType(it) && matchesGenre(it) }
            .mapNotNull(::libraryItemYearKey)
            .groupingBy { it }.eachCount()
            .map { (key, count) -> LibraryFilterOption(key, count) }
            .sortedByDescending { it.key }

        val genreStillOffered = selectedGenre == null ||
            genres.any { it.key.equals(selectedGenre, ignoreCase = true) }
        when {
            selectedYear != null && years.none { it.key == selectedYear } -> selectedYear = null
            !genreStillOffered -> selectedGenre = null
            selectedType != null && types.none { it.key == selectedType } -> selectedType = null
            else -> break
        }
    }
    // Canonical casing of the surviving genre selection.
    selectedGenre = selectedGenre?.let { current ->
        genres.firstOrNull { it.key.equals(current, ignoreCase = true) }?.key
    }

    val visible = items.filter { item ->
        (selectedType == null || libraryItemTypeKey(item) == selectedType) &&
            (selectedGenre == null || libraryItemHasGenre(item, selectedGenre!!)) &&
            (selectedYear == null || libraryItemYearKey(item) == selectedYear) &&
            when (watched) {
                LibraryWatchedFilter.ALL -> true
                LibraryWatchedFilter.WATCHED -> item.id in watchedIds
                LibraryWatchedFilter.UNWATCHED -> item.id !in watchedIds
            }
    }

    return LibraryFilterResult(
        items = visible,
        types = types,
        genres = genres,
        years = years,
        selectedType = selectedType,
        selectedGenre = selectedGenre,
        selectedYear = selectedYear,
    )
}
