package com.nuvio.app.features.streams

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.addons.httpRequestRaw
import com.nuvio.app.features.debrid.DebridTrackMetadata
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull

/** One HTTP range answer: [bytes] start at [offset]; [rangeHonored] false = the server sent the file from 0. */
class FetchedRange(
    val offset: Long,
    val bytes: ByteArray,
    val totalSize: Long?,
    val rangeHonored: Boolean = true,
)

/**
 * Fork (VERIFIED-LANGUAGES): lists a remote file's audio/subtitle tracks by reading just enough of
 * its container with HTTP Range requests — the head (256 KB), then whatever header the parser asks
 * for (Matroska `Tracks` found through the `SeekHead`, an MP4 `moov` after the media data), in 64 KB
 * blocks, at most [MAX_BYTES] and [TIMEOUT_MS] per file. Never used on a link that would make a
 * debrid service start a torrent download (see [TrackVerification.probeUrl]).
 */
object TrackProbe {
    const val HEAD_BYTES = 256 * 1024
    const val BLOCK_BYTES = 64 * 1024
    const val MAX_BYTES = 2 * 1024 * 1024
    const val TIMEOUT_MS = 6_000L
    const val MAX_ROUNDS = 24

    /** The tracks of [url], or null (not a Matroska/MP4 file, no range support, timeout, error). */
    suspend fun probe(url: String, headers: Map<String, String> = emptyMap()): List<ContainerTrack>? =
        withTimeoutOrNull(TIMEOUT_MS) {
            try {
                readTracks { offset, length -> fetchRange(url, headers, offset, length) }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                null
            }
        }

    /**
     * The fetch–parse loop. Inline so the same code runs with a suspending HTTP fetch and with a
     * plain in-memory one in tests.
     */
    inline fun readTracks(fetch: (offset: Long, length: Int) -> FetchedRange?): List<ContainerTrack>? {
        val first = fetch(0, HEAD_BYTES) ?: return null
        if (first.offset != 0L || first.bytes.isEmpty()) return null
        if (ContainerTrackParser.detect(first.bytes) == ContainerFormat.UNKNOWN) return null
        val source = ContainerByteSource(first.totalSize)
        source.add(0, first.bytes)
        val canSeek = first.rangeHonored
        var fetched = first.bytes.size.toLong()
        repeat(MAX_ROUNDS) {
            try {
                return ContainerTrackParser.parse(source)
            } catch (need: ContainerNeedsBytes) {
                if (!canSeek || fetched >= MAX_BYTES) return null
                val total = source.totalSize
                var length = maxOf(need.length, BLOCK_BYTES)
                if (total != null) length = minOf(length.toLong(), total - need.offset).toInt()
                if (length <= 0 || fetched + length > MAX_BYTES + BLOCK_BYTES) return null
                val range = fetch(need.offset, length) ?: return null
                if (range.offset != need.offset || range.bytes.isEmpty()) return null
                if (source.totalSize == null) source.totalSize = range.totalSize
                source.add(range.offset, range.bytes)
                fetched += range.bytes.size
                if (!source.contains(need.offset, minOf(need.length, range.bytes.size))) return null
            }
        }
        return null
    }

    private val CONTENT_RANGE_REGEX = Regex("bytes\\s+(\\d+)-(\\d+)/(\\d+|\\*)")

    private suspend fun fetchRange(url: String, headers: Map<String, String>, offset: Long, length: Int): FetchedRange? {
        val response = httpRequestRaw(
            method = "GET",
            url = url,
            headers = headers + mapOf(
                "Range" to "bytes=$offset-${offset + length - 1}",
                "Accept-Encoding" to "identity",
            ),
            body = "",
            maxResponseBodyBytes = length,
        )
        return when (response.status) {
            206 -> {
                val match = CONTENT_RANGE_REGEX.find(response.headers["content-range"].orEmpty())
                val start = match?.groupValues?.get(1)?.toLongOrNull() ?: offset
                FetchedRange(start, response.bodyBytes, match?.groupValues?.get(3)?.toLongOrNull())
            }
            200 -> if (offset == 0L) {
                FetchedRange(0, response.bodyBytes, response.headers["content-length"]?.toLongOrNull(), rangeHonored = false)
            } else {
                null
            }
            else -> null
        }
    }
}

/**
 * Fork (VERIFIED-LANGUAGES): which streams may be probed, and the probing itself (cache first,
 * then the debrid service's media info, then the file).
 */
object TrackVerification {

    /** Path parts of add-on links that resolve through a debrid service on request. */
    private val RESOLVER_PATH_PARTS = listOf(
        "/resolve/", "/playback/", "/streaming_provider/", "/stremthru/", "/realdebrid/", "/alldebrid/",
        "/torbox/", "/premiumize/", "/debridlink/", "/debrid-link/", "/easydebrid/", "/offcloud/", "/magnet",
    )

    /**
     * The link to probe for [stream], or null when probing it is not free: no direct link (a
     * torrent the app has not resolved), a debrid link that is not cached (asking for it would
     * start the download), or an add-on's debrid link whose cache state nobody stated. A link the
     * app itself resolved through the debrid service (it keeps the torrent's info hash), a cached
     * debrid link ([RD+], ⚡) and a plain HTTP link are fine.
     */
    fun probeUrl(stream: StreamItem, insight: StreamInsight): String? {
        val url = stream.playableDirectUrl?.trim() ?: return null
        if (!url.startsWith("http://", ignoreCase = true) && !url.startsWith("https://", ignoreCase = true)) return null
        if (insight.cacheState == StreamCacheState.NOT_CACHED) return null
        if (stream.debridCacheStatus?.state == StreamDebridCacheState.NOT_CACHED) return null
        val cached = insight.cacheState == StreamCacheState.CACHED ||
            stream.debridCacheStatus?.state == StreamDebridCacheState.CACHED
        if (cached) return url
        if (isResolverLink(url)) return null
        val resolvedByApp = !stream.infoHash.isNullOrBlank() || stream.clientResolve != null
        if (resolvedByApp) return url
        if (insight.debridService != null) return null
        return url
    }

    fun isResolverLink(url: String): Boolean {
        val path = url.substringBefore('?').substringAfter("://").substringAfter('/', "").lowercase()
        val withSlash = "/$path"
        return RESOLVER_PATH_PARTS.any { withSlash.contains(it) }
    }

    /** Cached tracks, else the debrid service's media info, else the file's header; recorded. */
    suspend fun verify(stream: StreamItem, url: String): VerifiedTrackRecord? {
        VerifiedTrackStore.lookup(stream)?.let { return it }
        val keys = VerifiedTrackKeys.forStream(stream)
        DebridTrackMetadata.tracksFor(url)?.let { tracks ->
            VerifiedTrackStore.recordKeys(keys, tracks, VerifiedTrackSource.DEBRID)?.let { return it }
        }
        val headers = sanitizePlaybackHeaders(stream.behaviorHints.proxyHeaders?.request)
        val tracks = TrackProbe.probe(url, headers) ?: return null
        return VerifiedTrackStore.recordKeys(keys, tracks, VerifiedTrackSource.PROBE)
    }
}

/**
 * Fork (VERIFIED-LANGUAGES): one stream list's probing — at most [MAX_CONCURRENT] files at a time,
 * a short pause after each, each stream once; [cancel] when the list goes away. Results come back on
 * a background thread through [onResult] (`id` = the caller's row identity).
 */
class TrackVerificationSession(
    private val onResult: (id: String, record: VerifiedTrackRecord) -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("TrackVerification"))
    private val permits = Semaphore(MAX_CONCURRENT)
    private val requested = HashSet<String>()
    private var cancelled = false

    /** Probes [stream] at [url] unless this session already did; false when skipped. */
    fun request(id: String, stream: StreamItem, url: String): Boolean {
        if (cancelled) return false
        val key = id + "\u001F" + url
        if (!requested.add(key)) return false
        scope.launch {
            permits.withPermit {
                val record = try {
                    TrackVerification.verify(stream, url)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    null
                }
                if (record != null) onResult(id, record)
                delay(PAUSE_MS)
            }
        }
        return true
    }

    fun wasRequested(id: String, url: String): Boolean = (id + "\u001F" + url) in requested

    fun cancel() {
        cancelled = true
        scope.cancel()
    }

    companion object {
        const val MAX_CONCURRENT = 2
        const val PAUSE_MS = 400L
    }
}
