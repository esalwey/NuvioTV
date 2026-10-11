package com.nuvio.app.features.player

import com.nuvio.app.features.player.skip.AutoSkipSegmentType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AutoSkipSegmentTypeTest {

    @Test
    fun storedValuesRoundTrip() {
        AutoSkipSegmentType.entries.forEach { type ->
            assertEquals(type, AutoSkipSegmentType.fromStoredValue(type.storedValue))
        }
        assertNull(AutoSkipSegmentType.fromStoredValue("post-credits"))
        assertNull(AutoSkipSegmentType.fromStoredValue(""))
    }

    @Test
    fun providerTypesMapToTheirKind() {
        listOf("op", "opening", "mixed-op", "intro", " Intro ").forEach {
            assertEquals(AutoSkipSegmentType.INTRO, AutoSkipSegmentType.fromSkipIntervalType(it), it)
        }
        assertEquals(AutoSkipSegmentType.RECAP, AutoSkipSegmentType.fromSkipIntervalType("recap"))
        listOf("ed", "ending", "mixed-ed", "outro", "credits", "ED").forEach {
            assertEquals(AutoSkipSegmentType.OUTRO, AutoSkipSegmentType.fromSkipIntervalType(it), it)
        }
        assertEquals(AutoSkipSegmentType.MOVIE_CREDITS, AutoSkipSegmentType.fromSkipIntervalType("movie-credits"))
    }

    @Test
    fun postCreditsAndUnknownTypesAreNeverAutoSkipped() {
        assertNull(AutoSkipSegmentType.fromSkipIntervalType("post-credits"))
        assertNull(AutoSkipSegmentType.fromSkipIntervalType("preview"))
        assertNull(AutoSkipSegmentType.fromSkipIntervalType(""))
    }

    @Test
    fun uiStateExposesTheSelectionAsStoredValues() {
        val state = PlayerSettingsUiState(
            autoSkipSegmentTypes = setOf(AutoSkipSegmentType.INTRO, AutoSkipSegmentType.OUTRO),
        )
        assertEquals(setOf("intro", "outro"), state.autoSkipSegmentTypeValues)
        assertEquals(emptySet(), PlayerSettingsUiState().autoSkipSegmentTypeValues)
    }
}
