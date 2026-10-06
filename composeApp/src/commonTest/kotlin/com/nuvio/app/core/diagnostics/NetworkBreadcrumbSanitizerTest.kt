package com.nuvio.app.core.diagnostics

import kotlin.test.Test
import kotlin.test.assertEquals

class NetworkBreadcrumbSanitizerTest {

    @Test
    fun redactsDebridStyleTokenPathSegment() {
        assertEquals(
            "/d/-redacted-/-redacted-",
            NetworkBreadcrumbSanitizer.sanitizePath("/d/PMZKQ7Y3PEXB4PPHAETRV6M2NQ/Some.Movie.2024.2160p.mkv"),
        )
    }

    @Test
    fun redactsJwtStyleSegment() {
        assertEquals(
            "/playback/-redacted-",
            NetworkBreadcrumbSanitizer.sanitizePath(
                "/playback/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123",
            ),
        )
    }

    @Test
    fun redactsHexHashSegment() {
        assertEquals(
            "/stream/-redacted-",
            NetworkBreadcrumbSanitizer.sanitizePath("/stream/8f434346648f6b96df89dda901c5176b"),
        )
    }

    @Test
    fun keepsPlainRouteWords() {
        assertEquals(
            "/api/v2/torrents/info",
            NetworkBreadcrumbSanitizer.sanitizePath("/api/v2/torrents/info"),
        )
    }

    @Test
    fun keepsManifestJson() {
        assertEquals(
            "/manifest.json",
            NetworkBreadcrumbSanitizer.sanitizePath("/manifest.json"),
        )
    }

    @Test
    fun redactsContentIdsButKeepsRouteShape() {
        assertEquals(
            "/stream/movie/-redacted-",
            NetworkBreadcrumbSanitizer.sanitizePath("/stream/movie/tt1234567.json"),
        )
    }

    @Test
    fun keepsShortNumericIds() {
        assertEquals(
            "/meta/123456",
            NetworkBreadcrumbSanitizer.sanitizePath("/meta/123456"),
        )
    }

    @Test
    fun redactsLongNumericSegments() {
        assertEquals(
            "/d/-redacted-",
            NetworkBreadcrumbSanitizer.sanitizePath("/d/98214657098214657098"),
        )
    }

    @Test
    fun redactsPercentEncodedSegments() {
        assertEquals(
            "/files/-redacted-",
            NetworkBreadcrumbSanitizer.sanitizePath("/files/My%20Movie%202024"),
        )
    }

    @Test
    fun preservesRootAndEmptyPaths() {
        assertEquals("/", NetworkBreadcrumbSanitizer.sanitizePath("/"))
        assertEquals("", NetworkBreadcrumbSanitizer.sanitizePath(""))
    }

    @Test
    fun preservesTrailingSlash() {
        assertEquals(
            "/api/",
            NetworkBreadcrumbSanitizer.sanitizePath("/api/"),
        )
    }

    @Test
    fun redactsAllLetterTokensNotOnTheRouteAllowlist() {
        assertEquals(
            "/playback/-redacted-",
            NetworkBreadcrumbSanitizer.sanitizePath("/playback/abcdefghijklmnopqrst"),
        )
    }

    @Test
    fun redactsOverlongRouteLookingSegments() {
        assertEquals(
            "/-redacted-",
            NetworkBreadcrumbSanitizer.sanitizePath(
                "/averyveryverylongsegmentthatlookslikewordsbutcouldbeatoken",
            ),
        )
    }
}
