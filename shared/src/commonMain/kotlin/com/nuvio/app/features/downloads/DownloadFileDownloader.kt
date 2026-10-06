package com.nuvio.app.features.downloads

import kotlin.concurrent.Volatile

/** Request to download a single file. Pure data, shared by the seam and its platform impls. */
data class DownloadPlatformRequest(
    val sourceUrl: String,
    val sourceHeaders: Map<String, String>,
    val destinationFileName: String,
)

/** Handle to a running download; cancelling stops it. */
interface DownloadsTaskHandle {
    fun cancel()
}

/**
 * Compose-free seam for platform-specific file downloading. The real implementation lives in
 * composeApp (its Android actual posts notifications and uses app resources, so it cannot move
 * to `:shared`). The shared module talks to it only through this interface.
 *
 * Default is a no-op (downloads unsupported) so a target with no adapter installed — e.g. tvOS
 * today — still compiles and runs; downloads simply fail fast there.
 */
interface DownloadFileDownloader {
    fun start(
        request: DownloadPlatformRequest,
        onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
        onSuccess: (localFileUri: String, totalBytes: Long?) -> Unit,
        onFailure: (message: String) -> Unit,
    ): DownloadsTaskHandle

    fun removeFile(localFileUri: String?): Boolean

    fun removePartialFile(destinationFileName: String): Boolean

    fun resolveLocalFileUri(localFileUri: String?, destinationFileName: String): String?
}

/** Process-wide holder for the active [DownloadFileDownloader]. composeApp installs the real one. */
object DownloadFileDownloaderProvider {
    @Volatile
    var downloader: DownloadFileDownloader = NoOpDownloadFileDownloader
}

private object NoOpDownloadsTaskHandle : DownloadsTaskHandle {
    override fun cancel() {}
}

private object NoOpDownloadFileDownloader : DownloadFileDownloader {
    override fun start(
        request: DownloadPlatformRequest,
        onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
        onSuccess: (localFileUri: String, totalBytes: Long?) -> Unit,
        onFailure: (message: String) -> Unit,
    ): DownloadsTaskHandle {
        onFailure("Downloads are not supported on this device.")
        return NoOpDownloadsTaskHandle
    }

    override fun removeFile(localFileUri: String?): Boolean = false

    override fun removePartialFile(destinationFileName: String): Boolean = false

    override fun resolveLocalFileUri(localFileUri: String?, destinationFileName: String): String? = null
}
