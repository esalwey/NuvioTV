// Fork: the matching half of upstream c9d6f5f63's PlayerSubtitleRestoreTest, placed in shared/commonTest
// (the fork's shared/ owns PlayerTrackSelection.kt; the tvOS players drive the restore from Swift).
package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlayerSubtitleRestoreTest {
    private val episodeOne = subtitle(1)
    private val episodeTwo = subtitle(2)
    private val savedEpisodeOne = PersistedPlayerTrackPreference(
        subtitleType = PersistedSubtitleSelectionType.ADDON,
        subtitleLanguage = episodeOne.language,
        subtitleName = episodeOne.display,
        addonSubtitleId = episodeOne.id,
        addonSubtitleUrl = episodeOne.url,
        addonSubtitleAddonName = episodeOne.addonName,
    )

    @Test
    fun sameEpisodeRestoresTheSavedFile() {
        val otherEnglish = episodeOne.copy(id = "other", url = "https://example.com/other.srt")
        assertEquals(episodeOne, findPersistedAddonSubtitle(listOf(otherEnglish, episodeOne), savedEpisodeOne))
    }

    @Test
    fun nextEpisodeGetsItsOwnSubtitleInTheSavedLanguage() {
        assertEquals(episodeTwo, findPersistedAddonSubtitle(listOf(episodeTwo), savedEpisodeOne))
    }

    @Test
    fun savedLanguageTakesPrecedenceOverListOrder() {
        val french = episodeTwo.copy(url = "https://example.com/episode-2-fr.srt", language = "fr", display = "French")
        assertEquals(episodeTwo, findPersistedAddonSubtitle(listOf(french, episodeTwo), savedEpisodeOne))
    }

    @Test
    fun savedProviderIsPreferredWithinTheLanguage() {
        val otherProvider = episodeTwo.copy(url = "https://other.example/episode-2.srt", addonName = "Other")
        assertEquals(episodeTwo, findPersistedAddonSubtitle(listOf(otherProvider, episodeTwo), savedEpisodeOne))
    }

    @Test
    fun savedDisplayNameIsPreferredWithinTheProvider() {
        val sdh = episodeTwo.copy(url = "https://example.com/episode-2-sdh.srt", display = "English SDH")
        val saved = savedEpisodeOne.copy(subtitleName = "English SDH")
        assertEquals(sdh, findPersistedAddonSubtitle(listOf(episodeTwo, sdh), saved))
    }

    @Test
    fun missingSavedProviderFallsBackToTheSameLanguage() {
        val replacement = episodeTwo.copy(addonName = "Other")
        assertEquals(replacement, findPersistedAddonSubtitle(listOf(replacement), savedEpisodeOne))
    }

    @Test
    fun noSubtitleInTheSavedLanguageRestoresNothing() {
        val french = episodeTwo.copy(language = "fr", display = "French")
        assertNull(findPersistedAddonSubtitle(listOf(french), savedEpisodeOne))
        assertNull(findPersistedAddonSubtitle(emptyList(), savedEpisodeOne))
    }

    @Test
    fun withoutASavedLanguageOnlyTheSavedFileMatches() {
        val saved = savedEpisodeOne.copy(subtitleLanguage = null)
        assertNull(findPersistedAddonSubtitle(listOf(episodeTwo), saved))
        assertEquals(episodeOne, findPersistedAddonSubtitle(listOf(episodeOne), saved))
    }

    @Test
    fun whileLoadingOnlyTheSavedFileOrProviderRestores() {
        val otherProvider = episodeTwo.copy(url = "https://other.example/episode-2.srt", addonName = "Other")
        assertTrue(canRestorePersistedAddonSubtitleWhileLoading(episodeOne, savedEpisodeOne))
        assertTrue(canRestorePersistedAddonSubtitleWhileLoading(episodeTwo, savedEpisodeOne))
        assertFalse(canRestorePersistedAddonSubtitleWhileLoading(otherProvider, savedEpisodeOne))
        assertTrue(canRestorePersistedAddonSubtitleWhileLoading(
            otherProvider,
            savedEpisodeOne.copy(addonSubtitleAddonName = null),
        ))
    }

    private fun subtitle(episode: Int) = AddonSubtitle(
        id = "episode-$episode",
        url = "https://example.com/episode-$episode.srt",
        language = "en",
        display = "English",
        addonName = "Test",
    )
}
