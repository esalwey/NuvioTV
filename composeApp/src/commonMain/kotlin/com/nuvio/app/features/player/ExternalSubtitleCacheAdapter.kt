package com.nuvio.app.features.player

/**
 * Installs the composeApp [SubtitleCacheProvider] (an `expect`/`actual` object whose
 * Android actual needs app resources and content URIs) behind the shared
 * [ExternalSubtitleCache] seam. Call [install] once at app startup.
 */
object ExternalSubtitleCacheAdapter {
    fun install() {
        ExternalSubtitleCacheProvider.cache = ExternalSubtitleCache { subtitles ->
            SubtitleCacheProvider.cacheForExternalPlayer(subtitles)
        }
    }
}
