// Upstream d95b4f9b4 (bahasa Indonesia mapping).
package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SubtitleIndonesianMatchingTest {
    @Test
    fun `bahasa indonesia labels normalize to indonesian`() {
        assertEquals("id", SubtitleLanguageMatching.normalizeLanguageCode("Bahasa Indonesia"))
        assertEquals("id", SubtitleLanguageMatching.normalizeLanguageCode("Indonesian"))
        assertEquals("id", SubtitleLanguageMatching.normalizeLanguageCode("ind"))
        assertTrue(SubtitleLanguageMatching.matchesLanguageCode("Bahasa Indonesia", "id"))
    }

    @Test
    fun `bahasa malaysia labels normalize to malay`() {
        assertEquals("ms", SubtitleLanguageMatching.normalizeLanguageCode("Bahasa Malaysia"))
        assertEquals("ms", SubtitleLanguageMatching.normalizeLanguageCode("Bahasa Melayu"))
        assertEquals("ms", SubtitleLanguageMatching.normalizeLanguageCode("may"))
    }

    @Test
    fun `a malay coded track labelled indonesian is indonesian`() {
        assertEquals(
            "id",
            SubtitleLanguageMatching.detectTrackLanguageVariant(language = "may", name = "Indonesian", trackId = null),
        )
        assertEquals(
            "ms",
            SubtitleLanguageMatching.detectTrackLanguageVariant(language = "msa", name = "Malay", trackId = null),
        )
    }
}
