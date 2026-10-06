package com.nuvio.app.features.tmdb

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Upstream `c66e80e6` / `e6314ba2` / `754605cb`: TMDB returns native-script (CJK/Hangul) names and
 * titles whenever the requested metadata language has no translation, so cast/crew, filmography and
 * network-browse rails all fall back to the Romaji/English form for non-CJK locales.
 */
class TmdbMetadataServiceTest {

    @Test
    fun containsCjkOrHangulDetectsJapaneseChineseAndKoreanScripts() {
        assertTrue(containsCjkOrHangul("田中敦子"))
        assertTrue(containsCjkOrHangul("成龙"))
        assertTrue(containsCjkOrHangul("김수현"))
        assertFalse(containsCjkOrHangul("Atsuko Tanaka"))
        assertFalse(containsCjkOrHangul("Scarlett Johansson"))
    }

    @Test
    fun resolvePersonNameFallsBackJapaneseNamesToRomajiForNonJapaneseLocales() {
        assertEquals(
            "Atsuko Tanaka",
            resolvePersonName("田中敦子", "Atsuko Tanaka", null, "tr-TR"),
        )
        assertEquals(
            "Atsuko Tanaka",
            resolvePersonName("田中敦子", "田中敦子", "Atsuko Tanaka", "de-DE"),
        )
    }

    @Test
    fun resolvePersonNameKeepsJapaneseNamesWhenUserLanguageIsJapanese() {
        assertEquals(
            "田中敦子",
            resolvePersonName("田中敦子", "Atsuko Tanaka", "Atsuko Tanaka", "ja-JP"),
        )
    }

    @Test
    fun resolvePersonNameFallsBackHangulNamesToLatinForNonKoreanLocales() {
        assertEquals(
            "Kim Soo-hyun",
            resolvePersonName("김수현", "Kim Soo-hyun", null, "de-DE"),
        )
        assertEquals(
            "Kim Soo-hyun",
            resolvePersonName("김수현", "김수현", "Kim Soo-hyun", "fr-FR"),
        )
    }

    @Test
    fun resolvePersonNameKeepsHangulWhenUserLanguageIsKorean() {
        assertEquals(
            "김수현",
            resolvePersonName("김수현", "Kim Soo-hyun", "Kim Soo-hyun", "ko-KR"),
        )
    }

    @Test
    fun resolvePersonNameFallsBackChineseHanziToStageNameForNonChineseLocales() {
        assertEquals(
            "Jackie Chan",
            resolvePersonName("成龙", "Jackie Chan", null, "es-ES"),
        )
        assertEquals(
            "Jackie Chan",
            resolvePersonName("成龙", "成龙", "Jackie Chan", "en-US"),
        )
    }

    @Test
    fun resolvePersonNameKeepsHanziWhenUserLanguageIsChinese() {
        assertEquals(
            "成龙",
            resolvePersonName("成龙", "Jackie Chan", "Jackie Chan", "zh-CN"),
        )
    }

    @Test
    fun resolvePersonNameLeavesAlreadyLatinNamesUnchanged() {
        assertEquals(
            "Scarlett Johansson",
            resolvePersonName("Scarlett Johansson", "Scarlett Johansson", null, "tr-TR"),
        )
        assertEquals(
            "Tom Hanks",
            resolvePersonName("Tom Hanks", "Tom Hanks", null, "ja-JP"),
        )
    }

    @Test
    fun resolvePersonNameHandlesNullAndBlankInputs() {
        assertEquals("Takuya Kimura", resolvePersonName(null, "Takuya Kimura", null, "tr-TR"))
        assertEquals("Scarlett Johansson", resolvePersonName("Scarlett Johansson", null, null, "tr-TR"))
        assertNull(resolvePersonName(null, null, null, "tr-TR"))
        assertEquals(
            "Takuya Kimura",
            resolvePersonName("  木村拓哉  ", "Takuya Kimura", null, "fr-FR"),
        )
    }

    @Test
    fun resolvePersonNamePrefersEnglishFallbackWhenLocalizedNameIsAbsent() {
        // Localized name missing, CJK original, English fallback available.
        assertEquals("Takuya Kimura", resolvePersonName(null, "木村拓哉", "Takuya Kimura", "de-DE"))
        // CJK locales keep the CJK original even with a fallback present.
        assertEquals("木村拓哉", resolvePersonName(null, "木村拓哉", "Takuya Kimura", "ja-JP"))
        // No fallback: the CJK original is still better than nothing.
        assertEquals("木村拓哉", resolvePersonName(null, "木村拓哉", null, "de-DE"))
    }

    @Test
    fun resolvePersonNameFallsBackCjkFilmographyTitlesToEnglish() {
        assertEquals(
            "Ghost in the Shell: Stand Alone Complex",
            resolvePersonName(
                "攻殻機動隊 STAND ALONE COMPLEX",
                "攻殻機動隊 STAND ALONE COMPLEX",
                "Ghost in the Shell: Stand Alone Complex",
                "pl-PL",
            ),
        )
        assertEquals(
            "Make My Day",
            resolvePersonName("Make My Day", "Make My Day", null, "pl-PL"),
        )
    }

    @Test
    fun resolvePersonNameKeepsCjkFilmographyTitlesForJapaneseLocale() {
        assertEquals(
            "攻殻機動隊 STAND ALONE COMPLEX",
            resolvePersonName(
                "攻殻機動隊 STAND ALONE COMPLEX",
                "攻殻機動隊 STAND ALONE COMPLEX",
                "Ghost in the Shell: Stand Alone Complex",
                "ja-JP",
            ),
        )
    }

    @Test
    fun networkBrowseFallsBackCjkTitlesToEnglish() {
        val localizedResults = listOf(
            TmdbDiscoverResult(
                id = 57775,
                name = "ちびまる子ちゃん",
                originalName = "ちびまる子ちゃん",
                posterPath = "/maruko.jpg",
                firstAirDate = "1990-01-07",
            ),
            TmdbDiscoverResult(
                id = 37854,
                name = "One Piece",
                originalName = "ワンピース",
                posterPath = "/op.jpg",
                firstAirDate = "1999-10-20",
            ),
        )
        val englishResults = listOf(
            TmdbDiscoverResult(
                id = 57775,
                name = "Chibi Maruko-chan",
                originalName = "ちびまる子ちゃん",
                posterPath = "/maruko.jpg",
            ),
        )

        assertTrue(discoverResultsContainCjkTitles(localizedResults))
        val englishTitlesById = englishDiscoverTitlesById(englishResults)

        val titles = localizedResults.associate { result ->
            result.id to resolvePersonName(
                localizedName = result.title ?: result.name,
                originalName = result.originalTitle ?: result.originalName,
                fallbackEnglishName = englishTitlesById[result.id],
                preferredLanguage = "tr-TR",
            )
        }

        assertEquals("Chibi Maruko-chan", titles[57775])
        assertEquals("One Piece", titles[37854])
    }

    /**
     * Bug report (French tvOS tester): the Trailers & Extras row showed ONLY "Behind the Scenes"
     * clips. Root cause was `fetchTrailers`' category rank-0 test comparing the group key — TMDB's
     * wire `type` value, always English — against the *localized* `resourceString("Trailer", ...)`
     * display string, which never matches for a non-English StringProvider. `trailerCategoryRank`
     * is the extracted, pure rank function these tests exercise directly.
     */
    @Test
    fun trailerCategoryRankPutsTrailerFirstRegardlessOfLocalizedDisplayString() {
        assertEquals(0, trailerCategoryRank("Trailer", hasOfficialVideo = false))
        // Case-insensitive, as the call site's `.equals(ignoreCase = true)` already was.
        assertEquals(0, trailerCategoryRank("trailer", hasOfficialVideo = false))
        assertEquals(0, trailerCategoryRank("TRAILER", hasOfficialVideo = true))
    }

    @Test
    fun trailerCategoryRankNeverMatchesALocalizedDisplayString() {
        // Simulates what the old, buggy compare effectively did: on a French device
        // resourceString("Trailer", StringKey.generic_trailer) resolves to "Bande-annonce", which
        // must NOT be treated as the Trailer group.
        assertEquals(2, trailerCategoryRank("Bande-annonce", hasOfficialVideo = false))
        assertEquals(1, trailerCategoryRank("Bande-annonce", hasOfficialVideo = true))
    }

    @Test
    fun trailerCategoryRankRanksOfficialCategoriesAboveUnofficialNonTrailerCategories() {
        assertEquals(1, trailerCategoryRank("Behind the Scenes", hasOfficialVideo = true))
        assertEquals(2, trailerCategoryRank("Clip", hasOfficialVideo = false))
        assertEquals(2, trailerCategoryRank("Teaser", hasOfficialVideo = false))
    }

    @Test
    fun sortedCategoriesPutTrailerFirstEvenWhenBehindTheScenesIsOfficialAndAlphabeticallyEarlier() {
        // Reproduces the tester's exact category set: "Behind the Scenes" (official) would sort
        // ahead of "Trailer" both alphabetically and, before the fix, because the localized
        // rank-0 compare never matched "Trailer" for a non-English StringProvider.
        val categories = mapOf(
            "Behind the Scenes" to true,
            "Clip" to false,
            "Trailer" to true,
            "Teaser" to false,
        )
        val sorted = categories.keys.sortedWith(
            compareBy<String> { category -> trailerCategoryRank(category, categories.getValue(category)) }
                .thenBy { it.lowercase() },
        )
        assertEquals(listOf("Trailer", "Behind the Scenes", "Clip", "Teaser"), sorted)
        assertEquals("Trailer", sorted.first())
    }
}
