package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlaybackSpeedPolicyTest {

    @Test
    fun offersEightStepsFromQuarterToDouble() {
        assertEquals(listOf(0.25f, 0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f), PlaybackSpeedPolicy.steps)
    }

    @Test
    fun normalSpeedIsNotStored() {
        assertNull(PlaybackSpeedPolicy.storedValue(1f))
        assertNull(PlaybackSpeedPolicy.storedValue(1.0004f))
        assertNull(PlaybackSpeedPolicy.storedValue(Float.NaN))
    }

    @Test
    fun otherSpeedsAreStoredWithinTheOfferedRange() {
        assertEquals(1.5f, PlaybackSpeedPolicy.storedValue(1.5f))
        assertEquals(0.25f, PlaybackSpeedPolicy.storedValue(0.1f))
        assertEquals(2f, PlaybackSpeedPolicy.storedValue(8f))
        PlaybackSpeedPolicy.steps.filter { it != 1f }.forEach {
            assertEquals(it, PlaybackSpeedPolicy.storedValue(it))
        }
    }

    @Test
    fun onlyInRangeStoredSpeedsAreReplayed() {
        assertNull(PlaybackSpeedPolicy.restoredValue(null))
        assertNull(PlaybackSpeedPolicy.restoredValue(1f))
        assertNull(PlaybackSpeedPolicy.restoredValue(0f))
        assertNull(PlaybackSpeedPolicy.restoredValue(3f))
        assertEquals(1.25f, PlaybackSpeedPolicy.restoredValue(1.25f))
    }

    @Test
    fun overlaySettingsDefaultToOn() {
        val state = PlayerSettingsUiState()
        assertTrue(state.showLoadingOverlay)
        assertTrue(state.showParentalGuide)
        assertTrue(state.osdClockEnabled)
    }
}
