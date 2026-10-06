package com.nuvio.app.features.collection

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TmdbSourceFilterEditorTest {
    private val collectionId = "tmdb-filter-editor-test-collection"
    private val folderId = "folder-1"

    private val addonSource = CollectionSource(
        provider = "addon",
        addonId = "com.example.addon",
        type = "movie",
        catalogId = "top",
    )

    private val discoverSource = CollectionSource(
        provider = "tmdb",
        tmdbSourceType = TmdbCollectionSourceType.DISCOVER.name,
        title = "Sci-Fi Picks",
        mediaType = TmdbCollectionMediaType.MOVIE.name,
        sortBy = TmdbCollectionSort.VOTE_AVERAGE_DESC.value,
        filters = TmdbCollectionFilters(
            withGenres = "878",
            withoutGenres = "16,27",
            releaseDateGte = "2010-01-01",
            voteAverageGte = 7.5,
            voteCountGte = 200,
            withOriginalLanguage = "en",
            withoutKeywords = "9715",
            withoutCompanies = "420",
            year = 2021,
            watchRegion = "US",
            withWatchProviders = "8",
            withoutWatchProviders = "337",
        ),
    )

    @BeforeTest
    fun setUp() {
        TmdbSourceFilterEditor.cancel()
        // Deterministic, key-free genre source for every test; individual tests override it.
        TmdbSourceFilterEditor.genreLoader = { emptyMap() }
        seed(
            folders = listOf(
                CollectionFolder(
                    id = folderId,
                    title = "Folder",
                    sources = listOf(addonSource, discoverSource),
                    catalogSources = listOf(addonSource.addonCatalogSource()!!),
                ),
            ),
        )
    }

    @AfterTest
    fun tearDown() {
        TmdbSourceFilterEditor.cancel()
        TmdbSourceFilterEditor.genreLoader = { TmdbCollectionSourceResolver.genres(it) }
    }

    private fun seed(folders: List<CollectionFolder>) {
        CollectionRepository.clearLocalState()
        CollectionRepository.setCollections(
            listOf(Collection(id = collectionId, title = "Editor Test", folders = folders)),
        )
    }

    private fun state(): TmdbSourceFilterEditorState =
        assertNotNull(TmdbSourceFilterEditor.uiState.value, "editor state should be active")

    private fun savedSource(index: Int = 1): CollectionSource =
        assertNotNull(CollectionRepository.getCollection(collectionId))
            .folders.first { it.id == folderId }
            .resolvedSources[index]

    private fun awaitGenresSettled(): TmdbSourceFilterEditorState = runBlocking {
        withTimeout(5_000) {
            TmdbSourceFilterEditor.uiState.first { it != null && !it.isLoadingGenres }!!
        }
    }

    @Test
    fun beginLoadsExistingTmdbSourceIntoStringFields() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))

        val state = state()
        assertEquals(collectionId, state.collectionId)
        assertEquals(folderId, state.folderId)
        assertEquals(1, state.sourceIndex)
        assertEquals("Sci-Fi Picks", state.sourceTitle)
        assertEquals(TmdbCollectionSourceType.DISCOVER, state.tmdbSourceType)
        assertEquals(TmdbCollectionMediaType.MOVIE, state.mediaType)
        assertEquals(TmdbCollectionSort.VOTE_AVERAGE_DESC.value, state.sortBy)
        assertTrue(state.supportsFilters)
        assertFalse(state.isDirty)
        assertFalse(state.saved)

        // Every field is present, "" when unset.
        assertEquals(TmdbFilterField.entries.toSet(), state.fields.keys)
        assertEquals("878", state.value(TmdbFilterField.WITH_GENRES))
        assertEquals("16,27", state.value(TmdbFilterField.WITHOUT_GENRES))
        assertEquals("2010-01-01", state.value(TmdbFilterField.RELEASE_DATE_GTE))
        assertEquals("", state.value(TmdbFilterField.RELEASE_DATE_LTE))
        assertEquals("7.5", state.value(TmdbFilterField.VOTE_AVERAGE_GTE))
        assertEquals("", state.value(TmdbFilterField.VOTE_AVERAGE_LTE))
        assertEquals("200", state.value(TmdbFilterField.VOTE_COUNT_GTE))
        assertEquals("en", state.value(TmdbFilterField.WITH_ORIGINAL_LANGUAGE))
        assertEquals("", state.value(TmdbFilterField.WITH_KEYWORDS))
        assertEquals("9715", state.value(TmdbFilterField.WITHOUT_KEYWORDS))
        assertEquals("420", state.value(TmdbFilterField.WITHOUT_COMPANIES))
        assertEquals("2021", state.value(TmdbFilterField.YEAR))
        assertEquals("US", state.value(TmdbFilterField.WATCH_REGION))
        assertEquals("8", state.value(TmdbFilterField.WITH_WATCH_PROVIDERS))
        assertEquals("337", state.value(TmdbFilterField.WITHOUT_WATCH_PROVIDERS))
        assertEquals(listOf("16", "27"), state.ids(TmdbFilterField.WITHOUT_GENRES))
        assertTrue(state.contains(TmdbFilterField.WITHOUT_GENRES, "27"))
        assertFalse(state.contains(TmdbFilterField.WITHOUT_GENRES, "28"))
    }

    @Test
    fun beginDefaultsWhenSourceHasNoFiltersOrSort() {
        seed(
            folders = listOf(
                CollectionFolder(
                    id = folderId,
                    title = "Folder",
                    sources = listOf(
                        CollectionSource(
                            provider = "tmdb",
                            tmdbSourceType = "network",
                            tmdbId = 213,
                            mediaType = "tv",
                        ),
                    ),
                ),
            ),
        )

        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 0))

        val state = state()
        assertEquals("TMDB", state.sourceTitle)
        assertEquals(TmdbCollectionSourceType.NETWORK, state.tmdbSourceType)
        assertEquals(TmdbCollectionMediaType.TV, state.mediaType)
        assertEquals(TmdbCollectionSort.POPULAR_DESC.value, state.sortBy)
        assertTrue(state.fields.values.all { it.isEmpty() })
    }

    @Test
    fun beginRejectsMissingOrNonTmdbSources() {
        assertFalse(TmdbSourceFilterEditor.begin("nope", folderId, 1))
        assertNull(TmdbSourceFilterEditor.uiState.value)
        assertFalse(TmdbSourceFilterEditor.begin(collectionId, "nope", 1))
        assertNull(TmdbSourceFilterEditor.uiState.value)
        assertFalse(TmdbSourceFilterEditor.begin(collectionId, folderId, 0), "addon source is not editable")
        assertNull(TmdbSourceFilterEditor.uiState.value)
        assertFalse(TmdbSourceFilterEditor.begin(collectionId, folderId, 5), "out of range")
        assertNull(TmdbSourceFilterEditor.uiState.value)
    }

    @Test
    fun beginRejectsLegacyCatalogSourcesOnlyFolder() {
        seed(
            folders = listOf(
                CollectionFolder(
                    id = folderId,
                    title = "Legacy",
                    catalogSources = listOf(addonSource.addonCatalogSource()!!),
                ),
            ),
        )

        assertFalse(TmdbSourceFilterEditor.begin(collectionId, folderId, 0))
        assertNull(TmdbSourceFilterEditor.uiState.value)
    }

    @Test
    fun setFieldMarksDirtyAndClearsInvalidFlag() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))
        TmdbSourceFilterEditor.setField(TmdbFilterField.YEAR, "abc")
        assertFalse(TmdbSourceFilterEditor.save())
        assertEquals(listOf(TmdbFilterField.YEAR), state().invalidFields)
        assertTrue(state().isInvalid(TmdbFilterField.YEAR))

        TmdbSourceFilterEditor.setField(TmdbFilterField.YEAR, "1999")

        val state = state()
        assertEquals("1999", state.value(TmdbFilterField.YEAR))
        assertTrue(state.isDirty)
        assertTrue(state.invalidFields.isEmpty())
        assertFalse(state.saved)
    }

    @Test
    fun toggleIdAddsRemovesAndPreservesOrder() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))

        // "" → id
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_KEYWORDS, "9715")
        assertEquals("9715", state().value(TmdbFilterField.WITH_KEYWORDS))
        // append
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_KEYWORDS, "818")
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_KEYWORDS, "4379")
        assertEquals("9715,818,4379", state().value(TmdbFilterField.WITH_KEYWORDS))
        // remove the middle one, order of the rest preserved
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_KEYWORDS, "818")
        assertEquals("9715,4379", state().value(TmdbFilterField.WITH_KEYWORDS))
        // remove all → ""
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_KEYWORDS, "9715")
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_KEYWORDS, "4379")
        assertEquals("", state().value(TmdbFilterField.WITH_KEYWORDS))
        // existing comma list from the seed: remove one, add one
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITHOUT_GENRES, "16")
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITHOUT_GENRES, "28")
        assertEquals("27,28", state().value(TmdbFilterField.WITHOUT_GENRES))
        // pipe-joined lists are understood for membership and normalised to commas
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITHOUT_WATCH_PROVIDERS, "8|337|350")
        assertTrue(state().contains(TmdbFilterField.WITHOUT_WATCH_PROVIDERS, "337"))
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITHOUT_WATCH_PROVIDERS, "337")
        assertEquals("8,350", state().value(TmdbFilterField.WITHOUT_WATCH_PROVIDERS))
        // blank ids are ignored
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITHOUT_WATCH_PROVIDERS, "  ")
        assertEquals("8,350", state().value(TmdbFilterField.WITHOUT_WATCH_PROVIDERS))
        assertTrue(state().isDirty)
    }

    @Test
    fun toggleIdReplacesSingleValuedFields() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))
        assertEquals("en", state().value(TmdbFilterField.WITH_ORIGINAL_LANGUAGE))

        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_ORIGINAL_LANGUAGE, "ko")
        assertEquals("ko", state().value(TmdbFilterField.WITH_ORIGINAL_LANGUAGE))
        // same value again clears
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_ORIGINAL_LANGUAGE, "ko")
        assertEquals("", state().value(TmdbFilterField.WITH_ORIGINAL_LANGUAGE))

        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_ORIGIN_COUNTRY, "KR")
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_ORIGIN_COUNTRY, "JP")
        assertEquals("JP", state().value(TmdbFilterField.WITH_ORIGIN_COUNTRY))

        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WATCH_REGION, "GB")
        assertEquals("GB", state().value(TmdbFilterField.WATCH_REGION))
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WATCH_REGION, "GB")
        assertEquals("", state().value(TmdbFilterField.WATCH_REGION))
    }

    @Test
    fun setSortByNormalisesAndIgnoresUnknown() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))

        TmdbSourceFilterEditor.setSortBy("VOTE_COUNT_DESC")
        assertEquals(TmdbCollectionSort.VOTE_COUNT_DESC.value, state().sortBy)
        TmdbSourceFilterEditor.setSortBy("primary_release_date.desc")
        assertEquals(TmdbCollectionSort.RELEASE_DATE_DESC.value, state().sortBy)
        TmdbSourceFilterEditor.setSortBy("bogus.sort")
        assertEquals(TmdbCollectionSort.RELEASE_DATE_DESC.value, state().sortBy)
        assertTrue(state().isDirty)
    }

    @Test
    fun clearFiltersBlanksEverythingButKeepsSort() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))

        TmdbSourceFilterEditor.clearFilters()

        val state = state()
        assertTrue(state.fields.values.all { it.isEmpty() })
        assertEquals(TmdbFilterField.entries.toSet(), state.fields.keys)
        assertEquals(TmdbCollectionSort.VOTE_AVERAGE_DESC.value, state.sortBy)
        assertTrue(state.isDirty)
    }

    @Test
    fun saveRejectsInvalidValuesAndReportsFields() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))
        TmdbSourceFilterEditor.setField(TmdbFilterField.RELEASE_DATE_GTE, "2020/01/01")
        TmdbSourceFilterEditor.setField(TmdbFilterField.RELEASE_DATE_LTE, "2021-1-1")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_AVERAGE_GTE, "seven")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_AVERAGE_LTE, "9,5")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_COUNT_GTE, "1.5")
        TmdbSourceFilterEditor.setField(TmdbFilterField.YEAR, "20x1")
        // id lists must be positive integers (Codex round 2 — no longer waved through)
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_GENRES, "anything")

        assertFalse(TmdbSourceFilterEditor.save())

        val state = state()
        assertEquals(
            listOf(
                TmdbFilterField.WITH_GENRES,
                TmdbFilterField.RELEASE_DATE_GTE,
                TmdbFilterField.RELEASE_DATE_LTE,
                TmdbFilterField.VOTE_AVERAGE_GTE,
                TmdbFilterField.VOTE_AVERAGE_LTE,
                TmdbFilterField.VOTE_COUNT_GTE,
                TmdbFilterField.YEAR,
            ),
            state.invalidFields,
        )
        assertFalse(state.saved)
        assertFalse(state.saveFailed)
        assertTrue(state.isDirty)
        // Nothing was written.
        assertEquals(discoverSource, savedSource())
    }

    @Test
    fun saveRejectsOutOfRangeAndMalformedValues() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_AVERAGE_GTE, "NaN")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_AVERAGE_LTE, "11")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_COUNT_GTE, "-5")
        TmdbSourceFilterEditor.setField(TmdbFilterField.YEAR, "1600")
        TmdbSourceFilterEditor.setField(TmdbFilterField.RELEASE_DATE_GTE, "2023-02-29")
        TmdbSourceFilterEditor.setField(TmdbFilterField.RELEASE_DATE_LTE, "2024-13-01")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_KEYWORDS, "818,-4")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_NETWORKS, ",,")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_ORIGINAL_LANGUAGE, "english")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WATCH_REGION, "U5")

        assertFalse(TmdbSourceFilterEditor.save())
        assertEquals(
            listOf(
                TmdbFilterField.RELEASE_DATE_GTE,
                TmdbFilterField.RELEASE_DATE_LTE,
                TmdbFilterField.VOTE_AVERAGE_GTE,
                TmdbFilterField.VOTE_AVERAGE_LTE,
                TmdbFilterField.VOTE_COUNT_GTE,
                TmdbFilterField.WITH_ORIGINAL_LANGUAGE,
                TmdbFilterField.WITH_KEYWORDS,
                TmdbFilterField.WITH_NETWORKS,
                TmdbFilterField.YEAR,
                TmdbFilterField.WATCH_REGION,
            ),
            state().invalidFields,
        )
        assertEquals(discoverSource, savedSource(), "nothing was written")

        // Boundary values are accepted: leap day, rating edges, year edges, pipe-joined ids.
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_AVERAGE_GTE, "0")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_AVERAGE_LTE, "10")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_COUNT_GTE, "0")
        TmdbSourceFilterEditor.setField(TmdbFilterField.YEAR, "1874")
        TmdbSourceFilterEditor.setField(TmdbFilterField.RELEASE_DATE_GTE, "2024-02-29")
        TmdbSourceFilterEditor.setField(TmdbFilterField.RELEASE_DATE_LTE, "2024-12-31")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_KEYWORDS, "818|4379")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_NETWORKS, "213")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_ORIGINAL_LANGUAGE, "ko")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WATCH_REGION, "GB")
        assertTrue(TmdbSourceFilterEditor.save())
        assertTrue(state().invalidFields.isEmpty())
    }

    @Test
    fun saveReportsFailureWhenPersistenceDoesNotLand() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_KEYWORDS, "818")

        CollectionRepository.payloadWriter = { false }
        try {
            assertFalse(TmdbSourceFilterEditor.save(), "a swallowed storage failure must not report success")
        } finally {
            CollectionRepository.payloadWriter = { CollectionStorage.savePayload(it) }
        }

        val state = state()
        assertTrue(state.saveFailed)
        assertFalse(state.saved)
        assertTrue(state.isDirty)

        // The same draft saves once storage works again.
        assertTrue(TmdbSourceFilterEditor.save())
        assertTrue(state().saved)
    }

    @Test
    fun updateCollectionRejectsAMissingTarget() {
        // A sync pull can remove the collection between the editor's re-read and the repository
        // mutation; the map used to change nothing and still report success.
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))
        val current = CollectionRepository.getCollection(collectionId)!!

        CollectionRepository.removeCollection(collectionId)

        assertFalse(
            CollectionRepository.updateCollection(current),
            "updating a removed collection must not report success",
        )
    }

    @Test
    fun saveWritesFiltersBackWithBlankAsNullAndSortPreserved() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_GENRES, "")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITHOUT_GENRES, " 16,27 ")
        TmdbSourceFilterEditor.setField(TmdbFilterField.RELEASE_DATE_GTE, "")
        TmdbSourceFilterEditor.setField(TmdbFilterField.RELEASE_DATE_LTE, "2024-12-31")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_AVERAGE_GTE, "6")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_AVERAGE_LTE, "9.5")
        TmdbSourceFilterEditor.setField(TmdbFilterField.VOTE_COUNT_GTE, " 50 ")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_ORIGINAL_LANGUAGE, "")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_KEYWORDS, "818")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITHOUT_KEYWORDS, "")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_COMPANIES, "2,3")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITHOUT_COMPANIES, "174")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_NETWORKS, "")
        TmdbSourceFilterEditor.setField(TmdbFilterField.YEAR, "")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WATCH_REGION, "GB")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_WATCH_PROVIDERS, "")
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITHOUT_WATCH_PROVIDERS, "8|337")
        TmdbSourceFilterEditor.setSortBy(TmdbCollectionSort.POPULAR_DESC.value)

        assertTrue(TmdbSourceFilterEditor.save())

        val state = state()
        assertTrue(state.saved)
        assertFalse(state.isDirty)
        assertFalse(state.isSaving)
        assertFalse(state.saveFailed)
        assertTrue(state.invalidFields.isEmpty())

        val written = savedSource()
        assertEquals("tmdb", written.provider)
        assertEquals("Sci-Fi Picks", written.title)
        assertEquals(TmdbCollectionSourceType.DISCOVER.name, written.tmdbSourceType)
        assertEquals(TmdbCollectionMediaType.MOVIE.name, written.mediaType)
        assertEquals(TmdbCollectionSort.POPULAR_DESC.value, written.sortBy)
        assertEquals(
            TmdbCollectionFilters(
                withGenres = null,
                withoutGenres = "16,27",
                releaseDateGte = null,
                releaseDateLte = "2024-12-31",
                voteAverageGte = 6.0,
                voteAverageLte = 9.5,
                voteCountGte = 50,
                withOriginalLanguage = null,
                withOriginCountry = null,
                withKeywords = "818",
                withoutKeywords = null,
                withCompanies = "2,3",
                withoutCompanies = "174",
                withNetworks = null,
                year = null,
                watchRegion = "GB",
                withWatchProviders = null,
                withoutWatchProviders = "8|337",
            ),
            written.filters,
        )
        // The sibling addon source and its legacy catalogSources mirror are untouched.
        val folder = assertNotNull(CollectionRepository.getCollection(collectionId)).folders.first { it.id == folderId }
        assertEquals(addonSource, folder.sources[0])
        assertEquals(listOf(addonSource.addonCatalogSource()!!), folder.catalogSources)
        assertEquals("Editor Test", assertNotNull(CollectionRepository.getCollection(collectionId)).title)
    }

    @Test
    fun saveWithoutChangesKeepsSourceAndSucceeds() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))

        assertTrue(TmdbSourceFilterEditor.save())

        assertEquals(discoverSource, savedSource())
        assertTrue(state().saved)
    }

    @Test
    fun saveRefreshesStaleLegacyCatalogSourcesFromSources() {
        val secondAddon = addonSource.copy(catalogId = "new", type = "series")
        seed(
            folders = listOf(
                CollectionFolder(
                    id = folderId,
                    title = "Stale legacy mirror",
                    sources = listOf(addonSource, secondAddon, discoverSource),
                    // Legacy mirror is stale (missing secondAddon) — save must rebuild it from sources.
                    catalogSources = listOf(addonSource.addonCatalogSource()!!),
                ),
            ),
        )
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 2))
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITHOUT_COMPANIES, "2")

        assertTrue(TmdbSourceFilterEditor.save())

        val folder = assertNotNull(CollectionRepository.getCollection(collectionId)).folders.first { it.id == folderId }
        assertEquals(3, folder.sources.size)
        assertEquals("420,2", folder.sources[2].filters?.withoutCompanies)
        assertEquals(
            listOf(addonSource.addonCatalogSource()!!, secondAddon.addonCatalogSource()!!),
            folder.catalogSources,
        )
    }

    @Test
    fun saveFailsGracefullyWhenCollectionDisappearedMidEdit() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_GENRES, "28")
        CollectionRepository.removeCollection(collectionId)

        assertFalse(TmdbSourceFilterEditor.save())

        val state = state()
        assertTrue(state.saveFailed)
        assertFalse(state.saved)
        assertTrue(state.isDirty)
        assertFalse(state.isSaving)
    }

    @Test
    fun cancelClearsState() {
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))
        assertNotNull(TmdbSourceFilterEditor.uiState.value)

        TmdbSourceFilterEditor.cancel()

        assertNull(TmdbSourceFilterEditor.uiState.value)
        // Setters after cancel are no-ops and must not resurrect state.
        TmdbSourceFilterEditor.setField(TmdbFilterField.WITH_GENRES, "28")
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_GENRES, "28")
        TmdbSourceFilterEditor.clearFilters()
        assertFalse(TmdbSourceFilterEditor.save())
        assertNull(TmdbSourceFilterEditor.uiState.value)
    }

    @Test
    fun loadGenresSortsByNameAndClearsLoadingFlag() {
        TmdbSourceFilterEditor.genreLoader = { mediaType ->
            assertEquals(TmdbCollectionMediaType.MOVIE, mediaType)
            mapOf(878 to "Science Fiction", 28 to "Action", 16 to "animation")
        }
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))

        val settled = awaitGenresSettled()

        assertFalse(settled.isLoadingGenres)
        assertEquals(
            listOf(
                TmdbGenreOption(28, "Action"),
                TmdbGenreOption(16, "animation"),
                TmdbGenreOption(878, "Science Fiction"),
            ),
            settled.availableGenres,
        )
    }

    @Test
    fun loadGenresFailureLeavesListEmptyWithoutCrashing() {
        TmdbSourceFilterEditor.genreLoader = { error("Add a TMDB API key in Settings to use TMDB sources.") }
        assertTrue(TmdbSourceFilterEditor.begin(collectionId, folderId, 1))

        val settled = awaitGenresSettled()

        assertFalse(settled.isLoadingGenres)
        assertTrue(settled.availableGenres.isEmpty())
        // The editor is still usable after the failed genre load.
        TmdbSourceFilterEditor.toggleId(TmdbFilterField.WITH_GENRES, "28")
        assertEquals("878,28", state().value(TmdbFilterField.WITH_GENRES))
    }

    @Test
    fun presetsCarryTheSharedQuickChipIds() {
        assertEquals(listOf("28", "12", "16", "35", "27", "878"), TmdbFilterPresets.movieGenreIds.map { it.value })
        assertEquals(listOf("18", "35", "16", "80", "10765", "10764"), TmdbFilterPresets.tvGenreIds.map { it.value })
        assertEquals(TmdbFilterPresets.tvGenreIds, TmdbFilterPresets.genreIds(TmdbCollectionMediaType.TV))
        assertEquals(listOf("9715", "818", "4379", "9882"), TmdbFilterPresets.keywords.map { it.value })
        assertEquals(listOf("420", "2", "3", "1", "174"), TmdbFilterPresets.companies.map { it.value })
        assertEquals(listOf("213", "49", "2739", "1024", "453", "2552"), TmdbFilterPresets.networks.map { it.value })
        assertEquals(listOf("8", "119", "337", "350", "15"), TmdbFilterPresets.watchProviders.map { it.value })
        assertEquals(listOf("en", "ko", "ja", "hi", "es"), TmdbFilterPresets.languages.map { it.value })
        assertEquals(listOf("US", "KR", "JP", "IN", "GB"), TmdbFilterPresets.countries.map { it.value })
        assertEquals(listOf("US", "GB", "CA", "AU", "DE"), TmdbFilterPresets.watchRegions.map { it.value })
        assertTrue(TmdbFilterField.WITH_ORIGINAL_LANGUAGE.isSingleValued)
        assertTrue(TmdbFilterField.WITHOUT_WATCH_PROVIDERS.isIdList)
        assertFalse(TmdbFilterField.YEAR.isIdList)
    }
}
