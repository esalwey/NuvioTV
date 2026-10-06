package com.nuvio.app.features.search

import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/// Upstream 085e8dc6 (#1819): while an enabled addon's manifest is still loading, Search/Discover
/// publish a loading state instead of a terminal "no active addons" — and settle to the right empty
/// state once it lands or fails. These are the two repository cases from upstream's
/// `SearchRequestStateTest`; the rest of that file tests `canReuseRequestState`, which this fork
/// replaced with inline reuse guards, so it is not ported. Both cases return before any network call.
class SearchAddonManifestStateTest {
    @Test
    fun `unresolved addon stays loading before surfacing manifest failure`() {
        val pendingAddon = ManagedAddon(
            manifestUrl = "https://pending.example/manifest.json",
            isRefreshing = true,
        )
        val failedAddon = pendingAddon.copy(
            isRefreshing = false,
            errorMessage = "Timed out",
        )

        try {
            SearchRepository.reset()
            SearchRepository.search(query = "movie", addons = listOf(pendingAddon))
            SearchRepository.refreshDiscover(addons = listOf(pendingAddon))

            assertTrue(SearchRepository.uiState.value.isLoading)
            assertEquals(null, SearchRepository.uiState.value.emptyStateReason)
            assertTrue(SearchRepository.discoverUiState.value.isLoading)
            assertEquals(null, SearchRepository.discoverUiState.value.emptyStateReason)

            SearchRepository.search(query = "movie", addons = listOf(failedAddon))
            SearchRepository.refreshDiscover(addons = listOf(failedAddon))

            assertFalse(SearchRepository.uiState.value.isLoading)
            assertEquals(SearchEmptyStateReason.RequestFailed, SearchRepository.uiState.value.emptyStateReason)
            assertEquals("Timed out", SearchRepository.uiState.value.errorMessage)
            assertFalse(SearchRepository.discoverUiState.value.isLoading)
            assertEquals(
                DiscoverEmptyStateReason.RequestFailed,
                SearchRepository.discoverUiState.value.emptyStateReason,
            )
            assertEquals("Timed out", SearchRepository.discoverUiState.value.errorMessage)
        } finally {
            SearchRepository.reset()
        }
    }

    @Test
    fun `pending addon settles to catalog capability empty states`() {
        val loadedAddon = ManagedAddon(
            manifestUrl = "https://loaded.example/manifest.json",
            manifest = AddonManifest(
                id = "loaded",
                name = "Loaded",
                description = "",
                version = "1.0.0",
                resources = listOf(AddonResource(name = "meta", types = listOf("movie"))),
                types = listOf("movie"),
                catalogs = emptyList(),
                transportUrl = "https://loaded.example/manifest.json",
            ),
        )
        val pendingAddon = ManagedAddon(
            manifestUrl = "https://pending.example/manifest.json",
            isRefreshing = true,
        )
        val failedAddon = pendingAddon.copy(
            isRefreshing = false,
            errorMessage = "Timed out",
        )

        try {
            SearchRepository.reset()
            SearchRepository.search(query = "movie", addons = listOf(loadedAddon, pendingAddon))
            SearchRepository.refreshDiscover(addons = listOf(loadedAddon, pendingAddon))

            assertTrue(SearchRepository.uiState.value.isLoading)
            assertTrue(SearchRepository.discoverUiState.value.isLoading)

            SearchRepository.search(query = "movie", addons = listOf(loadedAddon, failedAddon))
            SearchRepository.refreshDiscover(addons = listOf(loadedAddon, failedAddon))

            assertFalse(SearchRepository.uiState.value.isLoading)
            assertEquals(SearchEmptyStateReason.NoSearchCatalogs, SearchRepository.uiState.value.emptyStateReason)
            assertFalse(SearchRepository.discoverUiState.value.isLoading)
            assertEquals(
                DiscoverEmptyStateReason.NoDiscoverCatalogs,
                SearchRepository.discoverUiState.value.emptyStateReason,
            )
        } finally {
            SearchRepository.reset()
        }
    }
}
