package com.nuvio.app.features.details

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * BUG-63/BUG-67: the Metadata Language is a *preference* at selection time, never a filter.
 * These pin the tier order (preferred > en > untagged > other) and — since BUG-67 — that a set
 * preference sits ABOVE the official/type tiers: BUG-63's below-type placement let the widened
 * fetch's English official trailers beat French ones ("72 Hours" / "Drop Game", beta.13 review).
 */
class HeroTrailerLanguageSelectionTest {

    @Test
    fun prefersTheMetadataLanguageAmongEqualCandidates() {
        val trailers = listOf(
            trailer("en", language = "en"),
            trailer("fr", language = "fr"),
            trailer("untagged", language = null),
            trailer("de", language = "de"),
        )
        assertEquals("fr", selectHeroTrailer(trailers, "fr-FR")?.id)
        assertEquals("fr", selectHeroTrailer(trailers, "fr")?.id)
        assertEquals("de", selectHeroTrailer(trailers, "de-DE")?.id)
    }

    @Test
    fun fallsBackToEnglishThenUntaggedWhenPreferredIsAbsent() {
        val withEnglish = listOf(trailer("de", language = "de"), trailer("en", language = "en"), trailer("untagged"))
        assertEquals("en", selectHeroTrailer(withEnglish, "fr-FR")?.id)

        val withoutEnglish = listOf(trailer("de", language = "de"), trailer("untagged"))
        assertEquals("untagged", selectHeroTrailer(withoutEnglish, "fr-FR")?.id)

        val otherOnly = listOf(trailer("de", language = "de"))
        assertEquals("de", selectHeroTrailer(otherOnly, "fr-FR")?.id)
    }

    @Test
    fun languageOutranksOfficialAndTypeTiers() {
        // BUG-67 (the "72 Hours" / "Drop Game" regression): a French Teaser must beat an English
        // official Trailer when the Metadata Language is French — pre-BUG-63, the French-only
        // fetch made exactly this pick.
        val trailers = listOf(
            trailer("fr-teaser", language = "fr", type = "Teaser"),
            trailer("en-official", language = "en", official = true),
        )
        assertEquals("fr-teaser", selectHeroTrailer(trailers, "fr-FR")?.id)
    }

    @Test
    fun typeTiersStillDecideWithinTheSameLanguage() {
        val trailers = listOf(
            trailer("fr-teaser", language = "fr", type = "Teaser"),
            trailer("fr-official", language = "fr", official = true),
            trailer("en-official", language = "en", official = true),
        )
        assertEquals("fr-official", selectHeroTrailer(trailers, "fr-FR")?.id)
    }

    @Test
    fun oneArgumentOverloadIsLanguageNeutral() {
        // Equal tiers, no preference → the legacy publishedAt/size/name ordering decides, and the
        // language tag must not participate (here `name` = id, so "zz-fr" wins over "aa-en").
        val trailers = listOf(trailer("aa-en", language = "en"), trailer("zz-fr", language = "fr"))
        assertEquals("zz-fr", selectHeroTrailer(trailers)?.id)
        // …whereas the same list WITH a preference for English flips it.
        assertEquals("aa-en", selectHeroTrailer(trailers, "en-US")?.id)
        assertNull(selectHeroTrailer(emptyList(), "fr"))
    }

    private fun trailer(
        id: String,
        language: String? = null,
        type: String = "Trailer",
        official: Boolean = false,
    ): MetaTrailer = MetaTrailer(
        id = id,
        key = id,
        name = id,
        site = "YouTube",
        type = type,
        official = official,
        language = language,
    )
}
