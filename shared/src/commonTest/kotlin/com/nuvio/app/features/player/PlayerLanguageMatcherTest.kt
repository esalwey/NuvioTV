package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Fork (LANG-10/14, spec §8.1): native names, French release tags, SDH and the tvOS defaults. */
class PlayerLanguageMatcherTest {
    private fun sub(index: Int, language: String?, label: String = "", forced: Boolean = false) =
        SubtitleTrack(index = index, id = "${index + 1}", label = label, language = language, isForced = forced)

    private fun audio(language: String?, label: String = "") =
        AudioTrack(index = 0, id = "1", label = label, language = language, isSelected = true)

    @Test
    fun nativeNamesNormalize() {
        assertEquals("es", normalizeLanguageCode("Español"))
        assertEquals("fr", normalizeLanguageCode("Français"))
        assertEquals("de", normalizeLanguageCode("Deutsch"))
        assertEquals("pt", normalizeLanguageCode("Português"))
        assertEquals("ja", normalizeLanguageCode("日本語"))
        assertEquals("es-419", normalizeLanguageCode("Latino"))
        assertEquals("fr", SubtitleLanguageMatching.normalizeLanguageCode("Français"))
    }

    @Test
    fun codesAreUnchanged() {
        assertEquals("fr", normalizeLanguageCode("fre"))
        assertEquals("en", normalizeLanguageCode("English"))
        assertEquals("fr-ca", normalizeLanguageCode("fr-CA"))
        assertEquals("pt-br", normalizeLanguageCode("pt-BR"))
        assertEquals("fr", SubtitleLanguageMatching.normalizeLanguageCode("fre"))
    }

    @Test
    fun frenchReleaseTagsAreWholeWords() {
        assertEquals("fr", languageFromTrackText("VFF 5.1"))
        assertEquals("fr", languageFromTrackText("TrueFrench"))
        assertEquals("fr-ca", languageFromTrackText("VFQ"))
        assertEquals("fr-ca", languageFromTrackText("Français (Québec)"))
        assertEquals("fr-ca", languageFromTrackText("French Canadian"))
        assertEquals("fr", languageFromTrackText("MULTi VFF VFQ"))
        assertNull(languageFromTrackText("VFX breakdown"))
        assertNull(languageFromTrackText("English (Canada)"))
        assertNull(languageFromTrackText("Commentary"))
    }

    @Test
    fun frenchVariantDetection() {
        assertEquals("fr-ca", SubtitleLanguageMatching.detectTrackLanguageVariant("fre", "VFQ", "2"))
        assertEquals("fr", SubtitleLanguageMatching.detectTrackLanguageVariant("fre", "VFF", "1"))
        assertEquals("fr", SubtitleLanguageMatching.detectTrackLanguageVariant("fre", "French", "1"))
        assertEquals("fr-ca", SubtitleLanguageMatching.detectTrackLanguageVariant(null, "VFQ", "3"))
    }

    @Test
    fun titleRefinesCodeButNeverContradictsIt() {
        assertTrue(SubtitleLanguageMatching.trackMatchesLanguage("VFQ", "fre", "2", "fr-ca"))
        assertFalse(SubtitleLanguageMatching.trackMatchesLanguage("VFF", "fre", "1", "fr-ca"))
        assertTrue(SubtitleLanguageMatching.trackMatchesLanguage("Español", null, "1", "es"))
        assertFalse(SubtitleLanguageMatching.trackMatchesLanguage("Français", "eng", "1", "fr"))
    }

    @Test
    fun frenchTargetPrefersFranceDubAndQuebecTargetPrefersQuebec() {
        val tracks = listOf(sub(0, "fre", "VFQ"), sub(1, "fre", "VFF"))
        assertEquals(1, findBestInternalSubtitleTrackIndex(tracks, listOf("fr")))
        assertEquals(0, findBestInternalSubtitleTrackIndex(tracks, listOf("fr-ca")))
    }

    @Test
    fun onlyPreferredLanguagesWithNoTargetKeepsEverything() {
        val subtitles = listOf(
            AddonSubtitle(id = "a", url = "https://x/a.srt", language = "en", display = "English", addonName = "A"),
            AddonSubtitle(id = "b", url = "https://x/b.srt", language = "fr", display = "French", addonName = "A"),
        )
        val settings = PlayerSettingsUiState(
            preferredSubtitleLanguage = SubtitleLanguageOption.NONE,
            secondaryPreferredSubtitleLanguage = null,
            subtitleStyle = SubtitleStyleState(showOnlyPreferredLanguages = true),
        )
        assertEquals(subtitles, filterAddonSubtitlesForSettings(subtitles, settings))
    }

    @Test
    fun sdhTitles() {
        assertTrue(subtitleTextLooksSdh("English SDH"))
        assertTrue(subtitleTextLooksSdh("Français (SME)"))
        assertTrue(subtitleTextLooksSdh("English [CC]"))
        assertTrue(subtitleTextLooksSdh("Hearing Impaired"))
        assertFalse(subtitleTextLooksSdh("English"))
        assertFalse(subtitleTextLooksSdh("Accident"))
    }

    @Test
    fun closedCaptionsTurnSubtitlesOnInTheAudioLanguageAndPreferSdh() {
        val plan = assertNotNull(
            resolveSubtitleAutoSelectionPlanWithDefaults(
                selectedAudioTrack = audio("en"),
                preferredAudioTargets = listOf("en"),
                preferredSubtitleTargets = emptyList(),
                useForcedSubtitles = false,
                deviceLanguages = listOf("en-US", "en"),
                closedCaptionsEnabled = true,
            ),
        )
        assertEquals(listOf("en"), plan.targets)
        assertEquals(SubtitleAutoSelectionMode.NORMAL_ONLY, plan.mode)
        val tracks = listOf(sub(0, "en", "English"), sub(1, "en", "English SDH"))
        assertEquals(1, findPreferredSubtitleTrackIndexPreferringSdh(tracks, plan.targets, plan.mode, audio("en"), true))
        assertEquals(0, findPreferredSubtitleTrackIndexPreferringSdh(tracks, plan.targets, plan.mode, audio("en"), false))
    }

    @Test
    fun forcedOptionMeansForcedInTheAudioLanguage() {
        val plan = assertNotNull(
            resolveSubtitleAutoSelectionPlanWithDefaults(
                selectedAudioTrack = audio("fre"),
                preferredAudioTargets = listOf("fr"),
                preferredSubtitleTargets = listOf(SubtitleLanguageOption.FORCED),
                useForcedSubtitles = false,
                deviceLanguages = listOf("fr-FR"),
                closedCaptionsEnabled = false,
            ),
        )
        assertEquals(listOf("fr"), plan.targets)
        assertEquals(SubtitleAutoSelectionMode.FORCED_ONLY, plan.mode)
    }

    @Test
    fun forcedSubtitlesWhenAudioIsTheDeviceLanguage() {
        val plan = assertNotNull(
            resolveSubtitleAutoSelectionPlanWithDefaults(
                selectedAudioTrack = audio("fre"),
                preferredAudioTargets = listOf("ja"),
                preferredSubtitleTargets = emptyList(),
                useForcedSubtitles = true,
                deviceLanguages = listOf("fr-FR", "fr"),
                closedCaptionsEnabled = false,
            ),
        )
        assertEquals(SubtitleAutoSelectionMode.FORCED_ONLY, plan.mode)
        assertEquals(listOf("fr"), plan.targets)
    }

    @Test
    fun subtitlesOffStaysOffWithoutForcedOrCaptions() {
        val plan = assertNotNull(
            resolveSubtitleAutoSelectionPlanWithDefaults(
                selectedAudioTrack = audio("en"),
                preferredAudioTargets = listOf("en"),
                preferredSubtitleTargets = emptyList(),
                useForcedSubtitles = false,
                deviceLanguages = listOf("en-US"),
                closedCaptionsEnabled = false,
            ),
        )
        assertTrue(plan.targets.isEmpty())
    }

    @Test
    fun persistedAudioPicksTheSavedFrenchVariant() {
        val tracks = listOf(
            AudioTrack(0, "1", "VFF", "fre"),
            AudioTrack(1, "2", "VFQ", "fre"),
        )
        assertEquals(1, findPersistedAudioTrackIndex(tracks, PersistedPlayerTrackPreference(
            audioLanguage = "fr-ca", audioName = "Something else",
        )))
    }
}
