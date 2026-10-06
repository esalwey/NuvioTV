package com.nuvio.app.features.player

import kotlin.concurrent.Volatile

/**
 * Compose-free seam for platform-specific subtitle caching used by the external-player
 * launch flow. The real implementation ([SubtitleCacheProvider], an `expect`/`actual`
 * object) lives in composeApp because its Android actual depends on app-level resources
 * and content URIs; the shared module talks to it only through this interface.
 *
 * Default is a no-op that returns the subtitles unchanged (the iOS/tvOS behaviour —
 * players accept remote subtitle URLs directly), so a target with no adapter installed
 * (e.g. tvOS today) still works with zero wiring.
 */
fun interface ExternalSubtitleCache {
    /**
     * Caches subtitle files locally and returns an updated [SubtitleInput] list, or null
     * if caching fails. Implementations may return the input unchanged when no caching is
     * needed.
     */
    suspend fun cacheForExternalPlayer(subtitles: List<SubtitleInput>): List<SubtitleInput>?
}

/**
 * Process-wide holder for the active [ExternalSubtitleCache]. composeApp installs an
 * adapter backed by [SubtitleCacheProvider] at startup; other targets leave the no-op.
 */
object ExternalSubtitleCacheProvider {
    @Volatile
    var cache: ExternalSubtitleCache = ExternalSubtitleCache { it }
}
