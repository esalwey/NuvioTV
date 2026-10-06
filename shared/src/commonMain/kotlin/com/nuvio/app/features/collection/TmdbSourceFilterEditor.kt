package com.nuvio.app.features.collection

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import kotlin.concurrent.Volatile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

// Fork: tvOS-only shared editor for the TMDB Discover filters of an EXISTING tmdb source.
// Upstream has no "edit existing TMDB source" API (CollectionEditorRepository is add-only for
// TMDB; only Trakt has editTraktSource) and its Compose editor mutates TmdbCollectionFilters
// through an 18-field data-class lambda that Swift cannot build comfortably. This object keeps the
// draft as plain String fields so the native tvOS UI only ever calls setters, then writes the
// rebuilt TmdbCollectionFilters back into CollectionRepository + kicks the collections push.

/**
 * One editable TMDB Discover filter. Names mirror [TmdbCollectionFilters] property names 1:1 and
 * surface to Swift as lowerCamel cases (`.withGenres`, `.withoutWatchProviders`, …).
 */
enum class TmdbFilterField(val kind: TmdbFilterFieldKind) {
    WITH_GENRES(TmdbFilterFieldKind.ID_LIST),
    WITHOUT_GENRES(TmdbFilterFieldKind.ID_LIST),
    RELEASE_DATE_GTE(TmdbFilterFieldKind.DATE),
    RELEASE_DATE_LTE(TmdbFilterFieldKind.DATE),
    VOTE_AVERAGE_GTE(TmdbFilterFieldKind.DECIMAL),
    VOTE_AVERAGE_LTE(TmdbFilterFieldKind.DECIMAL),
    VOTE_COUNT_GTE(TmdbFilterFieldKind.INTEGER),
    WITH_ORIGINAL_LANGUAGE(TmdbFilterFieldKind.SINGLE_CODE),
    WITH_ORIGIN_COUNTRY(TmdbFilterFieldKind.SINGLE_CODE),
    WITH_KEYWORDS(TmdbFilterFieldKind.ID_LIST),
    WITHOUT_KEYWORDS(TmdbFilterFieldKind.ID_LIST),
    WITH_COMPANIES(TmdbFilterFieldKind.ID_LIST),
    WITHOUT_COMPANIES(TmdbFilterFieldKind.ID_LIST),
    WITH_NETWORKS(TmdbFilterFieldKind.ID_LIST),
    YEAR(TmdbFilterFieldKind.INTEGER),
    WATCH_REGION(TmdbFilterFieldKind.SINGLE_CODE),
    WITH_WATCH_PROVIDERS(TmdbFilterFieldKind.ID_LIST),
    WITHOUT_WATCH_PROVIDERS(TmdbFilterFieldKind.ID_LIST),
    ;

    /** True for the single-valued code fields where [TmdbSourceFilterEditor.toggleId] replaces instead of toggling membership. */
    val isSingleValued: Boolean
        get() = kind == TmdbFilterFieldKind.SINGLE_CODE

    /** True for the comma/pipe id-list fields where [TmdbSourceFilterEditor.toggleId] toggles membership. */
    val isIdList: Boolean
        get() = kind == TmdbFilterFieldKind.ID_LIST
}

/** What a [TmdbFilterField] holds — lets a UI pick keyboard type / validation copy without a second table. */
enum class TmdbFilterFieldKind {
    /** TMDB numeric ids joined with `,` (AND) or `|` (OR). */
    ID_LIST,

    /** One ISO code: `en`, `US`, … */
    SINGLE_CODE,

    /** `YYYY-MM-DD`. */
    DATE,

    /** `Double` (vote average). */
    DECIMAL,

    /** `Int` (vote count, year). */
    INTEGER,
}

/** A live TMDB genre (id + localized name) from `genre/{movie,tv}/list`. */
data class TmdbGenreOption(
    val id: Int,
    val name: String,
)

/** A quick-pick preset for one filter field: `label` is English (UI layers localise), `value` is what [TmdbSourceFilterEditor.toggleId] takes. */
data class TmdbFilterChip(
    val label: String,
    val value: String,
)

/**
 * Pure-data quick-chip presets, mirroring the ids the Compose editor (`TmdbSourcePickerScreen`)
 * hardcodes plus the shared `TmdbCollectionSourceResolver.presets()` ids, so tvOS and mobile
 * offer the same shortcuts. Labels are English and meant to be localised by the UI layer.
 */
object TmdbFilterPresets {
    val movieGenreIds: List<TmdbFilterChip> = listOf(
        TmdbFilterChip("Action", "28"),
        TmdbFilterChip("Adventure", "12"),
        TmdbFilterChip("Animation", "16"),
        TmdbFilterChip("Comedy", "35"),
        TmdbFilterChip("Horror", "27"),
        TmdbFilterChip("Sci-Fi", "878"),
    )

    val tvGenreIds: List<TmdbFilterChip> = listOf(
        TmdbFilterChip("Drama", "18"),
        TmdbFilterChip("Comedy", "35"),
        TmdbFilterChip("Animation", "16"),
        TmdbFilterChip("Crime", "80"),
        TmdbFilterChip("Sci-Fi & Fantasy", "10765"),
        TmdbFilterChip("Reality", "10764"),
    )

    val keywords: List<TmdbFilterChip> = listOf(
        TmdbFilterChip("Superhero", "9715"),
        TmdbFilterChip("Based on novel", "818"),
        TmdbFilterChip("Time travel", "4379"),
        TmdbFilterChip("Space", "9882"),
    )

    val companies: List<TmdbFilterChip> = listOf(
        TmdbFilterChip("Marvel Studios", "420"),
        TmdbFilterChip("Walt Disney Pictures", "2"),
        TmdbFilterChip("Pixar", "3"),
        TmdbFilterChip("Lucasfilm", "1"),
        TmdbFilterChip("Warner Bros.", "174"),
    )

    val networks: List<TmdbFilterChip> = listOf(
        TmdbFilterChip("Netflix", "213"),
        TmdbFilterChip("HBO", "49"),
        TmdbFilterChip("Disney+", "2739"),
        TmdbFilterChip("Prime Video", "1024"),
        TmdbFilterChip("Hulu", "453"),
        TmdbFilterChip("Apple TV+", "2552"),
    )

    val watchProviders: List<TmdbFilterChip> = listOf(
        TmdbFilterChip("Netflix", "8"),
        TmdbFilterChip("Prime Video", "119"),
        TmdbFilterChip("Disney+", "337"),
        TmdbFilterChip("Apple TV+", "350"),
        TmdbFilterChip("Hulu", "15"),
    )

    val languages: List<TmdbFilterChip> = listOf(
        TmdbFilterChip("English", "en"),
        TmdbFilterChip("Korean", "ko"),
        TmdbFilterChip("Japanese", "ja"),
        TmdbFilterChip("Hindi", "hi"),
        TmdbFilterChip("Spanish", "es"),
    )

    val countries: List<TmdbFilterChip> = listOf(
        TmdbFilterChip("United States", "US"),
        TmdbFilterChip("South Korea", "KR"),
        TmdbFilterChip("Japan", "JP"),
        TmdbFilterChip("India", "IN"),
        TmdbFilterChip("United Kingdom", "GB"),
    )

    val watchRegions: List<TmdbFilterChip> = listOf(
        TmdbFilterChip("United States", "US"),
        TmdbFilterChip("United Kingdom", "GB"),
        TmdbFilterChip("Canada", "CA"),
        TmdbFilterChip("Australia", "AU"),
        TmdbFilterChip("Germany", "DE"),
    )

    /** Genre quick chips for [mediaType] (movie vs tv genre ids differ on TMDB). */
    fun genreIds(mediaType: TmdbCollectionMediaType): List<TmdbFilterChip> =
        when (mediaType) {
            TmdbCollectionMediaType.MOVIE -> movieGenreIds
            TmdbCollectionMediaType.TV -> tvGenreIds
        }
}

/**
 * Draft for editing one tmdb source's Discover filters. `null` in [TmdbSourceFilterEditor.uiState]
 * means "not editing". [fields] always carries every [TmdbFilterField] (`""` when unset) so a UI
 * can bind without null checks.
 */
data class TmdbSourceFilterEditorState(
    val collectionId: String,
    val folderId: String,
    val sourceIndex: Int,
    val sourceTitle: String,
    val tmdbSourceType: TmdbCollectionSourceType,
    val mediaType: TmdbCollectionMediaType,
    val sortBy: String,
    val fields: Map<TmdbFilterField, String>,
    val availableGenres: List<TmdbGenreOption> = emptyList(),
    val isLoadingGenres: Boolean = false,
    val isDirty: Boolean = false,
    val isSaving: Boolean = false,
    val invalidFields: List<TmdbFilterField> = emptyList(),
    val saveFailed: Boolean = false,
    val saved: Boolean = false,
) {
    /** Raw draft text for [field] (`""` when unset). */
    fun value(field: TmdbFilterField): String = fields[field].orEmpty()

    /** Individual ids in [field], split on `,` and `|`, trimmed, blanks dropped. */
    fun ids(field: TmdbFilterField): List<String> = splitIds(value(field))

    /** True when [id] is one of [ids] for [field]. */
    fun contains(field: TmdbFilterField, id: String): Boolean = id.trim() in ids(field)

    /** True when [field] failed the last [TmdbSourceFilterEditor.save] validation. */
    fun isInvalid(field: TmdbFilterField): Boolean = field in invalidFields

    /** Discover filters consume these fields only for DISCOVER/COMPANY/NETWORK sources (LIST/COLLECTION/PERSON/DIRECTOR ignore them). */
    val supportsFilters: Boolean
        get() = tmdbSourceType in filterConsumingSourceTypes
}

/**
 * tvOS-facing state machine for editing the TMDB Discover filters (incl. the `without*` exclusion
 * fields) of an EXISTING tmdb source inside an existing folder, then persisting + syncing.
 *
 * Lifecycle: [begin] → ([setField] / [toggleId] / [setSortBy] / [clearFilters])* → [save] → [cancel].
 * [save] keeps the state alive (with `saved = true`) so the UI can show confirmation and dismiss;
 * [cancel] drops it. All methods are non-suspend for Swift simplicity; only [loadGenres] is async
 * and reports through [TmdbSourceFilterEditorState.isLoadingGenres].
 */
object TmdbSourceFilterEditor {
    private val log = Logger.withTag("TmdbSourceFilterEditor")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("TmdbSourceFilterEditor"))

    private val _uiState = MutableStateFlow<TmdbSourceFilterEditorState?>(null)
    val uiState: StateFlow<TmdbSourceFilterEditorState?> = _uiState.asStateFlow()

    /** Test seam: the live TMDB genre fetch (needs a TMDB key). Not exported to Swift. */
    internal var genreLoader: suspend (TmdbCollectionMediaType) -> Map<Int, String> =
        { mediaType -> TmdbCollectionSourceResolver.genres(mediaType) }

    private var genreJob: Job? = null

    /** Bumped by [begin]/[cancel]; an async genre result only lands when its session is still current. */
    @Volatile
    private var session: Int = 0

    // Fork/Codex round 1: the source being edited, captured at begin(). A collection pull that
    // reorders/inserts/removes sources while the editor is open would make the positional
    // `sourceIndex` point at a DIFFERENT source — save() relocates the original by structural
    // identity and refuses when it is gone (saveFailed), rather than corrupting a neighbour.
    private var editedSource: CollectionSource? = null

    /**
     * Starts editing `folder.resolvedSources[sourceIndex]` of `collectionId`/`folderId`. Returns
     * false (state stays `null`) when the collection/folder/source is missing or the source is not
     * a tmdb source. Kicks off [loadGenres] on success.
     */
    fun begin(collectionId: String, folderId: String, sourceIndex: Int): Boolean {
        CollectionRepository.initialize()
        val collection = CollectionRepository.getCollection(collectionId) ?: run {
            log.w { "begin — collection $collectionId not found" }
            return false
        }
        val folder = collection.folders.firstOrNull { it.id == folderId } ?: run {
            log.w { "begin — folder $folderId not found in collection $collectionId" }
            return false
        }
        val source = folder.resolvedSources.getOrNull(sourceIndex)
        if (source == null || !source.isTmdb) {
            log.w { "begin — source #$sourceIndex in folder $folderId is missing or not a tmdb source" }
            return false
        }
        session += 1
        genreJob?.cancel()
        editedSource = source
        val filters = source.filters ?: TmdbCollectionFilters()
        _uiState.value = TmdbSourceFilterEditorState(
            collectionId = collectionId,
            folderId = folderId,
            sourceIndex = sourceIndex,
            sourceTitle = source.title?.takeIf { it.isNotBlank() } ?: "TMDB",
            tmdbSourceType = source.tmdbType(),
            mediaType = TmdbCollectionMediaType.fromString(source.mediaType),
            sortBy = source.sortBy?.takeIf { it.isNotBlank() } ?: TmdbCollectionSort.POPULAR_DESC.value,
            fields = filters.toFieldMap(),
        )
        loadGenres()
        return true
    }

    /** Replaces the draft text of [field]; marks dirty, clears [field] from `invalidFields`, resets `saved`. */
    fun setField(field: TmdbFilterField, value: String) {
        _uiState.update { current ->
            current?.copy(
                fields = current.fields + (field to value),
                isDirty = true,
                invalidFields = current.invalidFields - field,
                saved = false,
            )
        }
    }

    /**
     * Quick-chip toggle for [field]:
     * - id-list fields ([TmdbFilterField.isIdList]): toggles membership — removes [id] when present
     *   (per [TmdbSourceFilterEditorState.ids]), else appends; the result is re-joined with `,`
     *   (TMDB AND semantics) preserving the order of the other ids, `""` when empty. A field that
     *   held a `|`-joined (OR) list is therefore normalised to `,` by the first toggle — use
     *   [setField] to keep an explicit `|` list.
     * - single-valued code fields ([TmdbFilterField.isSingleValued]: WITH_ORIGINAL_LANGUAGE,
     *   WITH_ORIGIN_COUNTRY, WATCH_REGION): REPLACES the value with [id], or clears it to `""`
     *   when it already equals [id].
     * - other kinds (dates/numbers): treated like single-valued (set, or clear when equal).
     */
    fun toggleId(field: TmdbFilterField, id: String) {
        val trimmed = id.trim()
        if (trimmed.isEmpty()) return
        val current = _uiState.value ?: return
        val next = if (field.isIdList) {
            val ids = current.ids(field)
            if (trimmed in ids) ids.filterNot { it == trimmed } else ids + trimmed
        } else {
            if (current.value(field).trim() == trimmed) emptyList() else listOf(trimmed)
        }
        setField(field, next.joinToString(","))
    }

    /** Sets the source sort; [value] may be a [TmdbCollectionSort] `value` (`popularity.desc`) or entry name (`POPULAR_DESC`); unknown values are ignored. */
    fun setSortBy(value: String) {
        val normalized = normalizeSort(value) ?: run {
            log.w { "setSortBy — ignoring unknown sort '$value'" }
            return
        }
        _uiState.update { current ->
            current?.copy(sortBy = normalized, isDirty = true, saved = false)
        }
    }

    /** Blanks every filter field (sort is kept); marks dirty. */
    fun clearFilters() {
        _uiState.update { current ->
            current?.copy(
                fields = emptyFieldMap(),
                isDirty = true,
                invalidFields = emptyList(),
                saved = false,
            )
        }
    }

    /**
     * Validates the draft and writes it back. Returns false and fills `invalidFields` when a
     * non-blank field fails validation (VOTE_AVERAGE_* → 0–10, VOTE_COUNT_GTE → non-negative Int,
     * YEAR → 1874–2100, RELEASE_DATE_* → real `YYYY-MM-DD` dates, id lists → positive integers,
     * codes → two letters). On success the rebuilt [TmdbCollectionFilters] (blank → null,
     * always a non-null object, mirroring the Compose picker) + `sortBy` replace the source at
     * `sourceIndex` inside the CURRENT folder from [CollectionRepository] (re-read at save time so
     * a pull that landed mid-edit is not clobbered), legacy `catalogSources` are refreshed from
     * `sources`, the collection is updated (persist + local-change event → CollectionSyncService
     * observer push) and [CollectionSyncService.triggerPush] is called as belt-and-braces. Sets
     * `saved = true`, `isDirty = false`. Any exception → `saveFailed = true`, returns false.
     */
    fun save(): Boolean {
        val state = _uiState.value ?: return false
        val invalid = validate(state.fields)
        if (invalid.isNotEmpty()) {
            _uiState.update { current -> current?.copy(invalidFields = invalid, saveFailed = false, saved = false) }
            return false
        }
        _uiState.update { current -> current?.copy(isSaving = true, saveFailed = false, invalidFields = emptyList()) }
        val result = runCatching {
            val collection = CollectionRepository.getCollection(state.collectionId)
                ?: error("Collection ${state.collectionId} no longer exists")
            val folder = collection.folders.firstOrNull { it.id == state.folderId }
                ?: error("Folder ${state.folderId} no longer exists in collection ${state.collectionId}")
            val sources = folder.resolvedSources
            // Relocate the edited source by identity — a pull may have moved it since begin().
            val original = editedSource
            val targetIndex = when {
                original != null && sources.getOrNull(state.sourceIndex) == original -> state.sourceIndex
                original != null -> sources.indexOf(original).takeIf { it >= 0 }
                    ?: error("The edited tmdb source is no longer in folder ${state.folderId} (changed remotely?)")
                else -> state.sourceIndex
            }
            val existing = sources.getOrNull(targetIndex)?.takeIf { it.isTmdb }
                ?: error("Source #$targetIndex in folder ${state.folderId} is missing or not a tmdb source")
            val updated = existing.copy(
                filters = state.fields.toFilters(),
                sortBy = state.sortBy,
            )
            val nextSources = sources.toMutableList().apply { this[targetIndex] = updated }
            val nextFolder = folder.withSources(nextSources)
            val nextCollection = collection.copy(
                folders = collection.folders.map { if (it.id == nextFolder.id) nextFolder else it },
            )
            if (!CollectionRepository.updateCollection(nextCollection)) {
                // Codex round 3: a storage-write failure used to be swallowed (persist() logs
                // only), so the editor dismissed with saved=true while the edit lived in memory
                // alone — lost on relaunch, with no remote push for anonymous users.
                // The in-memory collection DID update, so the identity anchor must follow the
                // updated copy or every retry would fail relocation ("no longer in folder").
                editedSource = updated
                error("Collections payload write failed — the edit is not persisted")
            }
            CollectionSyncService.triggerPush()
            updated
        }
        return result.fold(
            onSuccess = { savedSource ->
                editedSource = savedSource
                _uiState.update { current ->
                    current?.copy(isSaving = false, isDirty = false, saved = true, saveFailed = false)
                }
                true
            },
            onFailure = { error ->
                log.e(error) { "save — failed for collection ${state.collectionId} folder ${state.folderId} source #${state.sourceIndex}" }
                _uiState.update { current -> current?.copy(isSaving = false, saveFailed = true, saved = false) }
                false
            },
        )
    }

    /** Stops editing: state → `null`, any in-flight genre load is cancelled. */
    fun cancel() {
        session += 1
        editedSource = null
        genreJob?.cancel()
        genreJob = null
        _uiState.value = null
    }

    /**
     * (Re)loads the live TMDB genre list for the draft's media type into `availableGenres`
     * (sorted by name). Needs a TMDB API key; on any failure (no key, network) the list stays
     * empty and `isLoadingGenres` returns to false — never throws.
     */
    fun loadGenres() {
        val state = _uiState.value ?: return
        val token = session
        genreJob?.cancel()
        _uiState.update { current -> current?.copy(isLoadingGenres = true) }
        genreJob = scope.launch {
            val genres = try {
                genreLoader(state.mediaType)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.w { "loadGenres — TMDB genres unavailable (${error.message}); continuing without names" }
                emptyMap()
            }
            val options = genres
                .map { (id, name) -> TmdbGenreOption(id = id, name = name) }
                .sortedBy { it.name.lowercase() }
            if (session != token) return@launch
            _uiState.update { current ->
                current?.copy(availableGenres = options, isLoadingGenres = false)
            }
        }
    }

    // region helpers

    private fun validate(fields: Map<TmdbFilterField, String>): List<TmdbFilterField> =
        TmdbFilterField.entries.filter { field ->
            val raw = fields[field].orEmpty().trim()
            raw.isNotEmpty() && !isValid(field, raw)
        }

    // Values are persisted into the collection and sent to TMDB verbatim — anything TMDB rejects
    // makes the whole source stop loading, so gate the obvious garbage here (Codex round 2):
    // votes are 0–10 finite, counts non-negative, years plausible, dates real calendar dates,
    // id lists positive integers, codes two letters (ISO 639-1 / 3166-1).
    private fun isValid(field: TmdbFilterField, raw: String): Boolean =
        when (field.kind) {
            TmdbFilterFieldKind.DECIMAL -> raw.toDoubleOrNull()?.let { it in 0.0..10.0 } == true
            TmdbFilterFieldKind.INTEGER -> raw.toIntOrNull()?.let { value ->
                if (field == TmdbFilterField.YEAR) value in 1874..2100 else value >= 0
            } == true
            TmdbFilterFieldKind.DATE -> isValidIsoDate(raw)
            TmdbFilterFieldKind.ID_LIST -> splitIds(raw).let { ids ->
                ids.isNotEmpty() && ids.all { id -> (id.toIntOrNull() ?: 0) > 0 }
            }
            TmdbFilterFieldKind.SINGLE_CODE -> singleCodeRegex.matches(raw)
        }

    private fun normalizeSort(value: String): String? {
        val raw = value.trim()
        if (raw.isEmpty()) return null
        return TmdbCollectionSort.entries.firstOrNull { entry ->
            entry.value.equals(raw, ignoreCase = true) || entry.name.equals(raw, ignoreCase = true)
        }?.value
    }

    // endregion
}

private val isoDateRegex = Regex("""(\d{4})-(\d{2})-(\d{2})""")
private val singleCodeRegex = Regex("""[A-Za-z]{2}""")

private fun isValidIsoDate(raw: String): Boolean {
    val match = isoDateRegex.matchEntire(raw) ?: return false
    val (year, month, day) = match.destructured
    val y = year.toInt()
    val m = month.toInt()
    val d = day.toInt()
    if (m !in 1..12 || d < 1) return false
    val leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
    val daysInMonth = when (m) {
        4, 6, 9, 11 -> 30
        2 -> if (leap) 29 else 28
        else -> 31
    }
    return d <= daysInMonth
}

private val filterConsumingSourceTypes = setOf(
    TmdbCollectionSourceType.DISCOVER,
    TmdbCollectionSourceType.COMPANY,
    TmdbCollectionSourceType.NETWORK,
)

private fun splitIds(raw: String): List<String> =
    raw.split(',', '|').map { it.trim() }.filter { it.isNotEmpty() }

private fun emptyFieldMap(): Map<TmdbFilterField, String> =
    TmdbFilterField.entries.associateWith { "" }

private fun TmdbCollectionFilters.toFieldMap(): Map<TmdbFilterField, String> =
    TmdbFilterField.entries.associateWith { field ->
        when (field) {
            TmdbFilterField.WITH_GENRES -> withGenres
            TmdbFilterField.WITHOUT_GENRES -> withoutGenres
            TmdbFilterField.RELEASE_DATE_GTE -> releaseDateGte
            TmdbFilterField.RELEASE_DATE_LTE -> releaseDateLte
            TmdbFilterField.VOTE_AVERAGE_GTE -> voteAverageGte?.toString()
            TmdbFilterField.VOTE_AVERAGE_LTE -> voteAverageLte?.toString()
            TmdbFilterField.VOTE_COUNT_GTE -> voteCountGte?.toString()
            TmdbFilterField.WITH_ORIGINAL_LANGUAGE -> withOriginalLanguage
            TmdbFilterField.WITH_ORIGIN_COUNTRY -> withOriginCountry
            TmdbFilterField.WITH_KEYWORDS -> withKeywords
            TmdbFilterField.WITHOUT_KEYWORDS -> withoutKeywords
            TmdbFilterField.WITH_COMPANIES -> withCompanies
            TmdbFilterField.WITHOUT_COMPANIES -> withoutCompanies
            TmdbFilterField.WITH_NETWORKS -> withNetworks
            TmdbFilterField.YEAR -> year?.toString()
            TmdbFilterField.WATCH_REGION -> watchRegion
            TmdbFilterField.WITH_WATCH_PROVIDERS -> withWatchProviders
            TmdbFilterField.WITHOUT_WATCH_PROVIDERS -> withoutWatchProviders
        }.orEmpty()
    }

/** Blank → null, otherwise trimmed; numeric fields parsed (callers validate first). */
private fun Map<TmdbFilterField, String>.toFilters(): TmdbCollectionFilters {
    fun text(field: TmdbFilterField): String? = this[field]?.trim()?.takeIf { it.isNotEmpty() }
    return TmdbCollectionFilters(
        withGenres = text(TmdbFilterField.WITH_GENRES),
        withoutGenres = text(TmdbFilterField.WITHOUT_GENRES),
        releaseDateGte = text(TmdbFilterField.RELEASE_DATE_GTE),
        releaseDateLte = text(TmdbFilterField.RELEASE_DATE_LTE),
        voteAverageGte = text(TmdbFilterField.VOTE_AVERAGE_GTE)?.toDoubleOrNull(),
        voteAverageLte = text(TmdbFilterField.VOTE_AVERAGE_LTE)?.toDoubleOrNull(),
        voteCountGte = text(TmdbFilterField.VOTE_COUNT_GTE)?.toIntOrNull(),
        withOriginalLanguage = text(TmdbFilterField.WITH_ORIGINAL_LANGUAGE),
        withOriginCountry = text(TmdbFilterField.WITH_ORIGIN_COUNTRY),
        withKeywords = text(TmdbFilterField.WITH_KEYWORDS),
        withoutKeywords = text(TmdbFilterField.WITHOUT_KEYWORDS),
        withCompanies = text(TmdbFilterField.WITH_COMPANIES),
        withoutCompanies = text(TmdbFilterField.WITHOUT_COMPANIES),
        withNetworks = text(TmdbFilterField.WITH_NETWORKS),
        year = text(TmdbFilterField.YEAR)?.toIntOrNull(),
        watchRegion = text(TmdbFilterField.WATCH_REGION),
        withWatchProviders = text(TmdbFilterField.WITH_WATCH_PROVIDERS),
        withoutWatchProviders = text(TmdbFilterField.WITHOUT_WATCH_PROVIDERS),
    )
}

// Local copies of CollectionEditorRepository's private helpers (kept private there; duplicating two
// one-liners beats widening their visibility).
private fun CollectionFolder.withSources(nextSources: List<CollectionSource>): CollectionFolder =
    copy(
        sources = nextSources,
        catalogSources = nextSources.mapNotNull { it.addonCatalogSource() },
    )

private fun CollectionSource.tmdbType(): TmdbCollectionSourceType =
    tmdbSourceType
        ?.let { raw -> runCatching { TmdbCollectionSourceType.valueOf(raw.uppercase()) }.getOrNull() }
        ?: TmdbCollectionSourceType.DISCOVER
