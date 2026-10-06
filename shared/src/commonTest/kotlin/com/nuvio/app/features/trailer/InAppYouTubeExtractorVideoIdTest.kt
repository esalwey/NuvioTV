package com.nuvio.app.features.trailer

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * BUG-81 (tvOS letterbox zoom): [TrailerPlaybackSource.videoId] is the only per-video identity
 * that survives separate extractions (googlevideo's host, `itag` and even `id=` all rotate), so
 * [extractYouTubeVideoId] has to recover it from every URL shape the trailer pipeline feeds in.
 */
class InAppYouTubeExtractorVideoIdTest {

    @Test
    fun acceptsBareId() {
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("rNZ0xKaCdus"))
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("  rNZ0xKaCdus\n"))
    }

    @Test
    fun readsWatchQueryParameter() {
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("https://www.youtube.com/watch?v=rNZ0xKaCdus"))
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("https://www.youtube.com/watch?v=rNZ0xKaCdus&hl=en&t=12"))
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("https://m.youtube.com/watch?feature=share&v=rNZ0xKaCdus"))
    }

    @Test
    fun readsShortLinkAndPathForms() {
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("https://youtu.be/rNZ0xKaCdus"))
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("https://youtu.be/rNZ0xKaCdus?si=abc"))
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("https://www.youtube.com/embed/rNZ0xKaCdus"))
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("https://www.youtube.com/shorts/rNZ0xKaCdus"))
        assertEquals("rNZ0xKaCdus", extractYouTubeVideoId("https://www.youtube.com/live/rNZ0xKaCdus"))
    }

    @Test
    fun rejectsMalformedIds() {
        assertNull(extractYouTubeVideoId(""))
        assertNull(extractYouTubeVideoId("not a url"))
        assertNull(extractYouTubeVideoId("https://www.youtube.com/watch?v=tooShort"))
        assertNull(extractYouTubeVideoId("https://www.youtube.com/watch?v=waytoolongforanid"))
        assertNull(extractYouTubeVideoId("https://youtu.be/"))
        assertNull(extractYouTubeVideoId("https://www.youtube.com/channel/rNZ0xKaCdus"))
    }

    @Test
    fun playbackSourceCarriesVideoIdThroughCopy() {
        // The common extractor stamps the id with `copy(videoId = …)` on whatever the platform's
        // `buildPlaybackSource` returned; a platform that never sets it must leave it null.
        val platformBuilt = TrailerPlaybackSource(videoUrl = "https://example/v", audioUrl = null)
        assertNull(platformBuilt.videoId)
        assertEquals("rNZ0xKaCdus", platformBuilt.copy(videoId = "rNZ0xKaCdus").videoId)
        assertEquals("https://example/v", platformBuilt.copy(videoId = "rNZ0xKaCdus").videoUrl)
    }
}
