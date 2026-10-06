package com.nuvio.app.features.trailer

/**
 * tvOS-facing entry point for resolving a YouTube trailer URL into a directly-playable
 * [TrailerPlaybackSource] (video + optional audio), via the pure-Kotlin [InAppYouTubeExtractor].
 *
 * On mobile this resolution lives behind the flavor-gated `TrailerPlaybackResolver` (the App Store
 * flavor returns null). tvOS is a "full" experience with no App Store flavor, so it calls this
 * directly. Swift consumes the `suspend fun` as a completion-handler method:
 * `HeroTrailerResolver.shared.resolveYouTube(youtubeUrl:) { source, error in ... }`.
 *
 * Fails soft — any extraction error returns null so the caller can fall back to the static backdrop.
 */
object HeroTrailerResolver {
    private val extractor by lazy { InAppYouTubeExtractor() }

    suspend fun resolveYouTube(youtubeUrl: String): TrailerPlaybackSource? =
        resolveYouTube(youtubeUrl, TRAILER_EXTRACTOR_TIMEOUT_MS)

    /**
     * BUG-46/B4: same resolution, but bounded by the *caller's* deadline.
     *
     * The tvOS inline card gives up on an extraction after 15s (its own `ResumeLatch` deadline —
     * Kotlin completion handlers can't be cancelled from Swift, so the loser is simply dropped).
     * With the extractor running to its own 30s ceiling, that left an orphan extraction working for
     * another 15s: still holding connections, still scheduled, and overlapping whatever the next
     * card started. Passing the deadline down makes the work stop when the caller stops caring.
     *
     * Deliberately an OVERLOAD rather than a default parameter on the single-argument form above:
     * Kotlin/Native does not export default arguments, so adding one would rename the Objective-C
     * selector this is already called through (`resolveYouTube(youtubeUrl:completionHandler:)`,
     * `DetailViewModel.swift`) and break every existing Swift call site. Two functions keep the old
     * one byte-compatible.
     */
    suspend fun resolveYouTube(youtubeUrl: String, timeoutMillis: Long): TrailerPlaybackSource? {
        if (youtubeUrl.isBlank()) return null
        return runCatching { extractor.extractPlaybackSource(youtubeUrl, timeoutMillis) }.getOrNull()
    }
}
