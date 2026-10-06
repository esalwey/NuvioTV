package com.nuvio.app.features.details

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * BUG-101 (War Machine, French trailer with a dead YouTube id): `selectHeroTrailer` only ever
 * exposed its single top pick, so a caller whose extraction failed on that pick had nowhere to
 * fall back to — even when a perfectly playable trailer (e.g. the English one `fetchTmdbVideos`
 * always merges in) sat right behind it. `rankHeroTrailers` exposes the same selection as a full
 * ranking so both tvOS callers can retry the next candidate. These tests pin that the ranking is
 * exactly `selectHeroTrailer`'s decision, repeated: same filter, same dedup, same comparator,
 * just not collapsed to one result.
 */
class HeroTrailerSelectorTest {

    @Test
    fun firstRankedElementMatchesSelectHeroTrailerForAMixedList() {
        val trailers = listOf(
            trailer("fr-teaser", language = "fr", type = "Teaser"),
            trailer("en-official", language = "en", official = true),
            trailer("de-official", language = "de", official = true),
            trailer("untagged"),
        )
        val ranked = rankHeroTrailers(trailers, "fr-FR")
        assertEquals(selectHeroTrailer(trailers, "fr-FR")?.id, ranked.firstOrNull()?.id)

        val rankedNoPreference = rankHeroTrailers(trailers, null)
        assertEquals(selectHeroTrailer(trailers)?.id, rankedNoPreference.firstOrNull()?.id)
    }

    @Test
    fun duplicatesByKeyAreCollapsed() {
        val trailers = listOf(
            trailer("a", key = "shared-key", official = true),
            trailer("b", key = "shared-key"),
            trailer("c", key = "other-key"),
        )
        val ranked = rankHeroTrailers(trailers, null)
        assertEquals(2, ranked.size)
        assertEquals(setOf("shared-key", "other-key"), ranked.map { it.key }.toSet())
    }

    @Test
    fun emptyOrUnplayableListRanksEmpty() {
        assertTrue(rankHeroTrailers(emptyList(), "fr").isEmpty())

        val unplayable = listOf(
            trailer("no-key", key = ""),
            trailer("not-youtube", site = "Vimeo"),
        )
        assertTrue(rankHeroTrailers(unplayable, "fr").isEmpty())
    }

    @Test
    fun preferredLanguageOrderingHoldsAcrossTheWholeRankingNotJustTheHead() {
        // BUG-101's fallback shape: fr first (the preference), then en (fetchTmdbVideos always
        // merges it in), then untagged, then anything else — so a caller walking the ranked list
        // after the head fails visits candidates in exactly this order.
        val trailers = listOf(
            trailer("de", language = "de"),
            trailer("untagged"),
            trailer("en", language = "en"),
            trailer("fr", language = "fr"),
        )
        val ranked = rankHeroTrailers(trailers, "fr-FR").map { it.id }
        assertEquals(listOf("fr", "en", "untagged", "de"), ranked)
    }

    private fun trailer(
        id: String,
        key: String = id,
        language: String? = null,
        type: String = "Trailer",
        official: Boolean = false,
        site: String = "YouTube",
    ): MetaTrailer = MetaTrailer(
        id = id,
        key = key,
        name = id,
        site = site,
        type = type,
        official = official,
        language = language,
    )
}
