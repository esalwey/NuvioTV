package com.nuvio.app.features.trailer

/**
 * One demuxed fMP4 adaptive stream (video-only or audio-only) with the byte ranges AVPlayer-side
 * repackaging needs: `initRange` covers the ftyp+moov header, `indexRange` the sidx segment index.
 * tvOS turns a (video, audio) pair of these into a local byte-range HLS playlist when YouTube's
 * SABR rollout leaves no hlsManifestUrl (see TrailerLocalHLS.swift). Ranges are inclusive, as in
 * the innertube response.
 */
data class TrailerAdaptiveTrack(
    val url: String,
    /** RFC 6381 codec string from the mimeType, e.g. `avc1.640028` / `mp4a.40.2`. */
    val codecs: String,
    val bitrate: Long,
    val width: Int,
    val height: Int,
    val initStart: Long,
    val initEnd: Long,
    val indexStart: Long,
    val indexEnd: Long,
    val durationMs: Long,
)

data class TrailerPlaybackSource(
    val videoUrl: String,
    val audioUrl: String? = null,
    /**
     * A progressive H.264/MP4 (or HLS) URL suitable for native `AVPlayer` playback. tvOS plays this
     * (AVPlayer coexists with SwiftUI; libmpv/Vulkan does not). Null when only adaptive VP9/AV1 is
     * available. Mobile ignores it and uses [videoUrl] for its libmpv player.
     */
    val progressiveUrl: String? = null,
    /**
     * AVPlayer-decodable demuxed pair (H.264 fMP4 + AAC fMP4) that beats [progressiveUrl]'s
     * resolution — set only when local HLS repackaging is worth attempting (UX-4c SABR follow-up).
     * tvOS-only; mobile ignores both.
     */
    val adaptiveVideo: TrailerAdaptiveTrack? = null,
    val adaptiveAudio: TrailerAdaptiveTrack? = null,
    /**
     * The YouTube video id this source was extracted from (`rNZ0xKaCdus`-shaped), or null when the
     * source did not come from [InAppYouTubeExtractor].
     *
     * BUG-81: the only identifier of "which trailer is this" that survives a re-extraction. Every
     * other candidate the tvOS letterbox probe tried is per-request plumbing minted by the CDN —
     * the googlevideo `id=` query item rotates on every extraction of the same video (sim soak,
     * 2026-09-04: three extractions of one pinned video produced three unrelated `id=` values), the
     * host rotates, and the itag names a format-ladder rung the extractor may pick differently each
     * time. Swift keys the persisted-zoom VERIFY comparison on this
     * (`TrailerLetterboxProbe.streamIdentity(of:videoId:)` in `TrailerHeroPlayerView.swift`), so a
     * zoom measured in one launch can be confirmed or corrected in the next instead of being
     * re-measured cold every time.
     *
     * Nullable so the non-YouTube constructor call sites (and every platform actual of
     * `TrailerExtractionPlatform.buildPlaybackSource`, which has no video id in scope) stay
     * unchanged; the extractor stamps it on the way out.
     */
    val videoId: String? = null,
)
