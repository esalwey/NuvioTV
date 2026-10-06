package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * GitHub issue #2 (header-gated addon streams) + Codex 2026-08-20 round 3 hardening. The base
 * rules mirror upstream composeApp's `sanitizePlaybackHeaders` (trim, drop blanks, drop Range);
 * the token/control-character rejections are fork-side hardening because the tvOS consumers
 * serialize these into FFmpeg's CRLF-joined `headers` block and mpv's comma-delimited
 * `http-header-fields`, where an unvalidated entry is a header-injection vector.
 */
class SanitizePlaybackHeadersTest {

    @Test
    fun keepsOrdinaryHeadersAndTrims() {
        assertEquals(
            mapOf("Referer" to "https://example.com", "User-Agent" to "Nuvio"),
            sanitizePlaybackHeaders(
                mapOf(" Referer " to " https://example.com ", "User-Agent" to "Nuvio"),
            ),
        )
    }

    @Test
    fun dropsBlankAndRangeEntries() {
        assertEquals(
            emptyMap(),
            sanitizePlaybackHeaders(
                mapOf("" to "x", "Accept" to "  ", "Range" to "bytes=0-", "range" to "bytes=1-"),
            ),
        )
    }

    @Test
    fun rejectsNonTokenHeaderNames() {
        // Spaces, colons, and separator characters are not RFC 7230 tchars — an embedded colon
        // or comma would smuggle a second field through mpv's comma-joined serialization.
        assertEquals(
            emptyMap(),
            sanitizePlaybackHeaders(
                mapOf(
                    "X-Bad Header" to "v",
                    "X-Bad:Colon" to "v",
                    "X,Comma" to "v",
                    "Höst" to "v",
                ),
            ),
        )
    }

    @Test
    fun rejectsControlCharactersInValues() {
        // CR/LF in a value becomes an extra line in FFmpeg's CRLF header block — classic
        // header injection, including re-introducing the Range we just refused.
        assertEquals(
            mapOf("Good" to "value"),
            sanitizePlaybackHeaders(
                mapOf(
                    "Evil" to "v\r\nRange: bytes=0-",
                    "AlsoEvil" to "v\u0000null",
                    "Del" to "v\u007Fx",
                    "Good" to "value",
                ),
            ),
        )
    }

    @Test
    fun nullOrEmptyInputYieldsEmptyMap() {
        assertEquals(emptyMap(), sanitizePlaybackHeaders(null))
        assertEquals(emptyMap(), sanitizePlaybackHeaders(emptyMap()))
    }
}
