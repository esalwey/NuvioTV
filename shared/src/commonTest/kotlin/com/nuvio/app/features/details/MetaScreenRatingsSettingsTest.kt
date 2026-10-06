package com.nuvio.app.features.details

import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Upstream 6fb46976b (SET-2): rating visibility lives in the synced meta-screen payload. The
 * fields must round-trip, and a payload written before they existed must keep ratings visible.
 */
class MetaScreenRatingsSettingsTest {
    @BeforeTest
    fun reset() {
        MetaScreenSettingsStorage.savePayload("")
        MetaScreenSettingsRepository.clearLocalState()
    }

    @AfterTest
    fun clear() {
        MetaScreenSettingsRepository.clearLocalState()
    }

    @Test
    fun `ratings choices persist and reload`() {
        MetaScreenSettingsRepository.setShowOverallRatings(false)
        MetaScreenSettingsRepository.setEpisodeRatingsVisibility(EpisodeRatingsVisibility.HIDE_UNWATCHED_EPISODES)

        val payload = MetaScreenSettingsStorage.loadPayload().orEmpty()
        assertTrue(payload.contains("\"show_overall_ratings\":false"), payload)
        assertTrue(payload.contains("\"episode_ratings_visibility\":\"HIDE_UNWATCHED_EPISODES\""), payload)

        MetaScreenSettingsRepository.onProfileChanged()
        val state = MetaScreenSettingsRepository.uiState.value
        assertFalse(state.showOverallRatings)
        assertEquals(EpisodeRatingsVisibility.HIDE_UNWATCHED_EPISODES, state.episodeRatingsVisibility)
    }

    @Test
    fun `payload without ratings keys keeps every rating visible`() {
        MetaScreenSettingsStorage.savePayload("""{"items":[],"blur_unwatched_episodes":true}""")

        MetaScreenSettingsRepository.onProfileChanged()
        val state = MetaScreenSettingsRepository.uiState.value

        assertTrue(state.blurUnwatchedEpisodes)
        assertTrue(state.showOverallRatings)
        assertEquals(EpisodeRatingsVisibility.SHOW_ALL, state.episodeRatingsVisibility)
    }

    @Test
    fun `unknown episode visibility falls back to show all`() {
        assertEquals(EpisodeRatingsVisibility.SHOW_ALL, EpisodeRatingsVisibility.parse("SOMETHING_NEW"))
        assertEquals(EpisodeRatingsVisibility.SHOW_ALL, EpisodeRatingsVisibility.parse(null))
    }

    @Test
    fun `episode visibility gates each rating on the watched state`() {
        assertTrue(EpisodeRatingsVisibility.SHOW_ALL.showRating(isWatched = false))
        assertFalse(EpisodeRatingsVisibility.HIDE_EPISODES.showRating(isWatched = true))
        assertFalse(EpisodeRatingsVisibility.HIDE_UNWATCHED_EPISODES.showRating(isWatched = false))
        assertTrue(EpisodeRatingsVisibility.HIDE_UNWATCHED_EPISODES.showRating(isWatched = true))
    }
}
