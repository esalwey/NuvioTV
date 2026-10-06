// Upstream 8aad52d83 (TVDB preference) + 8ac70e598 (a preference only applies to anime entries).
package com.nuvio.app.features.simkl

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals

class SimklAnimeIdPreferenceTest {
    private val anime = SimklMedia(
        title = "Attack on Titan",
        ids = buildJsonObject {
            put("simkl", 39687)
            put("imdb", "tt2560140")
            put("tvdb", "267440")
            put("mal", "16498")
            put("kitsu", "7442")
        },
    )

    private val show = SimklMedia(
        title = "The Walking Dead",
        ids = buildJsonObject {
            put("simkl", 2090)
            put("imdb", "tt1520211")
            put("tvdb", "153021")
        },
    )

    @Test
    fun `each preference picks its id for an anime entry`() {
        assertEquals("tt2560140", anime.canonicalContentId(SimklAnimeIdPreference.IMDB))
        assertEquals("mal:16498", anime.canonicalContentId(SimklAnimeIdPreference.MAL))
        assertEquals("kitsu:7442", anime.canonicalContentId(SimklAnimeIdPreference.KITSU))
        assertEquals("tvdb:267440", anime.canonicalContentId(SimklAnimeIdPreference.TVDB))
    }

    @Test
    fun `a preference leaves entries without anime ids on the standard chain`() {
        SimklAnimeIdPreference.entries.forEach { preference ->
            assertEquals("tt1520211", show.canonicalContentId(preference), preference.name)
        }
    }

    @Test
    fun `the standard chain prefers kitsu over mal`() {
        val animeWithoutGlobalIds = SimklMedia(
            ids = buildJsonObject {
                put("mal", "16498")
                put("kitsu", "7442")
            },
        )

        assertEquals("kitsu:7442", animeWithoutGlobalIds.canonicalContentId(SimklAnimeIdPreference.IMDB))
    }

    @Test
    fun `the TVDB preference falls back when the anime entry has no TVDB id`() {
        val animeWithoutTvdb = SimklMedia(
            ids = buildJsonObject {
                put("imdb", "tt2560140")
                put("mal", "16498")
            },
        )

        assertEquals("tt2560140", animeWithoutTvdb.canonicalContentId(SimklAnimeIdPreference.TVDB))
    }

    @Test
    fun `stored TVDB preference round trips`() {
        assertEquals(SimklAnimeIdPreference.TVDB, SimklAnimeIdPreference.fromStorage("TVDB"))
        assertEquals(DEFAULT_SIMKL_ANIME_ID_PREFERENCE, SimklAnimeIdPreference.fromStorage("unknown"))
    }
}
