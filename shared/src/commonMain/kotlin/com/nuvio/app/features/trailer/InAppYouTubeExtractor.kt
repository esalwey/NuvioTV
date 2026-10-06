package com.nuvio.app.features.trailer

import co.touchlab.kermit.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal const val TRAILER_EXTRACTOR_TAG = "InAppYouTubeExtractor"
internal const val TRAILER_REQUEST_TIMEOUT_MS = 20_000L

/**
 * Ceiling on a whole extraction. `internal` (it was file-private) so [HeroTrailerResolver] can name
 * it as the default for callers that don't impose a shorter deadline of their own — BUG-46/B4.
 */
internal const val TRAILER_EXTRACTOR_TIMEOUT_MS = 30_000L

// F3 (beta.16 hotfix): an ORDERED chain, not a single client. android_vr was observed
// LOGIN_REQUIRED on one network (08-27 rig logs) but works on others; visionos works where
// android_vr is gated, but its HLS manifests are what tripped the F1/F2 silent-playback
// regression in the first place. Neither client alone is safe to hardcode as the only
// separate-A/V source, so [pickBestForClient] walks this list in order — the first client
// that contributed ANY candidates wins outright — before falling back to pooling across all
// clients. Costs one extra innertube POST when the first client fails or is empty.
private val PREFERRED_SEPARATE_CLIENTS = listOf("android_vr", "visionos")

// Per-request bounds for the concurrent innertube/manifest batches (Codex 2026-08-29 P1):
// awaitAll() completes when the SLOWEST request does, and each HTTP call otherwise allows 20s
// while the inline card's whole extraction deadline is 15s — one stalled client would still time
// the caller out with healthy responses in hand. Bounding every request keeps the batch's worst
// case at the bound itself, safely inside the deadline. The two phases run SEQUENTIALLY and
// share that deadline with the watch-page fetch and the reachability probes (Codex 2026-08-29
// P1 round 5), so their bounds are budgeted to sum well under it: 5s + 4s = 9s worst case,
// leaving ~6s of the tvOS caller's 15s for the preamble and probes. A healthy endpoint answers
// in well under 2s; only a genuinely stalled one ever meets these bounds.
//
// Platform honesty (Codex 2026-08-29 P2, declined-documented): withTimeoutOrNull can only
// interrupt a COOPERATIVE call. On tvOS — the platform that ships this path — the Darwin Ktor
// client suspends and cancels properly, so the bound holds. On JVM/Android the actual is a
// blocking call the wrapper cannot interrupt, so the bound degrades to the platform's own ~20s
// ceiling — still strictly better than the pre-fix serial loop (ONE stall caps the whole
// concurrent batch, instead of stalls summing across clients). Plumbing a per-request timeout
// through the expect/actual HTTP seam is the follow-up if a mobile frontend ever ships this
// extractor.
private const val PLAYER_FETCH_TIMEOUT_MS = 5_000L
private const val MANIFEST_FETCH_TIMEOUT_MS = 4_000L

private val VIDEO_ID_REGEX = Regex("^[a-zA-Z0-9_-]{11}$")
private val API_KEY_REGEX = Regex("\"INNERTUBE_API_KEY\":\"([^\"]+)\"")
private val VISITOR_DATA_REGEX = Regex("\"VISITOR_DATA\":\"([^\"]+)\"")
private val QUALITY_LABEL_REGEX = Regex("(\\d{2,4})p")
private val CODECS_REGEX = Regex("codecs=\"([^\"]+)\"")

private data class YouTubeClient(
    val key: String,
    val id: String,
    val version: String,
    val userAgent: String,
    val context: JsonObject,
    val priority: Int,
)

private data class WatchConfig(
    val apiKey: String?,
    val visitorData: String?,
)

internal data class StreamCandidate(
    val client: String,
    val priority: Int,
    val url: String,
    val score: Double,
    val hasN: Boolean,
    val height: Int,
    val fps: Int,
    val ext: String,
    /** RFC 6381 codec string parsed from the mimeType (empty when absent). */
    val codecs: String = "",
    val bitrateBps: Long = 0,
    val width: Int = 0,
    val durationMs: Long = 0,
    /** Inclusive byte ranges for the fMP4 header (ftyp+moov) and sidx index; -1 when absent. */
    val initStart: Long = -1,
    val initEnd: Long = -1,
    val indexStart: Long = -1,
    val indexEnd: Long = -1,
    // Only meaningful for audio candidates: false means this format is an
    // alternate-language dub track, not the video's original/default audio.
    // Always true for video/progressive candidates, so it never affects them.
    val isDefaultAudioTrack: Boolean = true,
) {
    /** True when the stream is a demuxed fMP4 with the ranges local HLS repackaging needs. */
    val hasSegmentRanges: Boolean
        get() = initStart >= 0 && initEnd > initStart && indexStart > initEnd && indexEnd > indexStart
}

private data class ManifestBestVariant(
    val url: String,
    val width: Int,
    val height: Int,
    val bandwidth: Long,
    // Whether the selected variant is SDR (or unmarked = SDR per the HLS spec). Carried up so the
    // CROSS-manifest pick can prefer another client's SDR manifest over this one's HDR-only
    // fallback — filtering per-manifest alone still let a PQ-only manifest win on height
    // (Codex 2026-08-29 P2).
    val isSdr: Boolean,
)

internal data class ManifestCandidate(
    val client: String,
    val priority: Int,
    val manifestUrl: String,
    val selectedVariantUrl: String,
    val height: Int,
    val bandwidth: Long,
    val isSdr: Boolean = true,
)

internal data class TrailerRequestResponse(
    val ok: Boolean,
    val status: Int,
    val statusText: String,
    val url: String,
    val body: String,
)

/** One `#EXT-X-STREAM-INF` variant parsed out of an HLS master manifest, pre-selection. */
internal data class HlsVariantCandidate(
    val url: String,
    val width: Int,
    val height: Int,
    val bandwidth: Long,
    /** Raw VIDEO-RANGE attribute value, or null when the tag omits it. */
    val videoRange: String?,
    /**
     * Raw AUDIO attribute value (the `#EXT-X-MEDIA` group-id this variant's audio lives in), or
     * null when the tag omits it. F2 (beta.16 regression): a non-null group means the variant
     * URL itself is VIDEO-ONLY — the audio is a sibling rendition this extractor never parses —
     * so [resolvePlaybackUrl] must hand back the master manifest instead.
     */
    val audioGroup: String? = null,
)

/**
 * Picks the best HLS variant for the SABR-fallback path, which renders on a bare
 * (non-EDR) `AVPlayerLayer` by design — BUG-18/59 retired the alternative because a
 * plain sublayer never negotiates HDR. `TrailerHeroPlayerView.swift` still plays this
 * variant on that layer, so a PQ or HLG VIDEO-RANGE renders milky/washed-out even
 * though the same segment would look correct on an EDR-aware layer. A variant whose
 * VIDEO-RANGE is present and not "SDR" is therefore skipped; a variant with NO
 * VIDEO-RANGE attribute is SDR per the HLS spec and is kept. If the manifest only
 * offers HDR variants, filtering would leave nothing to play, so this falls back to
 * the unfiltered best pick — a washed-out trailer still beats no trailer. Height →
 * bandwidth → width ordering among the surviving candidates is unchanged from before
 * this guard existed. The local-HLS repack path already pins avc1/SDR for its own
 * reasons (see `bestAvcVideo` in [InAppYouTubeExtractor]); this brings the HLS
 * fallback picker in line with it.
 * Ref: docs/steven-batch-plan-2026-08-29.md Wave 4 item 3.
 */
internal fun selectBestHlsVariant(candidates: List<HlsVariantCandidate>): HlsVariantCandidate? {
    fun isSdr(candidate: HlsVariantCandidate): Boolean {
        val range = candidate.videoRange
        return range == null || range.equals("SDR", ignoreCase = true)
    }

    fun bestOf(pool: List<HlsVariantCandidate>): HlsVariantCandidate? {
        var best: HlsVariantCandidate? = null
        for (candidate in pool) {
            if (
                best == null ||
                candidate.height > best.height ||
                (candidate.height == best.height && candidate.bandwidth > best.bandwidth) ||
                (
                    candidate.height == best.height &&
                        candidate.bandwidth == best.bandwidth &&
                        candidate.width > best.width
                    )
            ) {
                best = candidate
            }
        }
        return best
    }

    val sdrOnly = candidates.filter(::isSdr)
    return bestOf(sdrOnly) ?: bestOf(candidates)
}

/**
 * F2 (beta.16 regression fix): resolves the playback URL for a picked HLS variant. A variant
 * with a separate AUDIO group ([HlsVariantCandidate.audioGroup] non-null) is video-only when
 * played directly — the audio lives in a sibling `#EXT-X-MEDIA` rendition this extractor never
 * parses, which is why trailers went silent once the visionos client swap made manifests (and
 * therefore this variant-only path) common. Handing AVPlayer the MASTER manifest instead keeps
 * the audio rendition — AVPlayer then does its own ABR over the master.
 *
 * Tradeoff, accepted: master-URL ABR may roam variants, including any HDR ones on an HDR
 * upload, which could reach the non-EDR `AVPlayerLayer` washed out (see [selectBestHlsVariant]).
 * Accepted because (a) F1 makes this path rare — a repack tie now wins over a pinned variant —
 * and (b) audio beats a possible washout; the SDR preference in [selectBestHlsVariant] still
 * shapes which manifest wins the cross-client pick, it just no longer pins AVPlayer to a single
 * segment set once a separate audio group is involved.
 */
internal fun resolvePlaybackUrl(winner: HlsVariantCandidate, masterUrl: String): String {
    return if (winner.audioGroup != null) masterUrl else winner.url
}

private val JSON = Json { ignoreUnknownKeys = true }

private val CLIENTS = listOf(
    // F3 (beta.16 hotfix): restored verbatim from pre-swap history (commit dc8281c2, the
    // parent of a6fb2aed which replaced this with visionos) — see PREFERRED_SEPARATE_CLIENTS
    // above for why both clients are kept.
    YouTubeClient(
        key = "android_vr",
        id = "28",
        version = "1.56.21",
        userAgent = "com.google.android.apps.youtube.vr.oculus/1.56.21 " +
            "(Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1) gzip",
        context = jsonObjectOf(
            "clientName" to "ANDROID_VR",
            "clientVersion" to "1.56.21",
            "deviceMake" to "Oculus",
            "deviceModel" to "Quest 3",
            "osName" to "Android",
            "osVersion" to "12",
            "platform" to "MOBILE",
            "androidSdkVersion" to 32,
            "hl" to "en",
            "gl" to "US",
        ),
        priority = 0,
    ),
    YouTubeClient(
        key = "visionos",
        id = "101",
        version = "1.02",
        userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        context = jsonObjectOf(
            "clientName" to "VISIONOS",
            "clientVersion" to "1.02",
            "deviceMake" to "Apple",
            "deviceModel" to "RealityDevice17,1",
            "osName" to "visionOS",
            "osVersion" to "26.5.23O471",
            "hl" to "en",
            "gl" to "US",
        ),
        priority = 1,
    ),
    YouTubeClient(
        key = "android",
        id = "3",
        version = "20.10.35",
        userAgent = "com.google.android.youtube/20.10.35 (Linux; U; Android 14; en_US) gzip",
        context = jsonObjectOf(
            "clientName" to "ANDROID",
            "clientVersion" to "20.10.35",
            "osName" to "Android",
            "osVersion" to "14",
            "platform" to "MOBILE",
            "androidSdkVersion" to 34,
            "hl" to "en",
            "gl" to "US",
        ),
        priority = 2,
    ),
    YouTubeClient(
        key = "ios",
        id = "5",
        version = "20.10.1",
        userAgent = "com.google.ios.youtube/20.10.1 (iPhone16,2; U; CPU iOS 17_4 like Mac OS X)",
        context = jsonObjectOf(
            "clientName" to "IOS",
            "clientVersion" to "20.10.1",
            "deviceModel" to "iPhone16,2",
            "osName" to "iPhone",
            "osVersion" to "17.4.0.21E219",
            "platform" to "MOBILE",
            "hl" to "en",
            "gl" to "US",
        ),
        priority = 3,
    ),
)

class InAppYouTubeExtractor {
    private val log = Logger.withTag(TRAILER_EXTRACTOR_TAG)

    /**
     * [timeoutMillis] lets a caller impose a deadline shorter than [TRAILER_EXTRACTOR_TIMEOUT_MS];
     * it can never *raise* the ceiling (BUG-46/B4 — the tvOS inline card gives up at 15s, and an
     * extraction that outlives the caller only competes with the next one). Defaulted, so the
     * mobile flavor resolver's existing single-argument call is unchanged.
     */
    suspend fun extractPlaybackSource(
        youtubeUrl: String,
        timeoutMillis: Long = TRAILER_EXTRACTOR_TIMEOUT_MS,
    ): TrailerPlaybackSource? = withContext(Dispatchers.Default) {
        if (youtubeUrl.isBlank()) return@withContext null

        runCatching {
            withTimeout(timeoutMillis.coerceIn(1L, TRAILER_EXTRACTOR_TIMEOUT_MS)) {
                extractPlaybackSourceInternal(youtubeUrl)
            }
        }.onFailure {
            log.w { "Trailer extractor failed for $youtubeUrl: ${it.message}" }
        }.getOrNull()
    }

    private suspend fun extractPlaybackSourceInternal(youtubeUrl: String): TrailerPlaybackSource? {
        val videoId = extractYouTubeVideoId(youtubeUrl) ?: return null

        val watchUrl = "https://www.youtube.com/watch?v=$videoId&hl=en"
        val watchResponse = TrailerExtractionPlatform.performRequest(
            url = watchUrl,
            method = "GET",
            headers = TrailerExtractionPlatform.defaultHeaders,
            body = null,
            timeoutMillis = TRAILER_REQUEST_TIMEOUT_MS,
        )
        if (!watchResponse.ok) {
            throw IllegalStateException("Failed to fetch watch page (${watchResponse.status})")
        }

        val watchConfig = getWatchConfig(watchResponse.body)
        val apiKey = watchConfig.apiKey
            ?: throw IllegalStateException("Unable to extract INNERTUBE_API_KEY")

        val progressive = mutableListOf<StreamCandidate>()
        val adaptiveVideo = mutableListOf<StreamCandidate>()
        val adaptiveAudio = mutableListOf<StreamCandidate>()
        val manifestUrls = mutableListOf<Triple<String, Int, String>>()

        // Fetch every client's player response CONCURRENTLY (Codex 2026-08-29 P1): the chain is
        // walked serially at PICK time, but fetching serially would let one stalled client — an
        // android_vr that hangs instead of failing fast — consume the inline card's 15s deadline
        // before visionos was ever asked, defeating the fallback the chain exists for. A failed
        // fetch contributes nothing (same as runCatching before); results are PROCESSED in
        // CLIENTS order so candidate-list contents stay deterministic.
        val fetchedResponses = coroutineScope {
            CLIENTS.map { client ->
                async {
                    withTimeoutOrNull(PLAYER_FETCH_TIMEOUT_MS) {
                        runCatching {
                            fetchPlayerResponse(
                                apiKey = apiKey,
                                videoId = videoId,
                                client = client,
                                visitorData = watchConfig.visitorData,
                            )
                        }.onFailure {
                            trailerDebugLog("client=${client.key} REQUEST FAILED: ${it.message?.take(80)}")
                        }.getOrNull()?.let { client to it }
                    }
                }
            }.awaitAll()
        }
        for ((client, playerResponse) in fetchedResponses.filterNotNull()) {
            run {
                val streamingData = playerResponse.objectValue("streamingData")
                if (streamingData == null) {
                    val status = playerResponse.objectValue("playabilityStatus")
                    trailerDebugLog(
                        "client=${client.key} NO streamingData " +
                            "(playability=${status?.stringValue("status")} " +
                            "reason=${status?.stringValue("reason")?.take(60)})"
                    )
                    return@run
                }
                val hlsManifestUrl = streamingData.stringValue("hlsManifestUrl")
                trailerDebugLog(
                    "client=${client.key} video=$videoId hls=${!hlsManifestUrl.isNullOrBlank()} " +
                        "formats=${streamingData.listObjectValue("formats").size} " +
                        "adaptive=${streamingData.listObjectValue("adaptiveFormats").size} " +
                        "sdKeys=${streamingData.keys.joinToString(",")}"
                )
                if (!hlsManifestUrl.isNullOrBlank()) {
                    manifestUrls += Triple(client.key, client.priority, hlsManifestUrl)
                }

                for (format in streamingData.listObjectValue("formats")) {
                    val url = format.stringValue("url") ?: continue
                    val mimeType = format.stringValue("mimeType").orEmpty()
                    if (!mimeType.contains("video/") && mimeType.isNotBlank()) continue

                    val height = (
                        format.numberValue("height")
                            ?: parseQualityLabel(format.stringValue("qualityLabel"))?.toDouble()
                            ?: 0.0
                        ).toInt()
                    val fps = (format.numberValue("fps") ?: 0.0).toInt()
                    val bitrate = format.numberValue("bitrate")
                        ?: format.numberValue("averageBitrate")
                        ?: 0.0

                    progressive += StreamCandidate(
                        client = client.key,
                        priority = client.priority,
                        url = url,
                        score = videoScore(height, fps, bitrate),
                        hasN = hasNParam(url),
                        height = height,
                        fps = fps,
                        ext = if (mimeType.contains("webm")) "webm" else "mp4",
                    )
                }

                for (format in streamingData.listObjectValue("adaptiveFormats")) {
                    val url = format.stringValue("url") ?: continue
                    val mimeType = format.stringValue("mimeType").orEmpty()
                    val hasVideo = mimeType.contains("video/")
                    val hasAudio = mimeType.contains("audio/") || mimeType.startsWith("audio/")

                    if (hasVideo) {
                        val height = (
                            format.numberValue("height")
                                ?: parseQualityLabel(format.stringValue("qualityLabel"))?.toDouble()
                                ?: 0.0
                            ).toInt()
                        val fps = (format.numberValue("fps") ?: 0.0).toInt()
                        val bitrate = format.numberValue("bitrate")
                            ?: format.numberValue("averageBitrate")
                            ?: 0.0

                        adaptiveVideo += StreamCandidate(
                            client = client.key,
                            priority = client.priority,
                            url = url,
                            score = videoScore(height, fps, bitrate),
                            hasN = hasNParam(url),
                            height = height,
                            fps = fps,
                            ext = if (mimeType.contains("webm")) "webm" else "mp4",
                            codecs = parseCodecs(mimeType),
                            bitrateBps = bitrate.toLong(),
                            width = (format.numberValue("width") ?: 0.0).toInt(),
                            durationMs = format.stringValue("approxDurationMs")?.toLongOrNull() ?: 0,
                            initStart = rangeValue(format, "initRange", "start"),
                            initEnd = rangeValue(format, "initRange", "end"),
                            indexStart = rangeValue(format, "indexRange", "start"),
                            indexEnd = rangeValue(format, "indexRange", "end"),
                        )
                    } else if (hasAudio) {
                        val bitrate = format.numberValue("bitrate")
                            ?: format.numberValue("averageBitrate")
                            ?: 0.0
                        val audioSampleRate = format.numberValue("audioSampleRate") ?: 0.0
                        // Multi-language uploads (common for major-studio trailers)
                        // expose each dub as a separate adaptiveFormats entry with an
                        // audioTrack.audioIsDefault flag. Formats with no audioTrack
                        // are the only audio for that video, so treat them as default.
                        val isDefaultAudioTrack = format.objectValue("audioTrack")
                            ?.booleanValue("audioIsDefault") ?: true

                        adaptiveAudio += StreamCandidate(
                            client = client.key,
                            priority = client.priority,
                            url = url,
                            score = audioScore(bitrate, audioSampleRate),
                            hasN = hasNParam(url),
                            height = 0,
                            fps = 0,
                            ext = if (mimeType.contains("webm")) "webm" else "m4a",
                            codecs = parseCodecs(mimeType),
                            bitrateBps = bitrate.toLong(),
                            durationMs = format.stringValue("approxDurationMs")?.toLongOrNull() ?: 0,
                            initStart = rangeValue(format, "initRange", "start"),
                            initEnd = rangeValue(format, "initRange", "end"),
                            indexStart = rangeValue(format, "indexRange", "start"),
                            indexEnd = rangeValue(format, "indexRange", "end"),
                            isDefaultAudioTrack = isDefaultAudioTrack,
                        )
                    }
                }
            }
        }

        if (manifestUrls.isEmpty() && progressive.isEmpty() && adaptiveVideo.isEmpty() && adaptiveAudio.isEmpty()) {
            return null
        }

        // Manifest GETs are fetched/parsed CONCURRENTLY for the same reason the player POSTs are
        // (Codex 2026-08-29 P2): with two preferred clients both returning manifests, a stalled
        // android_vr manifest GET at the front of a serial loop would eat the inline card's
        // deadline before visionos's healthy manifest was ever read. Results are REDUCED in the
        // original list order so the pick stays deterministic.
        val parsedManifests = coroutineScope {
            manifestUrls.map { (clientKey, priority, manifestUrl) ->
                async {
                    val variant = withTimeoutOrNull(MANIFEST_FETCH_TIMEOUT_MS) {
                        runCatching { parseHlsManifest(manifestUrl) }
                            .onFailure { trailerDebugLog("manifest client=$clientKey FETCH/PARSE FAILED: ${it.message?.take(80)}") }
                            .getOrNull()
                    }
                    Triple(clientKey, priority, manifestUrl) to variant
                }
            }.awaitAll()
        }
        var bestManifest: ManifestCandidate? = null
        for ((meta, variant) in parsedManifests) {
            val (clientKey, priority, manifestUrl) = meta
            run {
                if (variant == null) {
                    trailerDebugLog("manifest client=$clientKey parsed but no variants")
                    return@run
                }
                trailerDebugLog("manifest client=$clientKey top variant ${variant.width}x${variant.height}")
                val candidate = ManifestCandidate(
                    client = clientKey,
                    priority = priority,
                    manifestUrl = manifestUrl,
                    selectedVariantUrl = variant.url,
                    height = variant.height,
                    bandwidth = variant.bandwidth,
                    isSdr = variant.isSdr,
                )
                // SDR dominates the cross-manifest pick: a client whose manifest fell back to an
                // HDR-only variant must lose to any client offering SDR, whatever the heights —
                // per-manifest filtering alone still let a PQ-only manifest win here on height
                // and reach the non-EDR AVPlayerLayer washed out (Codex 2026-08-29 P2).
                if (
                    bestManifest == null ||
                    (candidate.isSdr && !bestManifest.isSdr) ||
                    (candidate.isSdr == bestManifest.isSdr && (
                        candidate.height > bestManifest.height ||
                        (candidate.height == bestManifest.height && candidate.bandwidth > bestManifest.bandwidth)
                    ))
                ) {
                    bestManifest = candidate
                }
            }
        }

        val bestProgressive = sortCandidates(progressive).firstOrNull()
        trailerDebugLog(
            "selection: manifest=${bestManifest?.height ?: "none"} " +
                "progressive=${bestProgressive?.height ?: "none"} " +
                "(manifests collected=${manifestUrls.size})"
        )
        val bestVideo = pickBestForClient(adaptiveVideo, PREFERRED_SEPARATE_CLIENTS)
        val bestAudio = pickBestForClient(adaptiveAudio, PREFERRED_SEPARATE_CLIENTS)

        // AVPlayer-decodable demuxed pair for local HLS repackaging (SABR fallback): H.264 fMP4
        // video + AAC fMP4 audio, both with init/index ranges, from ONE client so the pair shares
        // a CDN session shape. The pair is chosen as a PAIR (Codex 2026-08-29 P2 round 6): the
        // first preferred client offering BOTH tracks wins — picking the video independently let
        // an android_vr with AVC-but-no-M4A poison the pair and knock repack out while visionos
        // held a complete one. Falls back to any single client (by candidate priority) that has
        // both.
        val repackVideos = adaptiveVideo.filter { it.ext == "mp4" && it.codecs.startsWith("avc1") && it.hasSegmentRanges }
        val repackAudios = adaptiveAudio.filter { it.ext == "m4a" && it.codecs.startsWith("mp4a") && it.hasSegmentRanges }
        val pairClient = (PREFERRED_SEPARATE_CLIENTS + (repackVideos.map { it.client } + repackAudios.map { it.client }).distinct())
            .firstOrNull { key -> repackVideos.any { it.client == key } && repackAudios.any { it.client == key } }
        val bestAvcVideo = pairClient?.let { key -> sortCandidates(repackVideos.filter { it.client == key }).firstOrNull() }
        val bestM4aAudio = pairClient?.let { key -> sortCandidates(repackAudios.filter { it.client == key }).firstOrNull() }
        trailerDebugLog(
            "repack candidates: avcVideo=${bestAvcVideo?.let { "${it.height}p ${it.codecs} (${it.client})" } ?: "none"} " +
                "m4aAudio=${bestM4aAudio?.let { "${it.codecs} (${it.client})" } ?: "none"}"
        )

        // BUG-81: stamp the video id on the way out rather than threading it through the
        // expect/actual `buildPlaybackSource` signature — every platform actual would have to take
        // a parameter it does not use, and the value is the same on all of them. See
        // `TrailerPlaybackSource.videoId` for what the tvOS letterbox probe does with it.
        return TrailerExtractionPlatform.buildPlaybackSource(
            bestManifest = bestManifest,
            bestProgressive = bestProgressive,
            bestVideo = bestVideo,
            bestAudio = bestAudio,
            bestAvcVideo = bestAvcVideo,
            bestM4aAudio = bestM4aAudio,
        )?.copy(videoId = videoId)
    }

    private suspend fun fetchPlayerResponse(
        apiKey: String,
        videoId: String,
        client: YouTubeClient,
        visitorData: String?,
    ): JsonObject {
        val endpoint = "https://www.youtube.com/youtubei/v1/player?key=${encodeUrlComponent(apiKey)}"

        val headers = buildMap {
            putAll(TrailerExtractionPlatform.defaultHeaders)
            put("content-type", "application/json")
            put("origin", "https://www.youtube.com")
            put("x-youtube-client-name", client.id)
            put("x-youtube-client-version", client.version)
            put("user-agent", client.userAgent)
            if (!visitorData.isNullOrBlank()) put("x-goog-visitor-id", visitorData)
        }

        val payload = jsonObjectOf(
            "videoId" to videoId,
            "contentCheckOk" to true,
            "racyCheckOk" to true,
            "context" to jsonObjectOf("client" to client.context),
            "playbackContext" to jsonObjectOf(
                "contentPlaybackContext" to jsonObjectOf("html5Preference" to "HTML5_PREF_WANTS"),
            ),
        )

        val response = TrailerExtractionPlatform.performRequest(
            url = endpoint,
            method = "POST",
            headers = headers,
            body = payload.toString(),
            timeoutMillis = TRAILER_REQUEST_TIMEOUT_MS,
        )

        if (!response.ok) {
            val preview = response.body.take(200)
            throw IllegalStateException("player API ${client.key} failed (${response.status}): $preview")
        }

        val parsed = JSON.parseToJsonElement(response.body)
        return parsed as? JsonObject ?: JsonObject(emptyMap())
    }

    private suspend fun parseHlsManifest(manifestUrl: String): ManifestBestVariant? {
        val response = TrailerExtractionPlatform.performRequest(
            url = manifestUrl,
            method = "GET",
            headers = TrailerExtractionPlatform.defaultHeaders,
            body = null,
            timeoutMillis = TRAILER_REQUEST_TIMEOUT_MS,
        )
        if (!response.ok) {
            throw IllegalStateException("Failed to fetch HLS manifest (${response.status})")
        }

        val lines = response.body
            .lineSequence()
            .map { it.trim() }
            .filter { it.isNotBlank() }
            .toList()

        val candidates = mutableListOf<HlsVariantCandidate>()
        for (index in lines.indices) {
            val line = lines[index]
            if (!line.startsWith("#EXT-X-STREAM-INF:")) continue

            val attrs = parseHlsAttributeList(line)
            val nextLine = lines.getOrNull(index + 1) ?: continue
            if (nextLine.startsWith("#")) continue

            val resolution = attrs["RESOLUTION"].orEmpty()
            val (width, height) = parseResolution(resolution)
            val bandwidth = attrs["BANDWIDTH"]?.toLongOrNull() ?: 0L

            candidates += HlsVariantCandidate(
                url = absolutizeUrl(manifestUrl, nextLine),
                width = width,
                height = height,
                bandwidth = bandwidth,
                videoRange = attrs["VIDEO-RANGE"],
                // F2: the variant's AUDIO attribute names the #EXT-X-MEDIA group its audio
                // lives in — non-null means the variant URL itself is video-only.
                audioGroup = attrs["AUDIO"],
            )
        }

        // See selectBestHlsVariant's kdoc: skips HDR (PQ/HLG) variants for the non-EDR
        // AVPlayerLayer fallback, falling back to the unfiltered pick if that leaves nothing.
        val bestVariant = selectBestHlsVariant(candidates) ?: return null
        val bestVariantIsSdr = bestVariant.videoRange == null ||
            bestVariant.videoRange.equals("SDR", ignoreCase = true)

        return ManifestBestVariant(
            // F2: resolvePlaybackUrl swaps in the master manifest URL when the winning variant
            // has a separate audio group, so AVPlayer keeps the audio rendition. Height/bandwidth
            // metadata below still describes the picked variant, not the master.
            url = resolvePlaybackUrl(bestVariant, manifestUrl),
            width = bestVariant.width,
            height = bestVariant.height,
            bandwidth = bestVariant.bandwidth,
            isSdr = bestVariantIsSdr,
        )
    }

    private fun getWatchConfig(html: String): WatchConfig {
        val apiKey = API_KEY_REGEX.find(html)?.groupValues?.getOrNull(1)
        val visitorData = VISITOR_DATA_REGEX.find(html)?.groupValues?.getOrNull(1)
        return WatchConfig(apiKey = apiKey, visitorData = visitorData)
    }

    /** `internal` (was `private`) so tests can pin AUDIO/VIDEO-RANGE attribute parsing directly. */
    internal fun parseHlsAttributeList(line: String): Map<String, String> {
        val index = line.indexOf(':')
        if (index == -1) return emptyMap()

        val raw = line.substring(index + 1)
        val out = LinkedHashMap<String, String>()
        val key = StringBuilder()
        val value = StringBuilder()
        var inKey = true
        var inQuote = false

        for (ch in raw) {
            if (inKey) {
                if (ch == '=') {
                    inKey = false
                } else {
                    key.append(ch)
                }
                continue
            }

            if (ch == '"') {
                inQuote = !inQuote
                continue
            }

            if (ch == ',' && !inQuote) {
                val parsedKey = key.toString().trim()
                if (parsedKey.isNotEmpty()) {
                    out[parsedKey] = value.toString().trim()
                }
                key.clear()
                value.clear()
                inKey = true
                continue
            }

            value.append(ch)
        }

        val lastKey = key.toString().trim()
        if (lastKey.isNotEmpty()) {
            out[lastKey] = value.toString().trim()
        }

        return out
    }

    private fun parseResolution(raw: String): Pair<Int, Int> {
        val parts = raw.split('x')
        if (parts.size != 2) return 0 to 0
        val width = parts[0].toIntOrNull() ?: 0
        val height = parts[1].toIntOrNull() ?: 0
        return width to height
    }

    private fun parseQualityLabel(label: String?): Int? {
        if (label.isNullOrBlank()) return null
        return QUALITY_LABEL_REGEX.find(label)?.groupValues?.getOrNull(1)?.toIntOrNull()
    }

    private fun parseCodecs(mimeType: String): String {
        return CODECS_REGEX.find(mimeType)?.groupValues?.getOrNull(1)?.trim().orEmpty()
    }

    /** innertube serves range bounds as strings: `"initRange": {"start": "0", "end": "741"}`. */
    private fun rangeValue(format: JsonObject, rangeKey: String, boundKey: String): Long {
        return format.objectValue(rangeKey)?.stringValue(boundKey)?.toLongOrNull() ?: -1
    }

    private fun hasNParam(url: String): Boolean {
        return parseUrl(url)?.query?.get("n")?.firstOrNull()?.isNotBlank() == true
    }

    private fun videoScore(height: Int, fps: Int, bitrate: Double): Double {
        return height * 1_000_000_000.0 + fps * 1_000_000.0 + bitrate
    }

    private fun audioScore(bitrate: Double, audioSampleRate: Double): Double {
        return bitrate * 1_000_000.0 + audioSampleRate
    }

    internal fun sortCandidates(items: List<StreamCandidate>): List<StreamCandidate> {
        return items.sortedWith(
            compareBy<StreamCandidate> { if (it.isDefaultAudioTrack) 0 else 1 }
                .thenByDescending { it.score }
                .thenBy { if (it.hasN) 1 else 0 }
                .thenBy { containerPreference(it.ext) }
                .thenBy { it.priority },
        )
    }

    /**
     * Picks the best candidate from [items], preferring each client key in [clientKeys] in
     * order — the first client that CONTRIBUTED any candidate wins outright, even if a
     * later-listed client's candidates would score higher; only when NONE of [clientKeys]
     * contributed anything does this fall back to pooling the best across all clients.
     * F3 (beta.16 hotfix): with a single hardcoded preferred client, that client being gated
     * (LOGIN_REQUIRED, etc.) on some networks was a single point of failure for the whole
     * separate-A/V path; an ordered chain gives it a fallback. `internal` so it's directly
     * testable with constructed [StreamCandidate]s.
     */
    internal fun pickBestForClient(items: List<StreamCandidate>, clientKeys: List<String>): StreamCandidate? {
        for (clientKey in clientKeys) {
            val sameClient = items.filter { it.client == clientKey }
            if (sameClient.isNotEmpty()) {
                return sortCandidates(sameClient).firstOrNull()
            }
        }
        return sortCandidates(items).firstOrNull()
    }

    /** Single-client convenience overload — e.g. pairing audio with one specific video's client. */
    internal fun pickBestForClient(items: List<StreamCandidate>, clientKey: String): StreamCandidate? {
        return pickBestForClient(items, listOf(clientKey))
    }

    private fun containerPreference(ext: String): Int {
        return when (ext.lowercase()) {
            "mp4", "m4a" -> 0
            "webm" -> 1
            else -> 2
        }
    }

    private fun absolutizeUrl(baseUrl: String, maybeRelative: String): String {
        if (maybeRelative.startsWith("http://") || maybeRelative.startsWith("https://")) {
            return maybeRelative
        }
        if (maybeRelative.startsWith('/')) {
            val scheme = baseUrl.substringBefore("://", "https")
            val host = baseUrl.substringAfter("://", "").substringBefore('/')
            return if (host.isNotBlank()) "$scheme://$host$maybeRelative" else maybeRelative
        }
        val baseDir = baseUrl.substringBeforeLast('/', missingDelimiterValue = baseUrl)
        return "$baseDir/$maybeRelative"
    }

    private fun encodeUrlComponent(value: String): String {
        return value
            .replace("%", "%25")
            .replace("+", "%2B")
            .replace(" ", "%20")
            .replace("&", "%26")
            .replace("=", "%3D")
    }
}

private data class ParsedUrl(
    val host: String,
    val pathSegments: List<String>,
    val query: Map<String, List<String>>,
)

/**
 * The 11-character YouTube video id named by [input] — a bare id, a `watch?v=` URL, a `youtu.be`
 * short link, or an `embed`/`shorts`/`live` path — or null when [input] names none. Top-level and
 * internal (was a private member of [InAppYouTubeExtractor]) so it can be unit-tested: BUG-81
 * threads its result through [TrailerPlaybackSource.videoId] as the cross-launch identity of a
 * trailer, so a parse that silently returned null would quietly disable persisted-zoom
 * verification for that title on tvOS.
 */
internal fun extractYouTubeVideoId(input: String): String? {
    val trimmed = input.trim()
    if (VIDEO_ID_REGEX.matches(trimmed)) return trimmed

    val parsed = parseUrl(trimmed) ?: return null

    if (parsed.host.endsWith("youtu.be")) {
        val id = parsed.pathSegments.firstOrNull()
        if (!id.isNullOrBlank() && VIDEO_ID_REGEX.matches(id)) {
            return id
        }
    }

    val queryId = parsed.query["v"]?.firstOrNull()
    if (!queryId.isNullOrBlank() && VIDEO_ID_REGEX.matches(queryId)) {
        return queryId
    }

    if (parsed.pathSegments.size >= 2) {
        val first = parsed.pathSegments[0]
        val second = parsed.pathSegments[1]
        if ((first == "embed" || first == "shorts" || first == "live") && VIDEO_ID_REGEX.matches(second)) {
            return second
        }
    }

    return null
}

private fun parseUrl(input: String): ParsedUrl? {
    val trimmed = input.trim()
    if (trimmed.isBlank()) return null

    val normalized = if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
        trimmed
    } else {
        "https://$trimmed"
    }

    val withoutFragment = normalized.substringBefore('#')
    val withoutScheme = withoutFragment.substringAfter("://", withoutFragment)
    val host = withoutScheme.substringBefore('/').substringBefore('?').lowercase()
    if (host.isBlank()) return null

    val pathAndQuery = withoutScheme.removePrefix(host)
    val path = when {
        pathAndQuery.startsWith("/") -> pathAndQuery.substringBefore('?')
        pathAndQuery.startsWith("?") || pathAndQuery.isBlank() -> "/"
        else -> "/${pathAndQuery.substringBefore('?')}"
    }
    val queryString = withoutFragment.substringAfter('?', "")
    val query = LinkedHashMap<String, MutableList<String>>()
    queryString.split('&')
        .filter { it.isNotBlank() }
        .forEach { pair ->
            val key = pair.substringBefore('=').trim()
            if (key.isBlank()) return@forEach
            val value = pair.substringAfter('=', "")
            query.getOrPut(key) { mutableListOf() }.add(value)
        }

    return ParsedUrl(
        host = host,
        pathSegments = path.trim('/').split('/').filter { it.isNotBlank() },
        query = query,
    )
}

private fun JsonObject.objectValue(key: String): JsonObject? {
    return this[key] as? JsonObject
}

private fun JsonObject.listObjectValue(key: String): List<JsonObject> {
    return (this[key] as? JsonArray)
        ?.mapNotNull { it as? JsonObject }
        .orEmpty()
}

private fun JsonObject.stringValue(key: String): String? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    return if (primitive.isString) primitive.content else primitive.toString().trim('"')
}

private fun JsonObject.numberValue(key: String): Double? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    return primitive.toString().trim('"').toDoubleOrNull()
}

private fun JsonObject.booleanValue(key: String): Boolean? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    return primitive.content.toBooleanStrictOrNull()
}

private fun jsonObjectOf(vararg pairs: Pair<String, Any?>): JsonObject {
    val mapped = LinkedHashMap<String, JsonElement>()
    pairs.forEach { (key, value) ->
        value?.let { mapped[key] = toJsonElement(it) }
    }
    return JsonObject(mapped)
}

private fun toJsonElement(value: Any): JsonElement {
    return when (value) {
        is JsonElement -> value
        is JsonObject -> value
        is String -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Int -> JsonPrimitive(value)
        is Long -> JsonPrimitive(value)
        is Double -> JsonPrimitive(value)
        is Float -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value.toDouble())
        is Map<*, *> -> {
            val map = LinkedHashMap<String, JsonElement>()
            value.forEach { (key, nestedValue) ->
                val parsedKey = key?.toString() ?: return@forEach
                if (nestedValue != null) {
                    map[parsedKey] = toJsonElement(nestedValue)
                }
            }
            JsonObject(map)
        }
        is List<*> -> JsonArray(value.mapNotNull { it?.let(::toJsonElement) })
        else -> JsonPrimitive(value.toString())
    }
}