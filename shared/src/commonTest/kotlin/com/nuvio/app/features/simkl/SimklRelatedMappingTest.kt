package com.nuvio.app.features.simkl

import com.nuvio.app.features.player.skip.preferSimklType
import com.nuvio.app.features.player.skip.simklTypesForHint
import com.nuvio.app.features.trakt.MoreLikeThisSourcePreference
import com.nuvio.app.features.trakt.shouldUseSimklMoreLikeThis
import com.nuvio.app.features.trakt.shouldUseTraktMoreLikeThis
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SimklRelatedMappingTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `redirect params accept imdb ids and known prefixes only`() {
        assertEquals("imdb" to "tt0133093", parseSimklRedirectParam("tt0133093:1:2"))
        assertEquals("tmdb" to "603", parseSimklRedirectParam("tmdb:603"))
        assertEquals("mal" to "5114", parseSimklRedirectParam("MAL:5114"))
        assertNull(parseSimklRedirectParam("custom:abc"))
        assertNull(parseSimklRedirectParam("   "))
        assertNull(parseSimklRedirectParam(null))
    }

    @Test
    fun `content type is movie only for movies and anime movies`() {
        assertEquals("movie", resolveSimklRelatedContentType("movie", null))
        assertEquals("movie", resolveSimklRelatedContentType("anime", "movie"))
        assertEquals("series", resolveSimklRelatedContentType("anime", "tv"))
        assertEquals("series", resolveSimklRelatedContentType("show", null))
        assertEquals("series", resolveSimklRelatedContentType(null, null))
    }

    @Test
    fun `non anime items prefer imdb then tmdb then tvdb`() {
        val ids = SimklRelatedIdsDto(imdb = "tt1", tmdb = "2", tvdb = "3", simkl = 4)
        assertEquals("tt1", resolveSimklRelatedContentId(ids, "movie", SimklAnimeIdPreference.MAL))
        assertEquals("tmdb:2", resolveSimklRelatedContentId(ids.copy(imdb = null), "show", SimklAnimeIdPreference.IMDB))
        assertEquals("tvdb:3", resolveSimklRelatedContentId(ids.copy(imdb = null, tmdb = null), "show", SimklAnimeIdPreference.IMDB))
        assertEquals("simkl:4", resolveSimklRelatedContentId(SimklRelatedIdsDto(simkl = 4), "show", SimklAnimeIdPreference.IMDB))
        assertNull(resolveSimklRelatedContentId(SimklRelatedIdsDto(), "show", SimklAnimeIdPreference.IMDB))
        assertNull(resolveSimklRelatedContentId(null, "show", SimklAnimeIdPreference.IMDB))
    }

    @Test
    fun `anime items follow the anime id preference`() {
        val ids = SimklRelatedIdsDto(imdb = "tt9", mal = "100", kitsu = "200", anidb = "300", tvdb = "400")
        assertEquals("mal:100", resolveSimklRelatedContentId(ids, "anime", SimklAnimeIdPreference.MAL))
        assertEquals("kitsu:200", resolveSimklRelatedContentId(ids, "anime", SimklAnimeIdPreference.KITSU))
        assertEquals("tvdb:400", resolveSimklRelatedContentId(ids, "anime", SimklAnimeIdPreference.TVDB))
        assertEquals("tt9", resolveSimklRelatedContentId(ids, "anime", SimklAnimeIdPreference.IMDB))
        // The preference never applies to a regular show.
        assertEquals("tt9", resolveSimklRelatedContentId(ids, "show", SimklAnimeIdPreference.MAL))
    }

    @Test
    fun `detail maps recommendations first and drops duplicates and unusable rows`() {
        val detail = json.decodeFromString<SimklRelatedDetailDto>(
            """
            {
              "users_recommendations": [
                {"title":"Alpha","year":2020,"poster":"aa/bb","fanart":"cc/dd","type":"movie","ids":{"simkl":1,"imdb":"tt1"}},
                {"title":"No Year","type":"movie","ids":{"simkl":2,"imdb":"tt2"}}
              ],
              "similar": [
                {"title":"Alpha again","year":2020,"type":"movie","ids":{"simkl":1,"imdb":"tt1"}},
                {"title":"Beta","en_title":"Beta EN","year":2019,"type":"show","ids":{"simkl":3,"tmdb":"30"}},
                {"year":2018,"type":"show","ids":{"simkl":4,"imdb":"tt4"}}
              ]
            }
            """.trimIndent(),
        )
        val items = mapRelatedItems(detail, SimklAnimeIdPreference.IMDB)
        assertEquals(listOf("tt1", "tmdb:30"), items.map { it.id })
        assertEquals(listOf("movie", "series"), items.map { it.type })
        assertEquals("Beta EN", items[1].name)
        assertEquals("2019", items[1].releaseInfo)
        assertTrue(items[0].poster!!.contains("simkl.in/posters/aa/bb"))
        assertTrue(items[0].banner!!.contains("simkl.in/fanart/cc/dd"))
    }

    @Test
    fun `banner falls back to the wide poster crop`() {
        val item = SimklRelatedItemDto(title = "X", year = 2001, poster = "p/q", type = "movie", ids = SimklRelatedIdsDto(imdb = "tt5"))
        val preview = simklRelatedItemToMetaPreview(item, SimklAnimeIdPreference.IMDB)!!
        assertTrue(preview.banner!!.contains("simkl.in/posters/p/q_w.webp"))
    }

    @Test
    fun `source preference decides which provider serves more like this`() {
        assertTrue(shouldUseSimklMoreLikeThis(true, MoreLikeThisSourcePreference.SIMKL))
        assertFalse(shouldUseSimklMoreLikeThis(false, MoreLikeThisSourcePreference.SIMKL))
        assertFalse(shouldUseSimklMoreLikeThis(true, MoreLikeThisSourcePreference.TRAKT))
        assertFalse(shouldUseTraktMoreLikeThis(true, MoreLikeThisSourcePreference.SIMKL))
    }

    @Test
    fun `an unknown stored source falls back to the default`() {
        assertEquals(MoreLikeThisSourcePreference.SIMKL, MoreLikeThisSourcePreference.fromStorage("SIMKL"))
        assertEquals(MoreLikeThisSourcePreference.TRAKT, MoreLikeThisSourcePreference.fromStorage("nonsense"))
    }

    @Test
    fun `type hint puts the matching search entry first`() {
        assertEquals(setOf("movie"), simklTypesForHint("Movie"))
        assertEquals(setOf("show", "tv"), simklTypesForHint("series"))
        assertTrue(simklTypesForHint(null).isEmpty())

        val results = json.parseToJsonElement(
            """[{"type":"show","ids":{"simkl":1}},{"type":"movie","ids":{"simkl":2}},{"type":"movie","ids":{"simkl":3}}]""",
        ).jsonArray.map { it as JsonObject }
        val ids = { list: List<JsonObject> ->
            list.map { it["ids"]!!.jsonObject["simkl"]!!.jsonPrimitive.content }
        }
        assertEquals(listOf("2", "3", "1"), ids(results.preferSimklType("movie")))
        assertEquals(listOf("1", "2", "3"), ids(results.preferSimklType(null)))
        assertEquals(listOf("1", "2", "3"), ids(results.preferSimklType("anime")))
    }
}
