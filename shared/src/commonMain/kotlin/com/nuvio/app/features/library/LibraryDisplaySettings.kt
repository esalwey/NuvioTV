package com.nuvio.app.features.library

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

enum class LibraryLayoutMode {
    HORIZONTAL,
    VERTICAL,
}

enum class LibrarySortOption {
    DEFAULT,
    ADDED_DESC,
    ADDED_ASC,
    RELEASED_DESC,
    RELEASED_ASC,
    TITLE_ASC,
    TITLE_DESC,
}

data class LibraryDisplaySettingsUiState(
    val layoutMode: LibraryLayoutMode = LibraryLayoutMode.HORIZONTAL,
    val sortOption: LibrarySortOption = LibrarySortOption.DEFAULT,
)

object LibraryDisplaySettingsRepository {
    private val _uiState = MutableStateFlow(LibraryDisplaySettingsUiState())
    val uiState: StateFlow<LibraryDisplaySettingsUiState> = _uiState.asStateFlow()

    private var hasLoaded = false

    fun ensureLoaded() {
        if (hasLoaded) return
        loadFromDisk()
    }

    fun onProfileChanged() {
        loadFromDisk()
    }

    fun clearLocalState() {
        hasLoaded = false
        _uiState.value = LibraryDisplaySettingsUiState()
    }

    fun setLayoutMode(layoutMode: LibraryLayoutMode) {
        ensureLoaded()
        if (_uiState.value.layoutMode == layoutMode) return
        _uiState.value = _uiState.value.copy(layoutMode = layoutMode)
        persist()
    }

    fun setSortOption(sortOption: LibrarySortOption) {
        ensureLoaded()
        if (_uiState.value.sortOption == sortOption) return
        _uiState.value = _uiState.value.copy(sortOption = sortOption)
        persist()
    }

    private fun loadFromDisk() {
        hasLoaded = true
        _uiState.value = decodeLibraryDisplaySettings(LibraryDisplaySettingsStorage.loadPayload())
    }

    private fun persist() {
        LibraryDisplaySettingsStorage.savePayload(encodeLibraryDisplaySettings(_uiState.value))
    }
}

// Fork: public (upstream: internal) — consumed cross-module (composeApp UI/tests, tvOS Swift).
data class LibraryVerticalEntry(
    val item: LibraryItem,
    val section: LibrarySection,
)

// Fork: public (upstream: internal) — consumed cross-module (composeApp UI/tests, tvOS Swift).
data class LibraryVerticalProjection(
    val availableSections: List<LibrarySection>,
    val selectedSectionKey: String?,
    val availableTypes: List<String>,
    val selectedType: String?,
    val entries: List<LibraryVerticalEntry>,
)

// Fork: public (upstream: internal) — consumed cross-module (composeApp UI/tests, tvOS Swift).
fun availableLibrarySortOptions(sourceMode: LibrarySourceMode): List<LibrarySortOption> =
    if (sourceMode.isRemoteTrackingSource) {
        LibrarySortOption.entries
    } else {
        LibrarySortOption.entries.filterNot { it == LibrarySortOption.DEFAULT }
    }

// Fork: public (upstream: internal) — consumed cross-module (composeApp UI/tests, tvOS Swift).
fun effectiveLibrarySortOption(
    selected: LibrarySortOption,
    sourceMode: LibrarySourceMode,
): LibrarySortOption =
    if (selected == LibrarySortOption.DEFAULT && sourceMode == LibrarySourceMode.LOCAL) {
        LibrarySortOption.ADDED_DESC
    } else {
        selected
    }

// Fork: public (upstream: internal) — consumed cross-module (composeApp UI/tests, tvOS Swift).
fun sortLibraryItems(
    items: List<LibraryItem>,
    selected: LibrarySortOption,
    sourceMode: LibrarySourceMode,
): List<LibraryItem> {
    // The sort keys (lowercase, trim, article regex, release-year regex) are computed once per item
    // here, not once per comparison: a comparator calls them 2 n log n times, which froze the UI on
    // libraries of a few thousand titles.
    val rows = items.map(::LibrarySortRow)
    val comparator: Comparator<LibrarySortRow> = when (effectiveLibrarySortOption(selected, sourceMode)) {
        LibrarySortOption.DEFAULT ->
            compareBy<LibrarySortRow> { it.item.traktRank ?: Int.MAX_VALUE }
                .thenByDescending { it.item.savedAtEpochMs }
                .thenBy { it.tieBreak }
                .thenBy { it.item.id }
        LibrarySortOption.ADDED_DESC ->
            compareByDescending<LibrarySortRow> { it.item.savedAtEpochMs }
                .thenBy { it.tieBreak }
                .thenBy { it.item.id }
        LibrarySortOption.ADDED_ASC ->
            compareBy<LibrarySortRow> { it.item.savedAtEpochMs }
                .thenBy { it.tieBreak }
                .thenBy { it.item.id }
        // Items without a release year always sink to the bottom, in both directions.
        LibrarySortOption.RELEASED_DESC ->
            compareBy<LibrarySortRow> { it.year == null }
                .thenByDescending { it.year ?: 0 }
                .thenBy { it.tieBreak }
                .thenBy { it.item.id }
        LibrarySortOption.RELEASED_ASC ->
            compareBy<LibrarySortRow> { it.year == null }
                .thenBy { it.year ?: 0 }
                .thenBy { it.tieBreak }
                .thenBy { it.item.id }
        LibrarySortOption.TITLE_ASC ->
            compareBy<LibrarySortRow> { it.titleKey }
                .thenBy { it.item.id }
        LibrarySortOption.TITLE_DESC ->
            compareByDescending<LibrarySortRow> { it.titleKey }
                .thenBy { it.item.id }
    }
    return rows.sortedWith(comparator).map { it.item }
}

/** An item with its sort keys computed once; the keys a given sort does not read are never built. */
private class LibrarySortRow(val item: LibraryItem) {
    val tieBreak: String = libraryTitleTieBreakKey(item)
    val titleKey: String by lazy(LazyThreadSafetyMode.NONE) { libraryTitleSortKey(item) }
    val year: Int? by lazy(LazyThreadSafetyMode.NONE) { libraryReleaseYear(item) }
}

// Fork: public (upstream: internal) — consumed cross-module (composeApp UI/tests, tvOS Swift).
fun sortLibrarySections(
    sections: List<LibrarySection>,
    selected: LibrarySortOption,
    sourceMode: LibrarySourceMode,
): List<LibrarySection> =
    sections.map { section ->
        section.copy(items = sortLibraryItems(section.items, selected, sourceMode))
    }

// Fork: public (upstream: internal) — consumed cross-module (composeApp UI/tests, tvOS Swift).
fun buildLibraryVerticalProjection(
    sections: List<LibrarySection>,
    sourceMode: LibrarySourceMode,
    selectedSectionKey: String?,
    selectedType: String?,
    sortOption: LibrarySortOption,
): LibraryVerticalProjection {
    val availableSections = if (sourceMode.isRemoteTrackingSource) sections else emptyList()
    val selectedSection = if (sourceMode.isRemoteTrackingSource) {
        sections.firstOrNull { it.type == selectedSectionKey } ?: sections.firstOrNull()
    } else {
        null
    }
    val baseEntries = if (selectedSection != null) {
        selectedSection.items.map { item -> LibraryVerticalEntry(item, selectedSection) }
    } else {
        sections.flatMap { section ->
            section.items.map { item -> LibraryVerticalEntry(item, section) }
        }
    }
    val deduplicatedEntries = LinkedHashMap<String, LibraryVerticalEntry>()
    baseEntries.forEach { entry ->
        val key = libraryDisplayItemKey(entry.item)
        if (key !in deduplicatedEntries) {
            deduplicatedEntries[key] = entry
        }
    }
    val availableTypes = deduplicatedEntries.values
        .map { entry -> (entry.item.mediaCategory ?: entry.item.type).normalizedLibraryType() }
        .filter { it.isNotBlank() }
        .distinct()
        .sorted()
    val effectiveType = selectedType
        ?.normalizedLibraryType()
        ?.takeIf { it in availableTypes }
    val filteredEntries = deduplicatedEntries.values.filter { entry ->
        effectiveType == null || (entry.item.mediaCategory ?: entry.item.type).normalizedLibraryType() == effectiveType
    }
    val entryByKey = filteredEntries.associateBy { entry -> libraryDisplayItemKey(entry.item) }
    val sortedEntries = sortLibraryItems(
        items = filteredEntries.map { entry -> entry.item },
        selected = sortOption,
        sourceMode = sourceMode,
    ).mapNotNull { item -> entryByKey[libraryDisplayItemKey(item)] }

    return LibraryVerticalProjection(
        availableSections = availableSections,
        selectedSectionKey = selectedSection?.type,
        availableTypes = availableTypes,
        selectedType = effectiveType,
        entries = sortedEntries,
    )
}

// Fork: public (upstream: internal) — consumed cross-module (composeApp UI/tests, tvOS Swift).
fun encodeLibraryDisplaySettings(state: LibraryDisplaySettingsUiState): String =
    LibraryDisplaySettingsJson.encodeToString(
        StoredLibraryDisplaySettings(
            layoutMode = state.layoutMode.name,
            sortOption = state.sortOption.name,
        ),
    )

// Fork: public (upstream: internal) — consumed cross-module (composeApp UI/tests, tvOS Swift).
fun decodeLibraryDisplaySettings(payload: String?): LibraryDisplaySettingsUiState {
    val stored = payload
        ?.takeIf { it.isNotBlank() }
        ?.let { value ->
            runCatching {
                LibraryDisplaySettingsJson.decodeFromString<StoredLibraryDisplaySettings>(value)
            }.getOrNull()
        }
    return LibraryDisplaySettingsUiState(
        layoutMode = stored?.layoutMode
            ?.let { value -> LibraryLayoutMode.entries.firstOrNull { it.name == value } }
            ?: LibraryLayoutMode.HORIZONTAL,
        sortOption = stored?.sortOption
            ?.let { value -> LibrarySortOption.entries.firstOrNull { it.name == value } }
            ?: LibrarySortOption.DEFAULT,
    )
}

private val LibraryDisplaySettingsJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

private val LeadingLibraryTitleArticle = Regex("^(the|an|a)\\s+", RegexOption.IGNORE_CASE)

private fun libraryTitleSortKey(item: LibraryItem): String =
    libraryTitleTieBreakKey(item)
        .trim()
        .replace(LeadingLibraryTitleArticle, "")

private fun libraryTitleTieBreakKey(item: LibraryItem): String =
    item.name
        .ifBlank { item.id }
        .lowercase()

private val LibraryReleaseYearRegex = Regex("""\b(?:19|20)\d{2}\b""")

/** The four-digit release year found in [LibraryItem.releaseInfo] ("2019", "2019–2021"), or null. */
fun libraryReleaseYear(item: LibraryItem): Int? =
    item.releaseInfo?.let { LibraryReleaseYearRegex.find(it)?.value }?.toIntOrNull()

private fun libraryDisplayItemKey(item: LibraryItem): String =
    "${item.type.normalizedLibraryType()}:${item.id.trim()}"

private fun String.normalizedLibraryType(): String = trim().lowercase()

/**
 * True for any provider-backed library source. Sort options and section projections apply to all
 * of them, not just Trakt — testing `== TRAKT` silently degrades every other provider to the
 * local-library shape.
 */
internal val LibrarySourceMode.isRemoteTrackingSource: Boolean
    get() = this != LibrarySourceMode.LOCAL

@Serializable
private data class StoredLibraryDisplaySettings(
    @SerialName("layout_mode") val layoutMode: String = LibraryLayoutMode.HORIZONTAL.name,
    @SerialName("sort_option") val sortOption: String = LibrarySortOption.DEFAULT.name,
)
