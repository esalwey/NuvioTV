package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StreamRecommenderTest {

    private fun insight(title: String, name: String? = null, size: Long? = null): StreamInsight =
        StreamInsightParser.parse(StreamInsightInput(name = name, title = title, videoSize = size))

    private val context = StreamRankingContext(
        originalLanguage = "en",
        playerAudioLanguage = "device",
        deviceLanguages = listOf("fr-FR"),
        supportsHdr = true,
        supportsDolbyVision = true,
    )

    private fun prefs(
        audio: String = StreamRankingPreferences.AUDIO_AUTO,
        fallback: List<String> = emptyList(),
        acceptSubtitled: Boolean = true,
        maxResolution: Int = 0,
        maxSizeGb: Int = 0,
        hdrMode: String = StreamRankingPreferences.HDR_AUTO,
        preferCached: Boolean = true,
        avoidLowQuality: Boolean = true,
    ) = StreamRankingPreferences(
        audioLanguage = audio,
        fallbackAudioLanguages = fallback,
        acceptSubtitledOriginal = acceptSubtitled,
        maxResolution = maxResolution,
        maxSizeGb = maxSizeGb,
        hdrMode = hdrMode,
        preferCached = preferCached,
        avoidLowQuality = avoidLowQuality,
    )

    private fun ranked(
        titles: Map<String, String>,
        preferences: StreamRankingPreferences,
        rankingContext: StreamRankingContext = context,
    ): List<String> {
        val keys = titles.keys.toList()
        val recommendations = keys.map { StreamRecommender.recommend(insight(titles.getValue(it)), preferences, rankingContext) }
        return StreamRecommender.orderedIndices(recommendations).map { keys[it] }
    }

    private val frenchOptions = linkedMapOf(
        "vf4k" to "Movie.2023.FRENCH.2160p.WEB-DL.DV.HDR10.DDP5.1.H265",
        "vfq4k" to "Movie.2023.MULTi.VFQ.2160p.WEB-DL.DV.HDR10.DDP5.1.H265",
        "vff1080" to "Movie.2023.MULTi.VFF.1080p.WEB-DL.DDP5.1.H264",
        "vostfr4k" to "Movie.2023.VOSTFR.2160p.WEB-DL.DV.HDR10.DDP5.1.H265",
        "en4k" to "Movie.2023.2160p.WEB-DL.DV.HDR10.DDP5.1.Atmos.H265",
    )

    @Test
    fun vffViewerGetsVffFirstThenUnknownFrenchThenQuebec() {
        val order = ranked(frenchOptions, prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_FRANCE))
        assertEquals("vff1080", order.first(), "a VFF viewer gets the VFF release even at 1080p")
        assertTrue(order.indexOf("vf4k") < order.indexOf("vfq4k"), "unknown-variant French beats a known VFQ")
        assertTrue(order.indexOf("vfq4k") < order.indexOf("vostfr4k"), "a VFQ dub still beats subtitles")
        assertTrue(order.indexOf("vostfr4k") < order.indexOf("en4k"), "VOSTFR is accepted before English-only")
    }

    @Test
    fun vffViewerReasons() {
        val preferences = prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_FRANCE)
        val vff = StreamRecommender.recommend(insight(frenchOptions.getValue("vff1080")), preferences, context)
        assertEquals(StreamReason(StreamReasonKind.LANGUAGE, "VFF"), vff.reasons.first())
        val vfq = StreamRecommender.recommend(insight(frenchOptions.getValue("vfq4k")), preferences, context)
        assertTrue(StreamReason(StreamReasonKind.OTHER_VARIANT, "VFQ", positive = false) in vfq.reasons)
        assertTrue(StreamReason(StreamReasonKind.QUALITY, "4K DV") in vfq.reasons)
        val vostfr = StreamRecommender.recommend(insight(frenchOptions.getValue("vostfr4k")), preferences, context)
        assertEquals(StreamReason(StreamReasonKind.SUBTITLED, "VOSTFR"), vostfr.reasons.first())
    }

    @Test
    fun quebecViewerGetsVfqFirst() {
        val order = ranked(frenchOptions, prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_QUEBEC))
        assertEquals("vfq4k", order.first())
        assertTrue(order.indexOf("vf4k") < order.indexOf("vff1080"), "VF (unknown) can still be VFQ; VFF can't")
        val vff = StreamRecommender.recommend(
            insight(frenchOptions.getValue("vff1080")),
            prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_QUEBEC),
            context,
        )
        assertTrue(StreamReason(StreamReasonKind.OTHER_VARIANT, "VFF", positive = false) in vff.reasons)
    }

    @Test
    fun quebecViewerPicksVfqFromVf2AndMulti() {
        val options = linkedMapOf(
            "vff" to "Movie.2023.MULTi.VFF.2160p.WEB-DL.H265",
            "vf2" to "Movie.2023.MULTi.VF2.1080p.WEB-DL.H264",
        )
        assertEquals("vf2", ranked(options, prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_QUEBEC)).first())
    }

    @Test
    fun anyFrenchLetsQualityDecide() {
        val order = ranked(frenchOptions, prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_ANY))
        val french = order.filter { it in setOf("vf4k", "vfq4k", "vff1080") }
        assertEquals(order.take(3).toSet(), french.toSet())
        assertTrue(order.indexOf("vfq4k") < order.indexOf("vff1080"), "4K beats 1080p when any French will do")
    }

    @Test
    fun autoFollowsPlayerFrenchAndLeansToFrance() {
        val playerFrench = context.copy(playerAudioLanguage = "fr")
        val options = linkedMapOf(
            "vfq" to "Movie.2023.MULTi.VFQ.1080p.WEB-DL.H264",
            "vff" to "Movie.2023.MULTi.VFF.1080p.WEB-DL.H264",
        )
        assertEquals("vff", ranked(options, prefs(), playerFrench).first())
        // The player's device language "fr-CA" leans the other way.
        val quebecDevice = context.copy(playerAudioLanguage = "device", deviceLanguages = listOf("fr-CA"))
        assertEquals("vfq", ranked(options, prefs(), quebecDevice).first())
    }

    @Test
    fun refusingSubtitlesDropsVostfr() {
        val preferences = prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_FRANCE, acceptSubtitled = false)
        val vostfr = StreamRecommender.recommend(insight(frenchOptions.getValue("vostfr4k")), preferences, context)
        assertTrue(StreamReason(StreamReasonKind.SUBTITLED, "VOSTFR", positive = false) in vostfr.reasons)
        val order = ranked(frenchOptions, preferences)
        assertTrue(order.indexOf("vostfr4k") > order.indexOf("vfq4k"))
    }

    @Test
    fun fallbackLanguageBeatsSubtitles() {
        val preferences = prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_FRANCE, fallback = listOf("en"))
        val order = ranked(
            linkedMapOf(
                "vostfr" to "Movie.2023.VOSTFR.1080p.WEB-DL",
                "eng" to "Movie.2023.ENGLISH.1080p.WEB-DL",
            ),
            preferences,
        )
        assertEquals(listOf("eng", "vostfr"), order)
    }

    @Test
    fun originalPreferenceWithJapaneseAnime() {
        val anime = context.copy(originalLanguage = "ja")
        val order = ranked(
            linkedMapOf(
                "vf" to "Anime.2023.S01E01.VF.1080p.WEB",
                "dual" to "Anime.2023.S01E01.1080p.WEB.Dual-Audio.JPN.ENG",
                "en" to "Anime.2023.S01E01.ENGLISH.1080p.WEB",
            ),
            prefs(audio = StreamRankingPreferences.AUDIO_ORIGINAL),
            anime,
        )
        assertEquals("dual", order.first())
    }

    @Test
    fun hardFiltersExcludeAndNeverRecommend() {
        val preferences = prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_FRANCE, maxResolution = 1080, maxSizeGb = 20)
        val cam = StreamRecommender.recommend(insight("Movie.2024.VFF.HDCAM.x264"), preferences, context)
        assertTrue(cam.isExcluded)
        assertTrue(cam.reasons.any { it.kind == StreamReasonKind.LOW_QUALITY && it.label == "CAM" })
        val uhd = StreamRecommender.recommend(insight("Movie.2024.VFF.2160p.WEB-DL"), preferences, context)
        assertTrue(uhd.isExcluded)
        assertTrue(uhd.reasons.any { it.kind == StreamReasonKind.OVER_RESOLUTION && it.label == "4K" })
        val huge = StreamRecommender.recommend(
            insight("Movie.2024.VFF.1080p.BluRay.REMUX", size = 45L * 1024 * 1024 * 1024),
            preferences,
            context,
        )
        assertTrue(huge.isExcluded)
        val english = StreamRecommender.recommend(insight("Movie.2024.ENGLISH.720p.WEB"), preferences, context)
        assertFalse(english.isExcluded)
        assertTrue(english.score > cam.score && english.score > uhd.score)

        val camAllowed = StreamRecommender.recommend(
            insight("Movie.2024.VFF.HDCAM.x264"),
            preferences.copy(avoidLowQuality = false),
            context,
        )
        assertFalse(camAllowed.isExcluded)
    }

    @Test
    fun hdrFollowsDisplayCapability() {
        val noHdr = context.copy(supportsHdr = false, supportsDolbyVision = false)
        val preferences = prefs(audio = "en")
        val order = ranked(
            linkedMapOf(
                "hdr" to "Movie.2023.ENGLISH.1080p.WEB-DL.HDR10.H265",
                "sdr" to "Movie.2023.ENGLISH.1080p.WEB-DL.H265",
            ),
            preferences,
            noHdr,
        )
        assertEquals("sdr", order.first())
        val hdr = StreamRecommender.recommend(insight("Movie.2023.ENGLISH.1080p.WEB-DL.HDR10.H265"), preferences, noHdr)
        assertTrue(hdr.reasons.any { it.kind == StreamReasonKind.HDR_UNSUPPORTED && !it.positive })

        val withHdr = ranked(
            linkedMapOf(
                "sdr" to "Movie.2023.ENGLISH.1080p.WEB-DL.H265",
                "hdr" to "Movie.2023.ENGLISH.1080p.WEB-DL.HDR10.H265",
            ),
            preferences,
        )
        assertEquals("hdr", withHdr.first())
    }

    @Test
    fun dolbyVisionWithoutFallbackIsPenalisedWithoutNativeDv() {
        val noDv = context.copy(supportsDolbyVision = false)
        val preferences = prefs(audio = "en")
        val profile5 = StreamRecommender.recommend(insight("Movie.2023.ENGLISH.2160p.WEB-DL.DV.P5.H265"), preferences, noDv)
        assertTrue(profile5.reasons.any { it.kind == StreamReasonKind.HDR_UNSUPPORTED && it.label == "DV" })
        val profile8 = StreamRecommender.recommend(insight("Movie.2023.ENGLISH.2160p.WEB-DL.DV.HDR10.H265"), preferences, noDv)
        assertTrue(profile8.score > profile5.score)
    }

    @Test
    fun avoidHdrPreference() {
        val order = ranked(
            linkedMapOf(
                "hdr" to "Movie.2023.ENGLISH.2160p.WEB-DL.HDR10.H265",
                "sdr" to "Movie.2023.ENGLISH.2160p.WEB-DL.H265",
            ),
            prefs(audio = "en", hdrMode = StreamRankingPreferences.HDR_AVOID),
        )
        assertEquals("sdr", order.first())
    }

    @Test
    fun cachedBeatsUncachedAtEqualQuality() {
        val preferences = prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_FRANCE)
        val cached = StreamRecommender.recommend(insight("Movie.2023.VFF.1080p.WEB", name = "[RD+] Torrentio"), preferences, context)
        val uncached = StreamRecommender.recommend(insight("Movie.2023.VFF.1080p.WEB", name = "[RD download] Torrentio"), preferences, context)
        assertTrue(cached.score > uncached.score)
        assertTrue(cached.reasons.any { it.kind == StreamReasonKind.CACHED && it.label == "RD" })
        assertTrue(uncached.reasons.any { it.kind == StreamReasonKind.NOT_CACHED && !it.positive })
    }

    @Test
    fun englishViewerKeepsUntaggedEnglishReleases() {
        val englishViewer = context.copy(playerAudioLanguage = "en", deviceLanguages = listOf("en-US"))
        val order = ranked(
            linkedMapOf(
                "vff" to "Movie.2023.MULTi.VFF.2160p.WEB-DL",
                "untagged" to "Movie.2023.2160p.WEB-DL.DDP5.1",
                "ita" to "Movie.2023.iTALiAN.2160p.WEB-DL",
            ),
            prefs(),
            englishViewer,
        )
        assertEquals("untagged", order.first(), "an untagged release of an English film is English")
    }

    @Test
    fun rankMarksSingleTopPickAndKeepsTiesStable() {
        val streams = listOf(
            StreamItem(name = "Torrentio\n1080p", title = "Movie.2023.VFQ.1080p.WEB", addonName = "Torrentio", addonId = "a"),
            StreamItem(name = "Torrentio\n1080p", title = "Movie.2023.VFF.1080p.WEB", addonName = "Torrentio", addonId = "a"),
            StreamItem(name = "Torrentio\n1080p", title = "Movie.2023.VFF.1080p.WEB", addonName = "Torrentio", addonId = "a"),
            StreamItem(name = "Torrentio\nCAM", title = "Movie.2023.VFF.CAM", addonName = "Torrentio", addonId = "a"),
        )
        val ranked = StreamRecommender.rank(streams, prefs(audio = StreamRankingPreferences.AUDIO_FRENCH_FRANCE), context)
        assertEquals(listOf(1, 2, 0, 3), ranked.map { it.originalIndex })
        assertEquals(1, ranked.count { it.isTopPick })
        assertTrue(ranked.first().isTopPick)
        assertTrue(ranked.last().recommendation.isExcluded)

        val off = StreamRecommender.rank(streams, prefs().copy(enabled = false), context)
        assertEquals(listOf(0, 1, 2, 3), off.map { it.originalIndex })
        assertTrue(off.none { it.isTopPick })
    }

    @Test
    fun noRecommendationWhenEverythingIsFiltered() {
        val streams = listOf(
            StreamItem(title = "Movie.2024.HDCAM", addonName = "A", addonId = "a"),
            StreamItem(title = "Movie.2024.TELESYNC", addonName = "A", addonId = "a"),
        )
        val ranked = StreamRecommender.rank(streams, prefs(), context)
        assertTrue(ranked.none { it.isTopPick })
    }

    @Test
    fun wishesResolution() {
        assertEquals(
            listOf<StreamRecommender.AudioWish>(StreamRecommender.AudioWish.Language("fr", StreamLanguageVariant.FRANCE)),
            StreamRecommender.resolveAudioWishes(prefs(audio = "fr-FR"), context),
        )
        assertEquals(
            listOf(
                StreamRecommender.AudioWish.Language("fr", lean = StreamLanguageVariant.FRANCE),
                StreamRecommender.AudioWish.Original,
            ),
            StreamRecommender.resolveAudioWishes(prefs(), context.copy(playerAudioLanguage = "fr", playerSecondaryAudioLanguage = "original")),
        )
        assertEquals(
            emptyList(),
            StreamRecommender.resolveAudioWishes(prefs(), context.copy(playerAudioLanguage = "default")),
        )
        assertEquals("fr", StreamRecommender.resolveSubtitleLanguage(prefs(audio = "fr-ca"), context.copy(playerSubtitleLanguage = "none")))
        assertEquals("en", StreamRecommender.resolveSubtitleLanguage(prefs(audio = "fr-ca"), context.copy(playerSubtitleLanguage = "en")))
        assertEquals(null, StreamRecommender.resolveSubtitleLanguage(prefs().copy(subtitleLanguage = "none"), context))
    }

    // region Playback audio hints

    @Test
    fun playbackHintsPutTheChosenVersionFirst() {
        val multi = insight("Movie.2023.MULTi.VF2.1080p.WEB")
        assertEquals(
            listOf("fr-ca", "fr", "en"),
            StreamPlaybackLanguageHints.audioTargets(multi, prefs(audio = "fr-ca"), listOf("fr", "en"), "en"),
        )
        assertEquals(
            listOf("fr", "en"),
            StreamPlaybackLanguageHints.audioTargets(multi, prefs(audio = "fr-fr"), listOf("en"), "en"),
        )
        // "Follow the player": untouched.
        assertEquals(
            listOf("fr", "en"),
            StreamPlaybackLanguageHints.audioTargets(multi, prefs(), listOf("fr", "en"), "en"),
        )
    }

    @Test
    fun playbackHintsStartSubtitledReleasesOnTheOriginal() {
        val vostfr = insight("Movie.2023.VOSTFR.1080p.WEB")
        assertEquals(
            listOf("en", "fr"),
            StreamPlaybackLanguageHints.audioTargets(vostfr, prefs(audio = "fr-fr"), listOf("fr"), "en"),
        )
    }

    // endregion

    // region Preferences

    @Test
    fun preferencesRoundTripAndLenientDecode() {
        val preferences = StreamRankingPreferences(
            audioLanguage = "fr-ca",
            fallbackAudioLanguages = listOf("en"),
            acceptSubtitledOriginal = false,
            maxResolution = 1080,
            hdrMode = StreamRankingPreferences.HDR_PREFER,
            maxSizeGb = 20,
        )
        val encoded = StreamRankingSettingsRepository.encode(preferences)
        assertEquals(preferences, StreamRankingSettingsRepository.decode(encoded))
        assertEquals(StreamRankingPreferences(), StreamRankingSettingsRepository.decode(null))
        assertEquals(StreamRankingPreferences(), StreamRankingSettingsRepository.decode("{not json"))
        assertEquals(
            "fr-ca",
            StreamRankingSettingsRepository.decode("""{"audioLanguage":"FR_CA","unknownField":1}""").audioLanguage,
        )
    }

    // endregion
}
