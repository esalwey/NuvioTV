package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PlaybackUrlCredentialsTest {
    @Test
    fun `signed and tokenised links are treated as expiring`() {
        assertTrue("https://cdn.example.com/video.mkv?token=abc".hasLikelyExpiringPlaybackCredentials())
        assertTrue("https://cdn.example.com/video.mkv?Expires=1&Signature=x".hasLikelyExpiringPlaybackCredentials())
    }

    @Test
    fun `static api keys and format hints are not expiring`() {
        assertFalse("https://example.com/video.mkv?api_key=static".hasLikelyExpiringPlaybackCredentials())
        assertFalse("https://example.com/video.mkv?apikey=static".hasLikelyExpiringPlaybackCredentials())
        assertFalse("https://example.com/video.mp4?quality=1080p&format=mp4".hasLikelyExpiringPlaybackCredentials())
    }

    @Test
    fun `log redaction drops the query and fragment`() {
        assertEquals(
            "https://example.com/video.mkv",
            "https://example.com/video.mkv?token=secret#frag".redactedForLogs(),
        )
    }
}
