package com.nuvio.app.features.details

import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Settings → Detail Page on the Apple TV: the string-keyed setters, the one-shot section order and
 * the layout-only reset, all through the real repository and its (synced) payload.
 */
class MetaScreenLayoutSettingsTest {
    @BeforeTest
    fun reset() {
        MetaScreenSettingsStorage.savePayload("")
        MetaScreenSettingsRepository.clearLocalState()
    }

    @AfterTest
    fun clear() {
        MetaScreenSettingsStorage.savePayload("")
        MetaScreenSettingsRepository.clearLocalState()
    }

    private fun state() = MetaScreenSettingsRepository.uiState.value

    @Test
    fun `string keyed setters use the persisted keys and ignore unknown ones`() {
        MetaScreenSettingsRepository.setBackgroundModeByKey("dominant_color")
        MetaScreenSettingsRepository.setEpisodeCardStyleByKey("list")
        assertEquals(MetaScreenBackgroundMode.DominantColor, state().backgroundMode)
        assertEquals(MetaEpisodeCardStyle.List, state().episodeCardStyle)

        MetaScreenSettingsRepository.setBackgroundModeByKey("not-a-mode")
        MetaScreenSettingsRepository.setEpisodeCardStyleByKey("")
        assertEquals(MetaScreenBackgroundMode.DominantColor, state().backgroundMode)
        assertEquals(MetaEpisodeCardStyle.List, state().episodeCardStyle)

        MetaScreenSettingsRepository.onProfileChanged()
        assertEquals(MetaScreenBackgroundMode.DominantColor, state().backgroundMode)
        assertEquals(MetaEpisodeCardStyle.List, state().episodeCardStyle)
    }

    @Test
    fun `a fresh profile starts on the synced order that the television presents its own way`() {
        MetaScreenSettingsRepository.ensureLoaded()
        val stored = state().items
        assertEquals(MetaScreenSectionLayout.syncedDefaultOrder, stored.map { it.key })
        assertEquals(
            MetaScreenSectionLayout.televisionDefaultOrder,
            MetaScreenSectionLayout.effectiveItems(stored).map { it.key },
        )
    }

    @Test
    fun `setOrder writes the whole order once and survives a reload`() {
        MetaScreenSettingsRepository.ensureLoaded()
        val moved = MetaScreenSectionLayout.orderAfterMoving(state().items, MetaScreenSectionKey.EPISODES, up = false)
        MetaScreenSettingsRepository.setOrder(moved)

        assertEquals(moved, state().items.map { it.key })
        assertEquals(moved, MetaScreenSectionLayout.effectiveItems(state().items).map { it.key })

        MetaScreenSettingsRepository.onProfileChanged()
        assertEquals(moved, state().items.map { it.key })
    }

    @Test
    fun `setOrder keeps sections it leaves out after the listed ones`() {
        MetaScreenSettingsRepository.ensureLoaded()
        MetaScreenSettingsRepository.setOrder(listOf(MetaScreenSectionKey.MORE_LIKE_THIS, MetaScreenSectionKey.CAST))
        val keys = state().items.map { it.key }
        assertEquals(MetaScreenSectionKey.MORE_LIKE_THIS, keys[0])
        assertEquals(MetaScreenSectionKey.CAST, keys[1])
        assertEquals(MetaScreenSectionKey.entries.toSet(), keys.toSet())
        assertEquals(MetaScreenSectionKey.entries.size, keys.size)
    }

    @Test
    fun `layout reset restores sections and options but keeps the rating choices`() {
        MetaScreenSettingsRepository.ensureLoaded()
        MetaScreenSettingsRepository.setEnabled(MetaScreenSectionKey.CAST, false)
        MetaScreenSettingsRepository.setBlurUnwatchedEpisodes(true)
        MetaScreenSettingsRepository.setEpisodeCardStyleByKey("list")
        MetaScreenSettingsRepository.setOrder(listOf(MetaScreenSectionKey.DETAILS))
        MetaScreenSettingsRepository.setShowOverallRatings(false)
        MetaScreenSettingsRepository.setEpisodeRatingsVisibility(EpisodeRatingsVisibility.HIDE_EPISODES)

        MetaScreenSettingsRepository.resetLayoutToDefaults()

        val after = state()
        assertTrue(after.items.all { it.enabled })
        assertFalse(after.blurUnwatchedEpisodes)
        assertEquals(MetaEpisodeCardStyle.Horizontal, after.episodeCardStyle)
        assertEquals(MetaScreenSectionLayout.syncedDefaultOrder, after.items.map { it.key })
        assertFalse(after.showOverallRatings)
        assertEquals(EpisodeRatingsVisibility.HIDE_EPISODES, after.episodeRatingsVisibility)

        MetaScreenSettingsRepository.onProfileChanged()
        assertFalse(state().showOverallRatings)
    }
}
