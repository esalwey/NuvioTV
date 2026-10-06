package com.nuvio.app.features.trailer

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * RISK (beta.16+): the HLS SABR-fallback path lands on a bare, non-EDR `AVPlayerLayer`
 * by design (BUG-18/59 retirement — see `TrailerHeroPlayerView.swift`), so a PQ/HLG
 * VIDEO-RANGE variant renders milky/washed-out there. The 08-28 client swap
 * (android_vr -> visionos) changed which variants YouTube offers, making this newly
 * reachable. These pin [selectBestHlsVariant]'s SDR-preferring guard.
 * Ref: docs/steven-batch-plan-2026-08-29.md Wave 4 item 3.
 */
class InAppYouTubeExtractorVariantTest {

    private fun variant(
        id: String,
        height: Int,
        bandwidth: Long = height.toLong() * 1_000,
        width: Int = height * 16 / 9,
        videoRange: String? = null,
    ) = HlsVariantCandidate(
        url = id,
        width = width,
        height = height,
        bandwidth = bandwidth,
        videoRange = videoRange,
    )

    @Test
    fun prefersSdrOverHigherPqVariant() {
        val candidates = listOf(
            variant("pq-1080", height = 1080, videoRange = "PQ"),
            variant("sdr-720", height = 720, videoRange = "SDR"),
        )
        assertEquals("sdr-720", selectBestHlsVariant(candidates)?.url)
    }

    @Test
    fun fallsBackToUnfilteredBestWhenOnlyHdrVariantsExist() {
        val candidates = listOf(
            variant("hlg-720", height = 720, videoRange = "HLG"),
            variant("pq-1080", height = 1080, videoRange = "PQ"),
        )
        // No SDR survivor: the picker still returns the best HDR variant rather than
        // nothing — a washed-out trailer beats no trailer.
        assertEquals("pq-1080", selectBestHlsVariant(candidates)?.url)
    }

    @Test
    fun treatsMissingVideoRangeAsSdr() {
        val candidates = listOf(
            variant("pq-1080", height = 1080, videoRange = "PQ"),
            variant("untagged-720", height = 720, videoRange = null),
        )
        assertEquals("untagged-720", selectBestHlsVariant(candidates)?.url)
    }

    @Test
    fun keepsHeightBandwidthWidthOrderingAmongSurvivors() {
        val candidates = listOf(
            variant("sdr-720-low-bw", height = 720, bandwidth = 1_000, videoRange = "SDR"),
            variant("sdr-720-high-bw", height = 720, bandwidth = 5_000, videoRange = null),
            variant("sdr-480", height = 480, bandwidth = 9_000, videoRange = "SDR"),
        )
        assertEquals("sdr-720-high-bw", selectBestHlsVariant(candidates)?.url)
    }

    @Test
    fun returnsNullForEmptyCandidateList() {
        assertNull(selectBestHlsVariant(emptyList()))
    }
}

/**
 * F2 (beta.16 regression): a variant with a separate AUDIO group is video-only when played
 * directly, since the audio lives in a sibling `#EXT-X-MEDIA` rendition this extractor never
 * parses. [resolvePlaybackUrl] is the pure decision point — pinned here directly rather than
 * through `parseHlsManifest`, which is network-bound.
 */
class ResolvePlaybackUrlTest {

    private fun variant(audioGroup: String?) = HlsVariantCandidate(
        url = "https://example.com/variant.m3u8",
        width = 1920,
        height = 1080,
        bandwidth = 5_000_000,
        videoRange = null,
        audioGroup = audioGroup,
    )

    @Test
    fun winnerWithAudioGroupReturnsMasterUrl() {
        val masterUrl = "https://example.com/master.m3u8"
        assertEquals(masterUrl, resolvePlaybackUrl(variant(audioGroup = "aud-group-1"), masterUrl))
    }

    @Test
    fun winnerWithoutAudioGroupReturnsVariantUrl() {
        val winner = variant(audioGroup = null)
        assertEquals(winner.url, resolvePlaybackUrl(winner, masterUrl = "https://example.com/master.m3u8"))
    }
}

/**
 * F2: pins that `AUDIO="..."` on an `#EXT-X-STREAM-INF` line survives attribute parsing intact,
 * since [InAppYouTubeExtractor.parseHlsAttributeList] is what feeds
 * [HlsVariantCandidate.audioGroup].
 */
class ParseHlsAttributeListAudioGroupTest {

    @Test
    fun parsesAudioAttributeFromStreamInfLine() {
        val line = "#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080," +
            "VIDEO-RANGE=SDR,AUDIO=\"aud-group-1\",CODECS=\"avc1.640028,mp4a.40.2\""
        val attrs = InAppYouTubeExtractor().parseHlsAttributeList(line)
        assertEquals("aud-group-1", attrs["AUDIO"])
    }

    @Test
    fun missingAudioAttributeParsesAsNull() {
        val line = "#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,VIDEO-RANGE=SDR"
        val attrs = InAppYouTubeExtractor().parseHlsAttributeList(line)
        assertNull(attrs["AUDIO"])
    }
}

/**
 * F3 (beta.16 hotfix): [InAppYouTubeExtractor.pickBestForClient] must walk the ordered
 * preferred-client chain, treating the first client that CONTRIBUTED any candidate as the
 * winner outright — never scoring across clients — and only pool everything when none of the
 * preferred clients contributed anything.
 */
class PickBestForClientTest {

    private fun candidate(client: String, height: Int) = StreamCandidate(
        client = client,
        priority = 0,
        url = "https://example.com/$client-$height.mp4",
        score = height.toDouble(),
        hasN = false,
        height = height,
        fps = 30,
        ext = "mp4",
    )

    @Test
    fun androidVrPresentWinsOverVisionos() {
        val items = listOf(
            candidate("visionos", height = 1080),
            candidate("android_vr", height = 360),
            candidate("android", height = 720),
        )
        val winner = InAppYouTubeExtractor().pickBestForClient(items, listOf("android_vr", "visionos"))
        assertEquals("android_vr", winner?.client)
    }

    @Test
    fun onlyVisionosPresentPicksVisionos() {
        val items = listOf(
            candidate("visionos", height = 720),
            candidate("android", height = 1080),
        )
        val winner = InAppYouTubeExtractor().pickBestForClient(items, listOf("android_vr", "visionos"))
        assertEquals("visionos", winner?.client)
    }

    @Test
    fun neitherPreferredClientPresentFallsBackToPooledBest() {
        val items = listOf(
            candidate("android", height = 720),
            candidate("ios", height = 1080),
        )
        val winner = InAppYouTubeExtractor().pickBestForClient(items, listOf("android_vr", "visionos"))
        assertEquals("ios", winner?.client)
    }
}
