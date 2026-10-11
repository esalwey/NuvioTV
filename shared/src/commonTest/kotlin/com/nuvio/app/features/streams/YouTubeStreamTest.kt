package com.nuvio.app.features.streams

import com.nuvio.app.features.trailer.TrailerAdaptiveTrack
import com.nuvio.app.features.trailer.TrailerPlaybackSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class YouTubeStreamTest {

    private fun parse(streamJson: String): List<StreamItem> =
        StreamParser.parse(
            payload = """{"streams":[$streamJson]}""",
            addonName = "Addon",
            addonId = "addon:test",
        )

    @Test
    fun parserKeepsAStreamThatOnlyHasAYtId() {
        val streams = parse("""{"name":"Trailer","ytId":" dQw4w9WgXcQ "}""")
        assertEquals(1, streams.size)
        assertEquals("dQw4w9WgXcQ", streams.single().ytId)
        assertEquals("dQw4w9WgXcQ", streams.single().youTubeIdToResolve)
        assertTrue(streams.single().hasPlayableSource)
        assertTrue(streams.single().isSelectableForPlayback(debridEnabled = false))
    }

    @Test
    fun parserStillDropsAStreamWithNothingToPlay() {
        assertTrue(parse("""{"name":"Nothing"}""").isEmpty())
        assertTrue(parse("""{"name":"Blank","ytId":"  "}""").isEmpty())
    }

    @Test
    fun otherSourcesWinOverTheYtId() {
        val withUrl = parse("""{"url":"https://example.com/v.mp4","ytId":"dQw4w9WgXcQ"}""").single()
        assertNull(withUrl.youTubeIdToResolve)
        val withHash = parse("""{"infoHash":"0123456789abcdef0123456789abcdef01234567","ytId":"dQw4w9WgXcQ"}""").single()
        assertNull(withHash.youTubeIdToResolve)
        val withExternal = parse("""{"externalUrl":"https://example.com/page","ytId":"dQw4w9WgXcQ"}""").single()
        assertNull(withExternal.youTubeIdToResolve)
    }

    @Test
    fun aYtIdOnlyStreamHasNoDirectUrlSoAutoPlaySkipsIt() {
        val stream = parse("""{"ytId":"dQw4w9WgXcQ"}""").single()
        assertNull(stream.playableDirectUrl)
        val selected = StreamAutoPlaySelector.selectAutoPlayStream(
            streams = listOf(stream),
            mode = StreamAutoPlayMode.FIRST_STREAM,
            regexPattern = "",
            source = StreamAutoPlaySource.ALL_SOURCES,
            installedAddonNames = setOf("Addon"),
            selectedAddons = emptySet(),
            selectedPlugins = emptySet(),
        )
        assertNull(selected)
    }

    @Test
    fun watchUrlIsOnlyBuiltForStreamsThatNeedResolving() {
        val ytOnly = parse("""{"ytId":"dQw4w9WgXcQ"}""").single()
        assertEquals("https://www.youtube.com/watch?v=dQw4w9WgXcQ", YouTubeStreamResolver.watchUrlToResolve(ytOnly))
        val direct = parse("""{"url":"https://example.com/v.mp4"}""").single()
        assertNull(YouTubeStreamResolver.watchUrlToResolve(direct))
    }

    private fun track() = TrailerAdaptiveTrack(
        url = "https://example.com/t", codecs = "avc1", bitrate = 1, width = 1, height = 1,
        initStart = 0, initEnd = 1, indexStart = 2, indexEnd = 3, durationMs = 1000,
    )

    @Test
    fun masterPlaylistIsPreferredUnlessAPairIsWorthRepackaging() {
        val master = TrailerPlaybackSource(
            videoUrl = "https://example.com/video",
            progressiveUrl = "https://example.com/variant.m3u8",
            masterPlaylistUrl = " https://example.com/master.m3u8 ",
        )
        assertEquals("https://example.com/master.m3u8", YouTubeStreamResolver.preferredDirectUrl(master))

        val repack = master.copy(adaptiveVideo = track(), adaptiveAudio = track())
        assertNull(YouTubeStreamResolver.preferredDirectUrl(repack))

        val noMaster = TrailerPlaybackSource(videoUrl = "https://example.com/video", masterPlaylistUrl = "  ")
        assertNull(YouTubeStreamResolver.preferredDirectUrl(noMaster))
    }
}
