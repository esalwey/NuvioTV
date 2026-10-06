package com.nuvio.app.features.streams

import com.nuvio.app.features.debrid.DebridTrackMetadata
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VerifiedTracksTest {

    private var now = 1_700_000_000_000L

    @BeforeTest
    fun setUp() {
        VerifiedTrackStore.persistenceEnabled = false
        VerifiedTrackStore.clock = { now }
        VerifiedTrackStore.clearAll()
    }

    @AfterTest
    fun tearDown() {
        VerifiedTrackStore.clearAll()
    }

    private fun audio(language: String?, name: String? = null, tag: String? = null) =
        ContainerTrack(ContainerTrackKind.AUDIO, language = language, languageTag = tag, name = name)

    private fun subtitle(language: String, forced: Boolean = false) =
        ContainerTrack(ContainerTrackKind.SUBTITLE, language = language, isForced = forced)

    private fun record(vararg tracks: ContainerTrack) =
        VerifiedTrackRecord(tracks.map(VerifiedTrack::from), verifiedAtMs = now, lastUsedMs = now)

    // region Track languages

    @Test
    fun trackLanguagesMapToTheParserVariants() {
        fun of(track: ContainerTrack) = VerifiedTrackLanguages.languageOf(VerifiedTrack.from(track))
        assertEquals("VF", of(audio("fre"))?.tag)
        assertEquals("VFF", of(audio("fre", name = "VFF"))?.tag)
        assertEquals("VFF", of(audio("fra", name = "TrueFrench 5.1"))?.tag)
        assertEquals("VFQ", of(audio("fre", name = "VFQ"))?.tag)
        assertEquals("VFQ", of(audio("fre", name = "French (Canada)"))?.tag)
        assertEquals("VFQ", of(audio("fre", tag = "fr-CA"))?.tag)
        assertEquals("VFF", of(audio("fre", tag = "fr-FR"))?.tag)
        assertEquals("EN", of(audio("eng"))?.tag)
        assertEquals("PT-BR", of(audio("por", tag = "pt-BR"))?.tag)
        assertEquals("LAT", of(audio("spa", name = "Latino"))?.tag)
        assertEquals("LAT", of(audio("spa", tag = "es-419"))?.tag)
        // An undetermined code with a title that states the language.
        assertEquals("VFQ", of(audio("und", name = "VFQ"))?.tag)
        assertNull(of(audio("und")))
        assertNull(of(audio(null)))
        assertNull(of(audio("eng", name = "Director's Commentary")))
        assertNull(of(audio("fre", name = "Audiodescription")))
    }

    @Test
    fun applyReplacesTheTitleGuessWithTheFileTracks() {
        val untagged = StreamInsightParser.parseText(null, "Movie.2023.1080p.WEB-DL.DDP5.1", null)
        assertTrue(untagged.audioLanguageUnknown)
        val verified = VerifiedTrackLanguages.applyRecord(untagged, record(audio("fre"), audio("eng"), subtitle("fre"), subtitle("eng", forced = true)))
        assertFalse(verified.audioLanguageUnknown)
        assertTrue(verified.audioVerified)
        assertEquals(listOf("fr", "en"), verified.audioLanguages.map { it.language })
        assertTrue(verified.audioLanguages.all { it.confidence == StreamConfidence.HIGH })
        assertEquals(listOf("fr"), verified.subtitleLanguages.map { it.language }, "a forced-only track is not a VOST")
    }

    @Test
    fun applyKeepsTheVersionTheTitleStatesForAPlainFrenchTrack() {
        val vff = StreamInsightParser.parseText(null, "Movie.2023.MULTi.VFF.1080p.WEB-DL", null)
        val verified = VerifiedTrackLanguages.applyRecord(vff, record(audio("fre"), audio("eng")))
        assertEquals(listOf("VFF", "EN"), verified.audioLanguages.map { it.tag })
    }

    @Test
    fun aFileWithOnlyUndeterminedTracksStaysUnknown() {
        val untagged = StreamInsightParser.parseText(null, "Movie.2023.1080p.WEB-DL", null)
        val result = VerifiedTrackLanguages.applyRecord(untagged, record(audio("und")))
        assertTrue(result.audioLanguageUnknown)
    }

    // endregion

    // region Store

    private val torrentioStream = StreamItem(
        name = "Torrentio\n1080p",
        title = "Movie.2023.1080p.WEB-DL",
        infoHash = "0123456789abcdef0123456789abcdef01234567",
        fileIdx = 2,
        addonName = "Torrentio",
        addonId = "addon:torrentio",
        behaviorHints = StreamBehaviorHints(filename = "Movie.2023.1080p.WEB-DL.mkv", videoSize = 4_000_000_000),
    )

    @Test
    fun aRecordIsFoundByAnotherAddonListingTheSameFile() {
        assertNotNull(VerifiedTrackStore.record(torrentioStream, listOf(audio("fre"), audio("eng")), VerifiedTrackSource.PROBE))
        // Same file name and size, different add-on, no info hash, a direct link.
        val other = StreamItem(
            name = "Comet",
            url = "https://cdn.example.com/files/abc",
            addonName = "Comet",
            addonId = "addon:comet",
            behaviorHints = StreamBehaviorHints(filename = "movie 2023 1080p web-dl.mkv", videoSize = 4_000_000_000),
        )
        val found = assertNotNull(VerifiedTrackStore.lookup(other))
        assertEquals(VerifiedTrackSource.PROBE.name, found.source)
        // Info hash + file index alone.
        assertNotNull(VerifiedTrackStore.lookup(torrentioStream.copy(behaviorHints = StreamBehaviorHints())))
        // Another file of the same torrent is not this one.
        assertNull(VerifiedTrackStore.lookup(torrentioStream.copy(fileIdx = 3, behaviorHints = StreamBehaviorHints())))
    }

    @Test
    fun recordsExpireAfterNinetyDays() {
        VerifiedTrackStore.record(torrentioStream, listOf(audio("fre")), VerifiedTrackSource.PROBE)
        now += VerifiedTrackStore.TTL_MS - 1
        assertNotNull(VerifiedTrackStore.lookup(torrentioStream))
        now += 2
        assertNull(VerifiedTrackStore.lookup(torrentioStream))
    }

    @Test
    fun theStoreIsBoundedAndDropsTheLeastRecentlyUsed() {
        val first = listOf("first")
        VerifiedTrackStore.recordKeys(first, listOf(audio("fre")), VerifiedTrackSource.PROBE)
        repeat(VerifiedTrackStore.MAX_ENTRIES) { index ->
            now += 1
            VerifiedTrackStore.recordKeys(listOf("k$index"), listOf(audio("eng")), VerifiedTrackSource.PROBE)
        }
        assertEquals(VerifiedTrackStore.MAX_ENTRIES, VerifiedTrackStore.size())
        assertNull(VerifiedTrackStore.lookupKeys(first))
        assertNotNull(VerifiedTrackStore.lookupKeys(listOf("k${VerifiedTrackStore.MAX_ENTRIES - 1}")))
    }

    @Test
    fun trackListsWithoutAnyLanguageAreNotRemembered() {
        assertNull(VerifiedTrackStore.record(torrentioStream, listOf(audio("und")), VerifiedTrackSource.PROBE))
        assertNull(VerifiedTrackStore.lookup(torrentioStream))
    }

    @Test
    fun playedTracksLandOnTheStreamThePickerRegistered() {
        val resolvedUrl = "https://abc.download.real-debrid.com/d/XYZ/Movie.mkv"
        VerifiedTrackStore.registerPlayback(resolvedUrl, torrentioStream)
        VerifiedTrackStore.recordPlayback(resolvedUrl, listOf(audio("fre", name = "VFQ"), audio("eng")))
        val found = assertNotNull(VerifiedTrackStore.lookup(torrentioStream))
        assertEquals(VerifiedTrackSource.PLAYBACK.name, found.source)
        assertEquals(listOf("VFQ", "EN"), VerifiedTrackLanguages.audioLanguages(found).map { it.tag })
    }

    @Test
    fun keysAreHashedSoNoLinkIsStored() {
        val keys = VerifiedTrackKeys.forStream(torrentioStream.copy(url = "https://example.com/secret-token/file.mkv"))
        assertTrue(keys.isNotEmpty())
        assertTrue(keys.none { it.contains("secret") || it.contains("example") })
    }

    // endregion

    // region Eligibility

    private fun eligible(stream: StreamItem) = TrackVerification.probeUrl(stream, StreamInsightParser.parse(stream))

    @Test
    fun onlyFreeLinksAreProbed() {
        val direct = StreamItem(name = "HTTP add-on", title = "Movie.2023.1080p", url = "https://cdn.example.com/Movie.mkv", addonName = "A", addonId = "addon:a")
        assertEquals("https://cdn.example.com/Movie.mkv", eligible(direct))
        // A torrent the app has not resolved: nothing to read.
        assertNull(eligible(torrentioStream))
        // Torrentio + Real-Debrid, cached: the resolve link redirects to the file.
        val cached = StreamItem(
            name = "[RD+] Torrentio\n1080p", title = "Movie.2023.1080p",
            url = "https://torrentio.strem.fun/resolve/realdebrid/KEY/0123456789abcdef0123456789abcdef01234567/null/0/Movie.mkv",
            addonName = "Torrentio", addonId = "addon:torrentio",
        )
        assertNotNull(eligible(cached))
        // Not cached: asking for the link would start the torrent download.
        assertNull(eligible(cached.copy(name = "[RD download] Torrentio\n1080p")))
        // Cache state not stated on a resolve link: never.
        assertNull(eligible(cached.copy(name = "[RD] Torrentio\n1080p")))
        // A link the app resolved itself (keeps the info hash): the debrid file.
        assertNotNull(eligible(torrentioStream.copy(url = "https://abc.download.real-debrid.com/d/XYZ/Movie.mkv")))
        // Magnets are not links.
        assertNull(eligible(direct.copy(url = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")))
    }

    // endregion

    // region Real-Debrid media info

    @Test
    fun realDebridMediaInfosAudioAndSubtitlesAreRead() {
        val body = Json.parseToJsonElement(
            """
            {"filename":"Movie.mkv","details":{
              "video":{"und1":{"stream":"0:0","lang":"Unknown","lang_iso":"und","codec":"hevc"}},
              "audio":{"fre1":{"stream":"0:1","lang":"French","lang_iso":"fre","codec":"eac3","sampling":48000,"channels":5.1},
                       "eng2":{"stream":"0:2","lang":"English","lang_iso":"eng","codec":"truehd","sampling":48000,"channels":7.1}},
              "subtitles":[{"fre3":{"stream":"0:3","lang":"French","lang_iso":"fre","type":"SRT"}}]
            }}
            """.trimIndent(),
        ).jsonObject
        val tracks = DebridTrackMetadata.realDebridTracks(body)
        assertEquals(listOf("fre", "eng", "fre"), tracks.map { it.language })
        assertEquals(listOf(6, 8), tracks.filter { it.kind == ContainerTrackKind.AUDIO }.map { it.channels })
        assertEquals(ContainerTrackKind.SUBTITLE, tracks.last().kind)
    }

    // endregion
}
