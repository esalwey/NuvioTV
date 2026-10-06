package com.nuvio.app.features.downloads

import kotlin.concurrent.Volatile

/**
 * Compose-free seam for surfacing live download status to the platform (e.g. Android progress
 * notifications). The real implementation lives in composeApp because its Android actual builds
 * notifications with app resources. Default is a no-op (e.g. tvOS today).
 */
fun interface DownloadsLiveStatusNotifier {
    fun onItemsChanged(items: List<DownloadItem>)
}

/** Process-wide holder for the active [DownloadsLiveStatusNotifier]. composeApp installs the real one. */
object DownloadsLiveStatusProvider {
    @Volatile
    var notifier: DownloadsLiveStatusNotifier = DownloadsLiveStatusNotifier { }
}
