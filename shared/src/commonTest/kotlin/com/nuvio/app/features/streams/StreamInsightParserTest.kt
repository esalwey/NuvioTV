package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StreamInsightParserTest {

    private fun parse(
        name: String? = null,
        title: String? = null,
        description: String? = null,
        filename: String? = null,
        videoSize: Long? = null,
        bingeGroup: String? = null,
        url: String? = null,
        parsed: StreamClientResolveParsed? = null,
        subtitleLanguages: List<String> = emptyList(),
        debridCacheState: StreamDebridCacheState? = null,
    ): StreamInsight = StreamInsightParser.parse(
        StreamInsightInput(
            name = name,
            title = title,
            description = description,
            filename = filename,
            videoSize = videoSize,
            bingeGroup = bingeGroup,
            url = url,
            parsed = parsed,
            subtitleLanguages = subtitleLanguages,
            debridCacheState = debridCacheState,
        ),
    )

    private fun StreamInsight.audioTags(): Set<String> = audioLanguages.map { it.tag }.toSet()
    private fun StreamInsight.subtitleCodes(): Set<String> = subtitleLanguages.map { it.code }.toSet()
    private fun StreamInsight.audioCodes(): Set<String> = audioLanguages.map { it.code }.toSet()
    private fun gb(value: Double): Long = (value * (1024.0 * 1024 * 1024)).toLong()

    // region Full add-on formats

    @Test
    fun torrentioFrenchMultiVffWithFlags() {
        val insight = parse(
            name = "[RD+] Torrentio\n4k DV | HDR",
            title = "Dune.Part.Two.2024.MULTi.VFF.2160p.WEB-DL.DV.HDR10.DDP5.1.Atmos.H265-FW\n" +
                "👤 152 💾 18.4 GB ⚙️ YggTorrent\nMulti Audio / 🇫🇷 / 🇬🇧",
        )
        assertEquals(StreamResolution.P2160, insight.resolution)
        assertEquals(StreamSourceKind.WEB_DL, insight.source)
        assertEquals(StreamVideoCodec.HEVC, insight.videoCodec)
        assertEquals(listOf(StreamHdrFormat.DOLBY_VISION, StreamHdrFormat.HDR10), insight.hdrFormats)
        assertTrue(StreamAudioCodec.EAC3 in insight.audioCodecs)
        assertTrue(insight.hasAtmos)
        assertEquals("5.1", insight.audioChannels)
        assertEquals(setOf("VFF", "EN"), insight.audioTags())
        assertTrue(insight.isMultiAudio)
        assertTrue(insight.includesOriginalAudio)
        assertEquals(gb(18.4), insight.sizeBytes)
        assertEquals(152, insight.seeders)
        assertEquals("YggTorrent", insight.provider)
        assertEquals(StreamCacheState.CACHED, insight.cacheState)
        assertEquals("RD", insight.debridService)
        assertEquals("FW", insight.releaseGroup)
        assertEquals("4K · Dolby Vision · Atmos", insight.qualitySummary)
        val vff = insight.audioLanguages.first { it.tag == "VFF" }
        assertEquals(StreamConfidence.HIGH, vff.confidence)
        assertEquals("fr-FR", vff.code)
    }

    @Test
    fun torrentioUncachedEnglishRelease() {
        val insight = parse(
            name = "[RD download] Torrentio\n1080p",
            title = "Oppenheimer.2023.1080p.BluRay.DDP5.1.x264-ZQ\n👤 2034 💾 14.2 GB ⚙️ ThePirateBay",
        )
        assertEquals(StreamCacheState.NOT_CACHED, insight.cacheState)
        assertEquals(StreamResolution.P1080, insight.resolution)
        assertEquals(StreamSourceKind.BLURAY, insight.source)
        assertEquals(StreamVideoCodec.AVC, insight.videoCodec)
        assertEquals("ThePirateBay", insight.provider)
        assertEquals(2034, insight.seeders)
        assertTrue(insight.audioLanguages.isEmpty())
        assertEquals("ZQ", insight.releaseGroup)
    }

    @Test
    fun cometFormatWithEmojiLines() {
        val insight = parse(
            name = "[TB⚡] Comet 4K",
            description = "📄 Gladiator.II.2024.MULTi.VFQ.2160p.WEB.HDR.DDP5.1.H265-TFA\n" +
                "📹 HEVC • HDR\n🔊 Atmos • 5.1\n💾 15.2 GB 🔎 Torrent9\n🌎 🇫🇷/🇬🇧",
        )
        assertEquals(StreamCacheState.CACHED, insight.cacheState)
        assertEquals("TB", insight.debridService)
        // VFQ is explicit: the 🇫🇷 flag must not add a generic "VF" next to it.
        assertEquals(setOf("VFQ", "EN"), insight.audioTags())
        assertEquals("Torrent9", insight.provider)
        assertTrue(insight.hasAtmos)
        assertEquals(gb(15.2), insight.sizeBytes)
    }

    @Test
    fun mediaFusionFormat() {
        val insight = parse(
            name = "MediaFusion | RD ⚡️ 4K HDR",
            description = "📂 The Batman 2022 2160p UHD BluRay REMUX\n💾 62.5 GB 👤 50\n🔗 TorrentGalaxy\n🌐 English + French",
        )
        assertEquals(StreamCacheState.CACHED, insight.cacheState)
        assertEquals(StreamSourceKind.REMUX, insight.source)
        assertEquals(StreamResolution.P2160, insight.resolution)
        assertEquals("TorrentGalaxy", insight.provider)
        assertEquals(50, insight.seeders)
        assertEquals(setOf("EN", "VF"), insight.audioTags())
        // Plain "French": the variant stays unknown — never assumed to be VFF.
        assertEquals(StreamLanguageVariant.UNSPECIFIED, insight.audioLanguages.first { it.language == "fr" }.variant)
    }

    @Test
    fun mediaFusionUncachedHourglass() {
        val insight = parse(name = "MediaFusion | RD ⏳ 1080p", description = "📂 Movie 2021 1080p WEB-DL")
        assertEquals(StreamCacheState.NOT_CACHED, insight.cacheState)
    }

    @Test
    fun jackettStyleTextMetadata() {
        val insight = parse(
            name = "Jackett 1080p",
            description = "Le.Prenom.2012.FRENCH.1080p.BluRay.x264-LOST\nSeeders: 34 | Peers: 3 | Indexer: Cpasbien",
        )
        assertEquals(34, insight.seeders)
        assertEquals(3, insight.peers)
        assertEquals("Cpasbien", insight.provider)
        assertEquals(setOf("VF"), insight.audioTags())
    }

    @Test
    fun debridCacheCheckOverridesText() {
        val insight = parse(
            name = "Torrentio\n1080p",
            title = "Movie.2020.1080p.WEB-DL",
            debridCacheState = StreamDebridCacheState.CACHED,
        )
        assertEquals(StreamCacheState.CACHED, insight.cacheState)
        val uncached = parse(name = "[AD+] Torrentio", title = "Movie.2020.1080p", debridCacheState = StreamDebridCacheState.NOT_CACHED)
        assertEquals(StreamCacheState.NOT_CACHED, uncached.cacheState)
    }

    // endregion

    // region French variants (critical)

    @Test
    fun vfqIsQuebecNotFrance() {
        val insight = parse(title = "Oppenheimer.2023.MULTi.VFQ.1080p.BluRay.x264-QC")
        assertEquals(setOf("VFQ"), insight.audioTags())
        assertEquals("fr-CA", insight.audioLanguages.single().code)
        assertEquals(StreamConfidence.HIGH, insight.audioLanguages.single().confidence)
    }

    @Test
    fun vf2IsBothFranceAndQuebec() {
        val insight = parse(title = "Barbie.2023.MULTi.VF2.2160p.WEB-DL.DV.HDR.H265-SUPPLY")
        assertEquals(setOf("VFF", "VFQ"), insight.audioTags())
        assertTrue(insight.isMultiAudio)
    }

    @Test
    fun plainFrenchKeepsVariantUnknown() {
        val insight = parse(title = "Le.Comte.de.Monte-Cristo.2024.FRENCH.1080p.WEB.H264-SUPPLY")
        assertEquals(setOf("VF"), insight.audioTags())
        assertEquals(StreamLanguageVariant.UNSPECIFIED, insight.audioLanguages.single().variant)
        assertEquals("fr", insight.audioLanguages.single().code)
    }

    @Test
    fun plainVfAndFrKeepVariantUnknown() {
        assertEquals(setOf("VF"), parse(title = "Avatar.2009.VF.1080p.BluRay").audioTags())
        assertEquals(setOf("VF"), parse(title = "Avatar 2009 FR 1080p BluRay").audioTags())
    }

    @Test
    fun trueFrenchIsVff() {
        assertEquals(setOf("VFF"), parse(title = "Anatomie.d.une.Chute.2023.TRUEFRENCH.720p.HDTV.x264").audioTags())
        assertEquals(setOf("VFF"), parse(title = "Les Misérables 2019 True French 1080p").audioTags())
    }

    @Test
    fun vfiIsInternational() {
        val insight = parse(title = "Coco.2017.MULTi.VFI.1080p.BluRay.x264")
        assertEquals(setOf("VFI"), insight.audioTags())
        assertEquals(StreamLanguageVariant.INTERNATIONAL, insight.audioLanguages.single().variant)
    }

    @Test
    fun vffAndVfqSeparateTags() {
        assertEquals(setOf("VFF", "VFQ"), parse(title = "Inside.Out.2.2024.MULTi.VFF.VFQ.2160p.WEB").audioTags())
    }

    @Test
    fun genericFrenchExplainedBySpecificTag() {
        assertEquals(setOf("VFQ"), parse(title = "Movie.2022.FRENCH.VFQ.1080p.WEB").audioTags())
    }

    @Test
    fun multiAloneMeansOriginalPlusFrenchLowConfidence() {
        val insight = parse(title = "Inception.2010.MULTi.1080p.BluRay.x264-LOST")
        assertTrue(insight.isMultiAudio)
        assertTrue(insight.includesOriginalAudio)
        val french = insight.audioLanguages.single()
        assertEquals("VF", french.tag)
        assertEquals(StreamConfidence.LOW, french.confidence)
    }

    @Test
    fun multiWithOtherLanguagesDoesNotInventFrench() {
        val insight = parse(title = "Movie.2020.MULTi.ITA.ENG.1080p.WEB-DL")
        assertEquals(setOf("IT", "EN"), insight.audioTags())
    }

    @Test
    fun vostfrIsOriginalAudioWithFrenchSubtitles() {
        val insight = parse(
            title = "Shogun.2024.S01E05.VOSTFR.1080p.WEB.H264-NoTag\n👤 30 💾 1.8 GB ⚙️ Nyaa\n🇫🇷",
        )
        assertTrue(insight.audioLanguages.none { it.language == "fr" }, "VOSTFR is not a French dub")
        assertEquals(setOf("fr"), insight.subtitleCodes())
        assertTrue(insight.includesOriginalAudio)
        assertEquals(StreamConfidence.HIGH, insight.originalAudioConfidence)
        assertEquals(listOf(1), insight.seasons)
        assertEquals(listOf(5), insight.episodes)
        assertFalse(insight.isSeasonPack)
    }

    @Test
    fun vostFrSplitTokensAndVostAlone() {
        assertEquals(setOf("fr"), parse(title = "Movie.2021.VOST-FR.1080p").subtitleCodes())
        val vost = parse(title = "Movie.2021.VOST.720p")
        assertTrue(vost.audioLanguages.isEmpty())
        assertEquals(StreamConfidence.LOW, vost.subtitleLanguages.single().confidence)
    }

    @Test
    fun subfrenchAndFrenchSubbedAreSubtitles() {
        val subfrench = parse(title = "Movie.2022.SUBFRENCH.1080p.WEB")
        assertTrue(subfrench.audioLanguages.none { it.language == "fr" })
        assertEquals(setOf("fr"), subfrench.subtitleCodes())

        val subbed = parse(title = "Movie.2019.ENGLISH.FRENCH.SUBBED.720p.BluRay")
        assertEquals(setOf("EN"), subbed.audioTags())
        assertEquals(setOf("fr"), subbed.subtitleCodes())
    }

    @Test
    fun explicitDubSurvivesVostfr() {
        val insight = parse(title = "Show.S01.MULTi.VFF.VOSTFR.1080p.WEB")
        assertEquals(setOf("VFF"), insight.audioTags())
        assertEquals(setOf("fr"), insight.subtitleCodes())
        assertTrue(insight.isSeasonPack)
    }

    @Test
    fun voIsOriginalOnly() {
        val insight = parse(title = "Movie.2020.VO.1080p.WEB")
        assertTrue(insight.audioLanguages.isEmpty())
        assertTrue(insight.includesOriginalAudio)
        assertEquals(StreamConfidence.HIGH, insight.originalAudioConfidence)
    }

    @Test
    fun canadaFlagAloneIsLowConfidenceQuebec() {
        val insight = parse(name = "Torrentio\n1080p", title = "Movie.2023.MULTi.1080p.WEB\n🇨🇦")
        val french = insight.audioLanguages.single()
        assertEquals(StreamLanguageVariant.QUEBEC, french.variant)
        assertEquals(StreamConfidence.LOW, french.confidence)
    }

    @Test
    fun franceAndCanadaFlagsAreTwoLowConfidenceVariants() {
        val insight = parse(title = "Movie.2023.1080p.WEB\n🇫🇷 / 🇨🇦")
        assertEquals(setOf("VFF", "VFQ"), insight.audioTags())
        assertTrue(insight.audioLanguages.all { it.confidence == StreamConfidence.LOW })
    }

    @Test
    fun canadaFlagWithEnglishIsNotFrench() {
        val insight = parse(title = "Movie.2023.1080p.WEB\n🇬🇧 / 🇨🇦")
        assertEquals(setOf("EN"), insight.audioTags())
    }

    @Test
    fun canadaFlagNeverOverridesExplicitTag() {
        assertEquals(setOf("VFF"), parse(title = "Movie.2023.VFF.1080p\n🇨🇦").audioTags())
    }

    @Test
    fun frenchCanadianWords() {
        assertEquals(setOf("VFQ"), parse(title = "Movie 2020 1080p French Canadian").audioTags())
        assertEquals(setOf("VFQ"), parse(description = "Audio: Français (Québec)").audioTags())
        assertEquals(setOf("VFQ"), parse(title = "Movie.2020.fr-CA.1080p").audioTags())
    }

    // endregion

    // region False positives

    @Test
    fun movieTitlesAreNotLanguageTags() {
        assertTrue(parse(title = "The.French.Dispatch.2021.1080p.BluRay.x264").audioLanguages.isEmpty())
        assertTrue(parse(title = "French.Kiss.1995.720p.WEB").audioLanguages.isEmpty())
        assertTrue(parse(title = "The.Italian.Job.2003.1080p.BluRay").audioLanguages.isEmpty())
        assertTrue(parse(title = "It.2017.1080p.BluRay.x264").audioLanguages.isEmpty())
        assertTrue(parse(title = "Freedom.Writers.2007.1080p").audioLanguages.isEmpty())
        assertTrue(parse(title = "An.English.Haunting.2020.720p").audioLanguages.isEmpty())
    }

    @Test
    fun languageWordRightBeforeAnAnchorCounts() {
        assertEquals(setOf("VF"), parse(title = "Intouchables.FRENCH.720p.HDTV").audioTags())
        assertEquals(setOf("VF", "EN"), parse(title = "Movie.FRENCH.ENGLISH.2019.1080p").audioTags())
    }

    @Test
    fun tagsInsideWordsDoNotMatch() {
        val insight = parse(title = "VOD.Release.Vfx.Breakdown.2020.1080p.FRANCHISE.Fruits")
        assertTrue(insight.audioLanguages.isEmpty())
        assertFalse(insight.includesOriginalAudio)
        // Lower-case "fr" is not the FR tag.
        assertTrue(parse(title = "movie.2020.fr.1080p").audioLanguages.isEmpty())
    }

    @Test
    fun bracketedDomainsAreIgnored() {
        val insight = parse(title = "[ Torrent9.FR ] Movie.2020.1080p.WEB")
        assertTrue(insight.audioLanguages.isEmpty())
        val www = parse(title = "www.Cpasbien.FR - Movie.2020.720p")
        assertTrue(www.audioLanguages.isEmpty())
    }

    @Test
    fun titleWordsAreNotLowQualityOr3D() {
        val cam = parse(title = "Cam.2018.1080p.NF.WEB-DL.DDP5.1.x264")
        assertEquals(StreamSourceKind.WEB_DL, cam.source)
        assertFalse(cam.isLowQuality)
        assertFalse(parse(title = "Step.Up.3D.2010.1080p.BluRay").is3D)
        assertTrue(parse(title = "Avatar.2009.1080p.3D.HSBS.BluRay").is3D)
    }

    @Test
    fun fileExtensionTsIsNotTelesync() {
        val insight = parse(filename = "movie.2021.1080p.web.ts")
        assertFalse(insight.isLowQuality)
    }

    @Test
    fun ratingIsNotAudioChannels() {
        val insight = parse(description = "Movie 2021 1080p WEB-DL\n⭐ 7.1 IMDb\n💾 7.1 GB")
        assertNull(insight.audioChannels)
        assertEquals(gb(7.1), insight.sizeBytes)
    }

    @Test
    fun bingeGroupNeverGivesLanguages() {
        val insight = parse(title = "Movie 2020", bingeGroup = "comet|FRENCH|1080p|HDR")
        assertTrue(insight.audioLanguages.isEmpty())
        assertEquals(StreamResolution.P1080, insight.resolution)
    }

    // endregion

    // region Other languages

    @Test
    fun spanishVariants() {
        val both = parse(title = "Movie.2023.1080p.WEB-DL.LATINO.CASTELLANO.DDP5.1")
        assertEquals(setOf("es-419", "es-ES"), both.audioCodes())
        assertEquals(setOf("CAST"), parse(title = "Movie 2023 [Castellano] 1080p").audioTags())
        assertEquals(setOf("es-ES"), parse(title = "Movie.2020.SPANISH.1080p.WEB").audioCodes())
        assertEquals(setOf("LAT"), parse(title = "Movie.2020.1080p.LAT.WEB").audioTags())
    }

    @Test
    fun portugueseVariants() {
        val dual = parse(title = "Movie.2022.1080p.WEB-DL.DUAL.PT-BR.x264")
        assertEquals(setOf("pt-BR"), dual.audioCodes())
        assertTrue(dual.isDualAudio)
        assertEquals(setOf("pt-PT"), parse(title = "Filme.2021.PT-PT.1080p").audioCodes())
        assertEquals(setOf("pt-BR"), parse(title = "Filme 2020 1080p Dublado").audioCodes())
        assertEquals(setOf("pt"), parse(title = "Filme.2020.PORTUGUESE.1080p").audioCodes())
    }

    @Test
    fun flagListOfTorrentio() {
        val insight = parse(title = "Movie.2021.MULTi.1080p.WEB\nMulti Audio / 🇬🇧 / 🇮🇹 / 🇪🇸 / 🇲🇽 / 🇧🇷 / 🇯🇵")
        // 🇪🇸 is Torrentio's flag for any Spanish (it shows 🇪🇸 + 🇲🇽 for "SPANiSH.LATiNO"): with
        // 🇲🇽 next to it, it is the Latin American track, not a second, Castilian one.
        assertEquals(setOf("en", "it", "es-419", "pt-BR", "ja"), insight.audioCodes())
        assertTrue(insight.audioLanguages.none { it.language == "fr" }, "MULTi with listed languages adds no French")
    }

    @Test
    fun manyLanguageCodes() {
        val insight = parse(title = "Movie.2019.GER.JPN.KOR.RUS.POL.NL.HINDI.1080p.BluRay")
        assertEquals(setOf("de", "ja", "ko", "ru", "pl", "nl", "hi"), insight.audioCodes())
        val nordic = parse(title = "Movie.2019.NORDIC.1080p.WEB")
        assertEquals(setOf("sv", "no", "da", "fi"), nordic.audioCodes())
        assertTrue(nordic.audioLanguages.all { it.confidence == StreamConfidence.LOW })
    }

    @Test
    fun dualAudioAnime() {
        val insight = parse(filename = "[SubsPlease] Frieren - 12 (1080p) [Dual-Audio] [ABCD1234].mkv")
        assertTrue(insight.isDualAudio)
        assertTrue(insight.includesOriginalAudio)
        assertEquals(StreamResolution.P1080, insight.resolution)
        assertEquals("SubsPlease", insight.releaseGroup)
    }

    @Test
    fun subtitleLists() {
        val list = parse(description = "Movie 2020 1080p\nSubs: English, French")
        assertEquals(setOf("en", "fr"), list.subtitleCodes())
        assertTrue(list.audioLanguages.isEmpty())

        val engSubs = parse(title = "Movie.2020.FRENCH.1080p.ENG.SUBS")
        assertEquals(setOf("VF"), engSubs.audioTags())
        assertEquals(setOf("en"), engSubs.subtitleCodes())

        val subIta = parse(title = "Movie.2020.ENG.1080p.SUB.ITA")
        assertEquals(setOf("EN"), subIta.audioTags())
        assertEquals(setOf("it"), subIta.subtitleCodes())

        val multiSubs = parse(title = "Movie.2020.1080p.WEB.MULTi-Subs")
        assertFalse(multiSubs.isMultiAudio)
        assertTrue(multiSubs.hasMultiSubtitles)
    }

    @Test
    fun addonSubtitleLanguagesAreSubtitles() {
        val insight = parse(title = "Movie.2020.1080p", subtitleLanguages = listOf("fre", "eng", "pt-BR"))
        assertEquals(setOf("fr", "en", "pt-BR"), insight.subtitleCodes())
    }

    @Test
    fun structuredFields() {
        val insight = parse(
            name = "StremThru",
            title = "Some.Movie",
            parsed = StreamClientResolveParsed(
                resolution = "2160p",
                quality = "BluRay REMUX",
                hdr = listOf("DV", "HDR10"),
                codec = "hevc",
                audio = listOf("Atmos", "TrueHD"),
                channels = listOf("7.1"),
                languages = listOf("fr", "en", "multi audio"),
                group = "FraMeSToR",
                seasons = listOf(1),
                episodes = listOf(2),
            ),
        )
        assertEquals(StreamResolution.P2160, insight.resolution)
        assertEquals(StreamSourceKind.REMUX, insight.source)
        assertTrue(insight.hasDolbyVision)
        assertEquals(StreamAudioCodec.TRUEHD, insight.bestAudioCodec)
        assertEquals("7.1", insight.audioChannels)
        assertEquals(setOf("VF", "EN"), insight.audioTags())
        assertTrue(insight.isMultiAudio)
        assertEquals("FraMeSToR", insight.releaseGroup)
        assertEquals("S01E02", insight.episodeLabel)
    }

    // endregion

    // region Technical details

    @Test
    fun remuxTrueHdAtmos() {
        val insight = parse(title = "Movie.2019.2160p.UHD.BluRay.REMUX.HDR10.HEVC.TrueHD.7.1.Atmos-FGT")
        assertEquals(StreamSourceKind.REMUX, insight.source)
        assertEquals(listOf(StreamHdrFormat.HDR10), insight.hdrFormats)
        assertEquals(StreamAudioCodec.TRUEHD, insight.bestAudioCodec)
        assertEquals("7.1", insight.audioChannels)
        assertTrue(insight.hasAtmos)
        assertEquals("FGT", insight.releaseGroup)
        assertEquals("4K · HDR10 · Atmos · REMUX", insight.qualitySummary)
    }

    @Test
    fun dtsFamily() {
        assertEquals(StreamAudioCodec.DTS_HD_MA, parse(title = "Movie.2010.1080p.BluRay.DTS-HD.MA.5.1.x264").bestAudioCodec)
        assertEquals("5.1", parse(title = "Movie.2010.1080p.BluRay.DTS-HD.MA.5.1.x264").audioChannels)
        assertEquals(StreamAudioCodec.DTS_X, parse(title = "Movie.2010.2160p.BluRay.DTS-X.7.1").bestAudioCodec)
        assertEquals(StreamAudioCodec.DTS_HD, parse(title = "Movie.2010.1080p.BluRay.DTS-HD.HRA.7.1").bestAudioCodec)
        assertEquals(listOf(StreamAudioCodec.DTS), parse(title = "Movie.2010.720p.BluRay.DTS.x264").audioCodecs)
    }

    @Test
    fun dolbyFamily() {
        assertEquals(listOf(StreamAudioCodec.EAC3), parse(title = "Movie.2010.1080p.WEB.E-AC-3.5.1").audioCodecs)
        assertEquals(listOf(StreamAudioCodec.EAC3), parse(title = "Movie 2010 1080p WEB DD+5.1 H264").audioCodecs)
        assertEquals(listOf(StreamAudioCodec.AC3), parse(title = "Movie.2010.720p.HDTV.AC3.5.1").audioCodecs)
        assertEquals(listOf(StreamAudioCodec.AC3), parse(title = "Movie.2010.720p.WEB.DD5.1.x264").audioCodecs)
        val aac = parse(title = "Movie.2010.720p.WEBRip.AAC2.0.x264")
        assertEquals(listOf(StreamAudioCodec.AAC), aac.audioCodecs)
        assertEquals("2.0", aac.audioChannels)
        assertEquals("AAC 2.0", aac.audioSummary)
        assertEquals(StreamSourceKind.WEBRIP, aac.source)
        assertEquals(listOf(StreamAudioCodec.OPUS), parse(title = "Movie.2010.1080p.WEB.Opus.AV1").audioCodecs)
        assertEquals(StreamVideoCodec.AV1, parse(title = "Movie.2010.1080p.WEB.Opus.AV1").videoCodec)
        assertEquals(listOf(StreamAudioCodec.FLAC), parse(title = "Movie.2010.1080p.BluRay.FLAC.2.0").audioCodecs)
    }

    @Test
    fun dolbyVisionProfiles() {
        assertEquals("8", parse(title = "Movie.2023.2160p.WEB-DL.DV.P8.HEVC").dolbyVisionProfile)
        assertEquals("7 FEL", parse(title = "Movie.2023.2160p.BluRay.REMUX.DV.P7.FEL.HEVC").dolbyVisionProfile)
        assertEquals("8.1", parse(title = "Movie.2023.2160p.WEB.DoVi.P8.1.H265").dolbyVisionProfile)
        assertEquals("5", parse(title = "Movie 2023 2160p WEB-DL Dolby Vision Profile 5").dolbyVisionProfile)
        assertNull(parse(title = "Movie.2023.2160p.P8.WEB").dolbyVisionProfile)
    }

    @Test
    fun hdrFormats() {
        assertEquals(listOf(StreamHdrFormat.HDR10_PLUS), parse(title = "Movie.2023.2160p.WEB-DL.HDR10+.H265").hdrFormats)
        assertEquals(listOf(StreamHdrFormat.HDR10_PLUS), parse(title = "Movie.2023.2160p.HDR10Plus.WEB").hdrFormats)
        assertEquals(listOf(StreamHdrFormat.HLG), parse(title = "Movie.2023.2160p.HLG.HDTV").hdrFormats)
        val sdr = parse(title = "Movie.2023.2160p.SDR.WEB")
        assertTrue(sdr.isSdr)
        assertFalse(sdr.hasHdr)
        assertEquals(listOf(StreamHdrFormat.HDR), parse(name = "Torrentio\n4k HDR").hdrFormats)
    }

    @Test
    fun resolutions() {
        assertEquals(StreamResolution.P2160, parse(name = "Torrentio\n4k").resolution)
        assertEquals(StreamResolution.P1440, parse(title = "Movie.2020.1440p.WEB").resolution)
        assertEquals(StreamResolution.P720, parse(title = "Movie.2020.720p.HDTV").resolution)
        assertEquals(StreamResolution.P480, parse(title = "Movie.2004.576p.DVDRip").resolution)
        assertEquals(StreamResolution.SD, parse(name = "Torrentio\nSD").resolution)
        assertEquals(StreamResolution.P1080, parse(title = "Movie 2020 1920x1080 WEB").resolution)
        assertEquals(StreamResolution.UNKNOWN, parse(title = "Movie").resolution)
        assertEquals(StreamSourceKind.DVDRIP, parse(title = "Movie.2004.576p.DVDRip").source)
        assertEquals(10, parse(title = "Movie.2020.1080p.10bit.HEVC").bitDepth)
    }

    @Test
    fun lowQualitySources() {
        assertEquals(StreamSourceKind.CAM, parse(title = "Movie.2024.HDCAM.x264-GRP").source)
        assertEquals(StreamSourceKind.CAM, parse(name = "Torrentio\nCAM", title = "Movie 2024").source)
        assertEquals(StreamSourceKind.TELESYNC, parse(title = "Movie 2024 1080p TS x264").source)
        assertEquals(StreamSourceKind.TELESYNC, parse(title = "Movie.2024.HDTS.720p").source)
        assertEquals(StreamSourceKind.TELECINE, parse(title = "Movie.2024.TC.XviD").source)
        assertEquals(StreamSourceKind.SCREENER, parse(title = "Movie.2024.DVDSCR.x264").source)
        assertTrue(parse(title = "Movie.2024.HDCAM.x264").isLowQuality)
        assertEquals("CAM", parse(title = "Movie.2024.720p.HDCAM").qualitySummary.substringBefore(" "))
    }

    // endregion

    // region Size, seeders, episodes, names

    @Test
    fun sizes() {
        assertEquals(gb(2.3), parse(description = "👤 12 💾 2.3 GB ⚙️ X").sizeBytes)
        assertEquals(gb(1.4), parse(description = "Film 2020 1080p - 1,4 Go").sizeBytes)
        assertEquals((750.0 * 1024 * 1024).toLong(), parse(description = "Film 2020 720p 750 MB").sizeBytes)
        assertEquals(123_456_789L, parse(description = "💾 2.3 GB", videoSize = 123_456_789L).sizeBytes)
        // "1 to 5" is not a terabyte.
        assertNull(parse(description = "Episodes 1 to 5").sizeBytes)
    }

    @Test
    fun seedersFormats() {
        assertEquals(45, parse(description = "👤 45 💾 1 GB").seeders)
        assertEquals(120, parse(description = "Seeders: 120").seeders)
        val sl = parse(description = "S: 12 L: 3")
        assertEquals(12, sl.seeders)
        assertEquals(3, sl.peers)
    }

    @Test
    fun episodesAndPacks() {
        val single = parse(title = "Show.S02E05.1080p.WEB")
        assertEquals(listOf(2), single.seasons)
        assertEquals(listOf(5), single.episodes)
        assertEquals("S02E05", single.episodeLabel)
        assertEquals(listOf(1, 2, 3), parse(title = "Show.S01E01-E03.1080p").episodes)
        val pack = parse(title = "Show.S03.COMPLETE.1080p.WEB")
        assertTrue(pack.isSeasonPack)
        assertEquals(listOf(3), pack.seasons)
        assertEquals(listOf(1, 2, 3, 4, 5), parse(title = "Show.S01-S05.1080p.BluRay").seasons)
        assertEquals(listOf(2), parse(title = "Show Saison 2 Integrale FRENCH 720p").seasons)
        val cross = parse(title = "Show.1x05.720p.HDTV")
        assertEquals(listOf(1), cross.seasons)
        assertEquals(listOf(5), cross.episodes)
        assertFalse(parse(title = "A.Complete.Unknown.2024.1080p").isSeasonPack)
    }

    @Test
    fun urlFilenameIsRead() {
        val insight = parse(url = "https://download.real-debrid.com/d/ABC123/Movie.2021.MULTi.VFF.1080p.WEB.H264-GRP.mkv")
        assertEquals(setOf("VFF"), insight.audioTags())
        assertEquals("GRP", insight.releaseGroup)
        val encoded = parse(url = "https://cdn.example.com/files/Movie%202021%20VFQ%201080p.mkv")
        assertEquals(setOf("VFQ"), encoded.audioTags())
    }

    @Test
    fun releaseNameAndGroup() {
        val insight = parse(title = "Movie.2020.1080p.WEB-DL\n👤 3")
        assertEquals("Movie.2020.1080p.WEB-DL", insight.releaseName)
        assertNull(insight.releaseGroup)
    }

    @Test
    fun stripEmojiForDisplay() {
        assertEquals(
            "Dune 2021 1080p\n152 18.4 GB YggTorrent\nMulti Audio",
            StreamInsightText.stripEmoji("Dune 2021 1080p\n👤 152 💾 18.4 GB ⚙️ YggTorrent\nMulti Audio / 🇫🇷 / 🇬🇧"),
        )
        assertEquals("[RD+] Torrentio · 4k", StreamInsightText.stripEmojiSingleLine("[RD+] Torrentio\n4k"))
        assertEquals("Les Misérables", StreamInsightText.stripEmoji("Les Misérables ⚡"))
    }

    // endregion

    // region Real add-on regressions (texts from Torrentio / TorrentsDB / Peerflix, 2026-10)

    private fun StreamInsight.subtitleTags(): Set<String> = subtitleLanguages.map { it.tag }.toSet()

    @Test
    fun torrentioFlagLineDoesNotTurnSubtitlesIntoAudio() {
        // The 🇬🇧 comes from "ENSUB": English is the subtitle, the audio is French only.
        val ensub = parse(
            name = "Torrentio\n720p",
            title = "Anatomy Of A Fall (2023) FRENCH.ENSUB 720p WEBRip-WORLD\n👤 63 💾 1.36 GB ⚙️ ThePirateBay\n🇬🇧 / 🇫🇷",
        )
        assertEquals(setOf("VF"), ensub.audioTags())
        assertEquals(setOf("EN"), ensub.subtitleTags())
        // An unexplained 🇬🇧 next to a release that names its only audio track is noise.
        val qxr = parse(
            title = "Anatomy of a Fall (2023) (1080p BluRay x265 HEVC 10bit EAC3 5.1 French Silence) [QxR]\n" +
                "👤 106 💾 8.09 GB ⚙️ 1337x\n🇬🇧 / 🇫🇷",
        )
        assertEquals(setOf("VF"), qxr.audioTags())
    }

    @Test
    fun flagFromAMovieTitleWordIsDropped() {
        val insight = parse(
            title = "The French Connection (1971) 2160p 4K AI SDR Upscale Blu-Ray x265 HEVC DTS-HD MA\n" +
                "👤 18 💾 242.34 MB ⚙️ 1337x\n🇬🇧 / 🇫🇷",
        )
        assertEquals(setOf("EN"), insight.audioTags())
        val latinoList = parse(title = "The Latino List 2011 1080p MAX WEB-DL DDP2 0 H 264-GPRS\n🇲🇽")
        assertTrue(latinoList.audioLanguages.isEmpty())
    }

    @Test
    fun torrentioMultiSubsLineFlagsAreSubtitles() {
        // Erai-raws: every flag repeats the subtitle list; nothing is a dub.
        val erai = parse(
            title = "[Erai-raws] Sousou no Frieren - 01 ~ 28 [1080p][BATCH][Multiple Subtitle] " +
                "[ENG][POR-BR][SPA-LA][SPA][ARA][FRE][GER][ITA][RUS]\n" +
                "👤 41 💾 1.48 GB ⚙️ NyaaSi\nMulti Subs / 🇬🇧 / 🇷🇺 / 🇮🇹 / 🇵🇹 / 🇪🇸 / 🇲🇽 / 🇫🇷 / 🇩🇪 / 🇸🇦",
        )
        assertTrue(erai.audioLanguages.isEmpty())
        assertEquals(setOf("EN", "PT-BR", "LAT", "CAST", "AR", "VF", "DE", "IT", "RU"), erai.subtitleTags())
        assertTrue(erai.hasMultiSubtitles)
        // Hindi + English named as audio: the "Multi Subs" flags only confirm them.
        val tombDoc = parse(
            title = "Money Heist (2017) Season 1-2 1080p 10bit NF WEBRip x265 HEVC Hindi-Eng DDP 5.1 MSubs ~ TombDoc\n" +
                "Multi Subs / 🇬🇧 / 🇮🇳",
        )
        assertEquals(setOf("HI", "EN"), tombDoc.audioTags())
        assertTrue(tombDoc.subtitleLanguages.isEmpty())
    }

    @Test
    fun dualAudioWithOneUnexplainedFlagIsTheDub() {
        val trix = parse(
            title = "[Trix] Kimetsu no Yaiba S01-03 (COMPLETE) [Dual Audio][Multi Subs] (720p AV1) - Demon Slayer VOSTFR\n" +
                "Dubbed / Multi Subs / Dual Audio / 🇬🇧 / 🇫🇷",
        )
        assertEquals(setOf("EN"), trix.audioTags())
        assertEquals(setOf("VF"), trix.subtitleTags())
    }

    @Test
    fun italianStyleAudioThenSubtitleLists() {
        // "<audio list> Sub <subtitle list>": the languages before "Sub" are audio.
        val mirCrew = parse(title = "The Platform (2019) 720p h264 Ac3 5.1 Ita Eng Sub Ita Eng-MIRCrew.mkv")
        assertEquals(setOf("IT", "EN"), mirCrew.audioTags())
        assertEquals(setOf("IT", "EN"), mirCrew.subtitleTags())
        // Mixed-case three-letter codes count inside such lists ("iTA Fre", "Sub iTA EnG Fre").
        val monteCristo = parse(title = "The Count of Monte-Cristo (2024) 2160p H265 HDR D.V iTA Fre AC3 Sub iTA EnG Fre - MIRCrew")
        assertEquals(setOf("IT", "VF"), monteCristo.audioTags())
        assertEquals(setOf("IT", "EN", "VF"), monteCristo.subtitleTags())
        // A list right before "SUB" with no other audio named is the audio list.
        assertEquals(setOf("IT", "VF"), parse(title = "Anatomia.di.una.caduta.2023.FULL.HD.1080p.DTS AC3.ITA.FRE.SUB.LFi.mkv").audioTags())
        assertEquals(setOf("IT", "EN", "JA"), parse(title = "Attack on Titan S01e01-25 [720p Ita Eng Jap SubS]").audioTags())
    }

    @Test
    fun languagesBeforeSubsWhenTheAudioIsNamedElsewhere() {
        val insight = parse(filename = "Mommy 2014 BDRip 1080p x264 AC3 French Castellano URBiN4HD Eng Spa Subs.mkv")
        assertEquals(setOf("VF", "CAST"), insight.audioTags())
        assertEquals(setOf("EN", "CAST"), insight.subtitleTags())
        val eng = parse(title = "Lupin (2021) - season 1 (Eng/Multi subs)")
        assertTrue(eng.audioLanguages.isEmpty())
        assertEquals(setOf("en"), eng.subtitleCodes())
        assertTrue(eng.hasMultiSubtitles)
        val hardcoded = parse(title = "City Of God (2002) - English Hardcoded Subs")
        assertTrue(hardcoded.audioLanguages.isEmpty())
        assertEquals(setOf("en"), hardcoded.subtitleCodes())
        assertTrue(hardcoded.hasHardcodedSubtitles)
    }

    @Test
    fun rutrackerTrackLists() {
        val insight = parse(
            title = "Дэдпул и Росомаха / Deadpool & Wolverine [2024 UHD BDRemux 2160p HDR10 Dolby Vision] 4x Dub + 3x MVO + " +
                "VO + Dub Ukr + DVO Ukr + Sub Rus Ukr Eng + Original Eng\n👤 5 💾 56.15 GB ⚙️ Rutracker\n🇬🇧 / 🇷🇺 / 🇺🇦",
        )
        assertEquals(setOf("UK", "EN"), insight.audioTags())
        assertEquals(setOf("RU", "UK", "EN"), insight.subtitleTags())
        // "Original (Fra)" + Russian dub: the 🇷🇺 flag is the voice-over.
        val monteCristo = parse(
            title = "Граф Монте-Кристо / Le comte de Monte-Cristo [2024 WEB-DL 1080p] Dub (Пифагор) + Original (Fra) + Sub (Fra)\n🇷🇺 / 🇫🇷",
        )
        assertEquals(setOf("VF", "RU"), monteCristo.audioTags())
        assertEquals(setOf("RU", "PT"), parse(filename = "Cidade de Deus.2002.BD.Remux.1080p.h264.2xRus.Por.mkv").audioTags())
    }

    @Test
    fun gluedSubtitleTags() {
        assertEquals(setOf("sv", "en"), parse(title = "Incendies.2010.SweSub-EngSub.1080p.x264-Justiso").subtitleCodes())
        assertEquals(setOf("ro"), parse(title = "Oppenheimer.2023.V1.1080p.Cam.X264.RoSub-Will1869").subtitleCodes())
        val burned = parse(title = "Barbie 2023 1080p WEB-DL (HC-KOR) HEVC x265 BONE")
        assertEquals(setOf("ko"), burned.subtitleCodes())
        assertTrue(burned.audioLanguages.isEmpty())
    }

    @Test
    fun quebecOriginalVoq() {
        val insight = parse(title = "Incendies 2010 FRENCH VOQ 1080p HDLight AC3 5 1 H264-LiHDL\n🇫🇷")
        assertEquals(setOf("VFQ"), insight.audioTags())
        assertTrue(insight.includesOriginalAudio)
    }

    @Test
    fun genericMultiAudioDoesNotInventFrench() {
        // Only the bare scene "MULTi" tag implies a French track (French scene convention).
        assertTrue(parse(title = "Dune.Part.Two.2024.1080p.Bluray.REMUX.Multi.Audio.AVC.TrueHD.Atmos.7.1-VARR0A")
            .audioLanguages.none { it.language == "fr" })
        assertTrue(parse(title = "Elite (S01-06)(2018-2022)(1080p)(AVC)(WebDl)(Multi 4 lang)(MultiSUB) PHDTeam")
            .audioLanguages.none { it.language == "fr" })
        assertEquals(setOf("VF"), parse(title = "La.Casa.De.Papel.S01E01.MULTi.720p.NF.WEB-DL.x264-ARK01").audioTags())
    }

    @Test
    fun spanishSitesAndVariants() {
        // "SPANiSH.LATiNO" is Latin American only; Torrentio adds 🇪🇸 + 🇲🇽 for it.
        assertEquals(
            setOf("LAT"),
            parse(title = "Dune.Part.Two.2024.SPANiSH.LATiNO.1080p.WEB-DL.DDP5.1.H.264-dem3nt3\n🇪🇸 / 🇲🇽").audioTags(),
        )
        // Spanish spellings of other languages.
        val coco = parse(title = "Coco [BluRay 1080p][AC3 5.1 Castellano DTS 5.1-Ingles+Subs][ES-EN]")
        assertEquals(setOf("CAST", "EN"), coco.audioTags())
        assertEquals(setOf("es", "en"), coco.subtitleCodes())
        assertEquals(setOf("CAST", "VF"), parse(title = "El conde de Montecristo Castellano-Frances +Subs H264 AC3 5.1 BD-Rip hd 1080p").audioTags())
        // A lone 🇪🇸 from Peerflix says Spanish, not which Spanish.
        assertEquals(setOf("LAT"), parse(name = "Peerflix 🇪🇸 480p", title = "Cocote [720p][Latino]").audioTags())
        assertEquals(setOf("ES"), parse(name = "Peerflix 🇪🇸 1080p", title = "Deadpool y Lobezno (2024) UHD.iso").audioTags())
    }

    @Test
    fun portugueseFlagsAndBrazilianSites() {
        // Torrentio shows 🇵🇹 for "Dublado" (Brazilian) releases.
        val dublado = parse(title = "Deadpool.e.Wolverine.1080p.HDCAM.Dublado.PT_BR\n🇵🇹")
        assertEquals(setOf("PT-BR"), dublado.audioTags())
        val comando = parse(
            title = "Dragons.Race.To.The.Edge.S01E01.720p.NF.WEB-DL.DDP5.1.H264.DUAL\n👤 0 💾 408.5 MB ⚙️ Comando\nDual Audio / 🇬🇧 / 🇵🇹",
        )
        assertEquals(setOf("EN", "PT-BR"), comando.audioTags())
        assertEquals(setOf("pt"), parse(title = "City.of.God.2002.PORTUGUESE.1080p.BluRay.x265-VXT\n🇵🇹").audioCodes())
    }

    @Test
    fun animeSubtitleListsAndDubLists() {
        val anitsu = parse(title = "[Anitsu] Sousou no Frieren S01 [BD 1080p x265 Opus] [DUAL JAP PT-BR] [SUB PT-BR ENG]")
        assertEquals(setOf("JA", "PT-BR"), anitsu.audioTags())
        assertEquals(setOf("PT-BR", "EN"), anitsu.subtitleTags())
        val toonsHub = parse(
            title = "[ToonsHub] Frieren - 01 (Multi-Audio 1080p x264 AAC) [Multi-Subs] (English Japanese Hindi Tamil French Dubs)",
        )
        assertEquals(setOf("EN", "JA", "HI", "TA", "VF"), toonsHub.audioTags())
        assertTrue(toonsHub.subtitleLanguages.isEmpty())
        assertTrue(toonsHub.hasMultiSubtitles)
    }

    @Test
    fun indianLanguageListsAndCountryCodes() {
        val tamil = parse(title = "Anatomy of a Fall (2023) [1080p BDRip - x264 - [Tam + Mal + Tel + Hin + Eng] - DD5.1 - ESub]")
        assertEquals(setOf("TA", "ML", "TE", "HI", "EN"), tamil.audioTags())
        assertEquals(setOf("en"), tamil.subtitleCodes())
        assertEquals(setOf("CS", "SK", "EN"), parse(title = "Coco (2017)(CZ/SK/EN)[2160p][HDR10/DV][HEVC]").audioTags())
        assertEquals(setOf("JA", "EN", "IT"), parse(title = "[JPN-ENG] Attack on Titan : Season 01 S01 [2013] 1080p Hybrid ITA BDRip").audioTags())
    }

    // endregion
}
