package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Fork (LANG-10, user feedback "VFF is not VFQ"): France vs Quebec French and the other regional
 * variants, for the audio pick at start, the saved per-title choice and the subtitle tie-break.
 */
class PlayerAudioVariantTest {
    private fun audio(index: Int, language: String?, label: String = "") =
        AudioTrack(index = index, id = "${index + 1}", label = label, language = language)

    private fun sub(index: Int, language: String?, label: String = "") =
        SubtitleTrack(index = index, id = "${index + 1}", label = label, language = language)

    @Test
    fun canonicalVariantCollapsesRegionsWithoutADistinctDub() {
        assertEquals("fr", SubtitleLanguageMatching.canonicalLanguageVariant("fr-FR"))
        assertEquals("fr", SubtitleLanguageMatching.canonicalLanguageVariant("fr-BE"))
        assertEquals("fr", SubtitleLanguageMatching.canonicalLanguageVariant("fre"))
        assertEquals("fr-ca", SubtitleLanguageMatching.canonicalLanguageVariant("fr-CA"))
        assertEquals("en", SubtitleLanguageMatching.canonicalLanguageVariant("en-US"))
        assertEquals("es", SubtitleLanguageMatching.canonicalLanguageVariant("es-ES"))
        assertEquals("es-419", SubtitleLanguageMatching.canonicalLanguageVariant("es-MX"))
        assertEquals("pt-br", SubtitleLanguageMatching.canonicalLanguageVariant("pt-BR"))
        assertEquals("pt", SubtitleLanguageMatching.canonicalLanguageVariant("pt-PT"))
        assertEquals("zh-tw", SubtitleLanguageMatching.canonicalLanguageVariant("zh-TW"))
        assertEquals("", SubtitleLanguageMatching.canonicalLanguageVariant(null))
        assertEquals("fr", SubtitleLanguageMatching.detectTrackLanguageVariant("fr-FR", null, null))
        assertEquals("fr-ca", SubtitleLanguageMatching.detectTrackLanguageVariant("fre", "French (Canada)", null))
    }

    @Test
    fun deviceRegionTargetsMatchPlainCodes() {
        assertTrue(SubtitleLanguageMatching.matchesLanguageCode("fre", "fr-FR"))
        assertTrue(SubtitleLanguageMatching.matchesLanguageCode("spa", "es-ES"))
        assertTrue(SubtitleLanguageMatching.matchesLanguageCode("fr-CA", "fr"))
        assertFalse(SubtitleLanguageMatching.matchesLanguageCode("es-MX", "es"))
        assertFalse(SubtitleLanguageMatching.matchesLanguageCode("fre", "fr-CA"))
    }

    @Test
    fun appleTvFranceLanguagePicksTheFranceDub() {
        // The Apple TV set to French (France) yields the target "fr-fr" first.
        val tracks = listOf(audio(0, "fre", "VFQ"), audio(1, "fre", "VFF"))
        assertEquals(1, findPreferredAudioTrackIndex(tracks, listOf("fr-fr", "fr")))
        assertEquals(0, findPreferredAudioTrackIndex(tracks, listOf("fr-CA", "fr")))
    }

    @Test
    fun franceTargetAvoidsTheQuebecDubWhenNoTrackSaysFrance() {
        val tracks = listOf(audio(0, "fre", "VFQ"), audio(1, "fre"), audio(2, "eng"))
        assertEquals(listOf(1), preferredAudioTrackCandidates(tracks, listOf("fr")))
        val quebecOnly = listOf(audio(0, "eng"), audio(1, "fre", "VFQ"))
        assertEquals(1, findPreferredAudioTrackIndex(quebecOnly, listOf("fr")))
    }

    @Test
    fun containerRegionTagsDecideTheVariant() {
        val tracks = listOf(audio(0, "fr-CA"), audio(1, "fr-FR"))
        assertEquals(1, findPreferredAudioTrackIndex(tracks, listOf("fr-FR")))
        assertEquals(0, findPreferredAudioTrackIndex(tracks, listOf("fr-CA")))
        val titled = listOf(audio(0, "fre", "French (Canada)"), audio(1, "fre", "French"))
        assertEquals(1, findPreferredAudioTrackIndex(titled, listOf("fr")))
        assertEquals(0, findPreferredAudioTrackIndex(titled, listOf("fr-ca")))
    }

    @Test
    fun untaggedTracksMatchByTitleButCodesWin() {
        val tracks = listOf(audio(0, "", "English"), audio(1, "und", "Espanol"))
        assertEquals(0, findPreferredAudioTrackIndex(tracks, listOf("en")))
        assertEquals(1, findPreferredAudioTrackIndex(tracks, listOf("es")))
        val coded = listOf(audio(0, "eng", "Français"), audio(1, "ger", "Deutsch"))
        assertEquals(-1, findPreferredAudioTrackIndex(coded, listOf("fr")))
        assertEquals(-1, findPreferredAudioTrackIndex(coded, emptyList()))
    }

    @Test
    fun savedQuebecChoiceIsNotHijackedByAReusedTrackId() {
        // Episode 1: the viewer picked track 2, "VFQ". Episode 2 numbers the France dub 2.
        val tracks = listOf(
            AudioTrack(0, "2", "French", "fre"),
            AudioTrack(1, "3", "French (Canada)", "fre"),
        )
        assertEquals(1, findPersistedAudioTrackIndex(tracks, PersistedPlayerTrackPreference(
            audioTrackId = "2", audioLanguage = "fre", audioName = "VFQ",
        )))
    }

    @Test
    fun savedFranceChoiceKeepsTheFranceDub() {
        val tracks = listOf(audio(0, "fre", "VFQ 5.1"), audio(1, "fre", "VFF 5.1"))
        assertEquals(1, findPersistedAudioTrackIndex(tracks, PersistedPlayerTrackPreference(
            audioTrackId = "1", audioLanguage = "fre", audioName = "VFF",
        )))
    }

    @Test
    fun nativeEngineDisplayNameStillRestoresTheVariant() {
        // Older native saves stored the menu label as the name.
        val tracks = listOf(audio(0, "fre", "VFF"), audio(1, "fre", "VFQ"))
        assertEquals(1, findPersistedAudioTrackIndex(tracks, PersistedPlayerTrackPreference(
            audioLanguage = "fr", audioName = "Français · Dolby Digital+ 5.1 · VFQ",
        )))
    }

    @Test
    fun initialPickPrefersTheSavedChoiceThenTheTargets() {
        val tracks = listOf(audio(0, "eng"), audio(1, "fre", "VFF"), audio(2, "fre", "VFQ"))
        assertEquals(2, resolveInitialAudioTrackIndex(tracks, listOf("fr"), "fre", "VFQ", null))
        assertEquals(1, resolveInitialAudioTrackIndex(tracks, listOf("fr"), null, null, null))
        // Saved language missing from this file: the settings decide.
        assertEquals(0, resolveInitialAudioTrackIndex(tracks, listOf("en"), "ja", "Japanese", "4"))
        assertEquals(-1, resolveInitialAudioTrackIndex(tracks, emptyList(), "ja", null, null))
    }

    @Test
    fun deviceRegionSubtitleTargetGetsTheFranceTieBreak() {
        val tracks = listOf(sub(0, "fre", "VFQ"), sub(1, "fre", "VFF"))
        assertEquals(1, findBestInternalSubtitleTrackIndex(tracks, listOf("fr-fr")))
        assertEquals(0, findBestInternalSubtitleTrackIndex(tracks, listOf("fr-ca")))
    }
}
