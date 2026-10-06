package com.nuvio.app.features.downloads

/**
 * Installs the composeApp [DownloadsLiveStatusPlatform] (its Android actual builds progress
 * notifications with app resources) behind the shared [DownloadsLiveStatusNotifier] seam.
 * Call [install] once at app startup.
 */
object DownloadsLiveStatusAdapter {
    fun install() {
        DownloadsLiveStatusProvider.notifier = DownloadsLiveStatusNotifier { items ->
            DownloadsLiveStatusPlatform.onItemsChanged(items)
        }
    }
}
