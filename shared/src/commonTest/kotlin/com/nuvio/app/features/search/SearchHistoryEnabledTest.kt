package com.nuvio.app.features.search

import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Upstream 7c1c6578 (#1934): the recent-searches switch. Mirrors upstream's
 * SearchHistoryPreferencesTest on the platform storage the shared test targets provide.
 */
class SearchHistoryEnabledTest {
    @BeforeTest
    fun reset() {
        SearchHistoryStorage.savePayload("[]")
        SearchHistoryStorage.saveEnabled(true)
        SearchHistoryRepository.onProfileChanged()
    }

    @Test
    fun `history is recorded and shown while enabled`() {
        SearchHistoryRepository.recordSearch("dune")
        SearchHistoryRepository.recordSearch("silo")

        assertTrue(SearchHistoryRepository.enabled.value)
        assertEquals(listOf("silo", "dune"), SearchHistoryRepository.uiState.value)
    }

    @Test
    fun `disabling survives a reload, hides history and stops recording until re-enabled`() {
        SearchHistoryRepository.recordSearch("dune")
        SearchHistoryRepository.setEnabled(false)
        assertTrue(SearchHistoryRepository.uiState.value.isEmpty())

        SearchHistoryRepository.onProfileChanged()
        assertFalse(SearchHistoryRepository.enabled.value)
        assertTrue(SearchHistoryRepository.uiState.value.isEmpty())
        SearchHistoryRepository.recordSearch("silo")

        SearchHistoryRepository.setEnabled(true)
        SearchHistoryRepository.onProfileChanged()
        assertTrue(SearchHistoryRepository.enabled.value)
        assertEquals(listOf("dune"), SearchHistoryRepository.uiState.value)

        SearchHistoryRepository.recordSearch("arrival")
        assertEquals(listOf("arrival", "dune"), SearchHistoryRepository.uiState.value)
    }
}
