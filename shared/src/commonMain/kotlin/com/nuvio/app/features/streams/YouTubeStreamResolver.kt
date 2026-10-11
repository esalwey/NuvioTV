package com.nuvio.app.features.streams

import com.nuvio.app.features.trailer.TrailerPlaybackSource

/**
 * Makes streams that only carry a YouTube id ([StreamItem.ytId]) playable.
 *
 * The extraction itself is the trailer pipeline's ([com.nuvio.app.features.trailer.HeroTrailerResolver]).
 * What differs from a trailer is the pick: a stream is the full video and must have sound, so the
 * HLS master playlist (audio as a rendition) is preferred over a variant playlist that may be
 * video-only. When the extraction found a demuxed pair worth repackaging locally, the platform
 * does that instead (`TrailerLocalHLS` on tvOS), so no direct URL is named here.
 */
object YouTubeStreamResolver {
    fun watchUrl(videoId: String): String = "https://www.youtube.com/watch?v=$videoId"

    /** The watch URL for a stream that needs resolving, null for every other stream. */
    fun watchUrlToResolve(stream: StreamItem): String? =
        stream.youTubeIdToResolve?.let(::watchUrl)

    /**
     * The one URL to hand a player for [source], or null when the platform should repackage the
     * demuxed pair it carries (or has nothing to offer: the caller then falls back to the
     * source's own progressive/video URL).
     */
    fun preferredDirectUrl(source: TrailerPlaybackSource): String? {
        if (source.adaptiveVideo != null && source.adaptiveAudio != null) return null
        return source.masterPlaylistUrl?.trim()?.takeIf { it.isNotEmpty() }
    }
}
