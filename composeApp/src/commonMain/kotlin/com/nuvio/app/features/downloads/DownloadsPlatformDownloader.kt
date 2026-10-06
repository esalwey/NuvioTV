package com.nuvio.app.features.downloads

// DownloadPlatformRequest + DownloadsTaskHandle now live in :shared (consumed by the
// DownloadFileDownloader seam); referenced here same-package via implementation(projects.shared).
internal expect object DownloadsPlatformDownloader {
    fun start(
        request: DownloadPlatformRequest,
        onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
        onSuccess: (localFileUri: String, totalBytes: Long?) -> Unit,
        onFailure: (message: String) -> Unit,
    ): DownloadsTaskHandle

    fun removeFile(localFileUri: String?): Boolean

    fun removePartialFile(destinationFileName: String): Boolean

    fun resolveLocalFileUri(localFileUri: String?, destinationFileName: String): String?

    fun openDownloadsDirectory(): Boolean
}
