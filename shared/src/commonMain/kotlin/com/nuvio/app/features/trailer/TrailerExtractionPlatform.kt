package com.nuvio.app.features.trailer

/**
 * Platform HTTP + URL plumbing for [InAppYouTubeExtractor], relocated into `:shared` so the tvOS
 * target can resolve trailers too. The iOS/tvOS actual uses ktor-Darwin; the Android actual uses
 * OkHttp. (In composeApp this used to be a per-flavor `internal object`; here it is a proper
 * `expect`/`actual` because `:shared` has no flavor source sets.)
 */
internal expect object TrailerExtractionPlatform {
    val defaultHeaders: Map<String, String>

    suspend fun performRequest(
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String?,
        timeoutMillis: Long,
    ): TrailerRequestResponse

    suspend fun buildPlaybackSource(
        bestManifest: ManifestCandidate?,
        bestProgressive: StreamCandidate?,
        bestVideo: StreamCandidate?,
        bestAudio: StreamCandidate?,
        /** AVPlayer-decodable demuxed fMP4 pair for tvOS local HLS repackaging; Android ignores. */
        bestAvcVideo: StreamCandidate?,
        bestM4aAudio: StreamCandidate?,
    ): TrailerPlaybackSource?
}

/**
 * Step-specific extraction diagnostics (UX-4c): one terse line per decision point so a device
 * `log show` names the exact step that degraded a trailer to the 360p progressive fallback.
 * NSLog-backed on Apple, logcat on Android.
 */
internal expect fun trailerDebugLog(message: String)
