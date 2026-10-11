package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals

class StreamBackgroundModeTest {

    @Test
    fun storedValuesAreReadInAnyCase() {
        assertEquals(StreamBackgroundMode.Normal, parseStreamBackgroundMode("normal"))
        assertEquals(StreamBackgroundMode.Cinematic, parseStreamBackgroundMode("cinematic"))
        assertEquals(StreamBackgroundMode.Cinematic, parseStreamBackgroundMode(" Cinematic "))
        assertEquals(StreamBackgroundMode.Normal, parseStreamBackgroundMode("NORMAL"))
    }

    @Test
    fun anUnsetOrUnknownValueKeepsTheArtworkBackground() {
        assertEquals(StreamBackgroundMode.Cinematic, parseStreamBackgroundMode(null))
        assertEquals(StreamBackgroundMode.Cinematic, parseStreamBackgroundMode(""))
        assertEquals(StreamBackgroundMode.Cinematic, parseStreamBackgroundMode("sepia"))
    }

    @Test
    fun theUiStateDefaultsToTheArtworkBackground() {
        assertEquals(StreamBackgroundMode.Cinematic, StreamBadgeSettingsUiState().backgroundMode)
    }
}
