package com.nuvio.app.features.search

import com.nuvio.app.features.servers.FakeServerProvider
import com.nuvio.app.features.servers.ServerLibrary
import com.nuvio.app.features.servers.ServerMediaKind
import com.nuvio.app.features.servers.installFakeServer
import com.nuvio.app.features.servers.removeFakeServer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Jellyfin / Emby libraries in Discover: movie and show libraries are sources, a mixed library is not. */
class SearchServerSourcesTest {
    @BeforeTest
    fun setUp() = SearchRepository.reset()

    @AfterTest
    fun tearDown() {
        removeFakeServer()
        SearchRepository.reset()
    }

    @Test
    fun discoverListsMovieAndShowLibrariesAsServerSources() {
        installFakeServer(FakeServerProvider(movieCount = 5))

        SearchRepository.refreshDiscover(addons = emptyList(), forceRefresh = true)

        val state = SearchRepository.discoverUiState.value
        assertEquals(listOf("movie", "series"), state.typeOptions)
        val movie = assertNotNull(state.catalogOptions.firstOrNull { it.server?.libraryId == "10" })
        assertEquals("server:cfake:10", movie.key)
        assertEquals("Fake · Box", movie.addonName)
        assertEquals("Box · Movies", movie.catalogName)
        assertEquals("", movie.manifestUrl)
    }

    @Test
    fun searchAsksEachServerOncePerTypeEvenWithoutAddons() = runBlocking<Unit> {
        val provider = FakeServerProvider(movieCount = 5)
        installFakeServer(provider)

        SearchRepository.search(query = "matrix", addons = emptyList())
        withContext(Dispatchers.Default) {
            withTimeout(5_000L) {
                while (SearchRepository.uiState.value.let { it.isLoading || it.sections.isEmpty() }) delay(10)
            }
        }

        val state = SearchRepository.uiState.value
        assertEquals(listOf("Box · Movies", "Box · Series"), state.sections.map { it.title })
        assertEquals(listOf(ServerMediaKind.MOVIE, ServerMediaKind.SERIES), provider.searches.map { it.first })
    }

    @Test
    fun aMixedLibraryIsNotADiscoverSource() {
        val provider = FakeServerProvider(movieCount = 5)
        installFakeServer(provider, libraries = listOf(ServerLibrary("30", "Everything", ServerMediaKind.MIXED)))

        SearchRepository.refreshDiscover(addons = emptyList(), forceRefresh = true)

        val state = SearchRepository.discoverUiState.value
        assertTrue(state.catalogOptions.none { it.server != null })
    }
}
