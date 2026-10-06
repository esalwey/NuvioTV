package com.nuvio.app.features.downloads

/**
 * Installs the composeApp [DownloadsPlatformDownloader] (an `expect`/`actual` object whose Android
 * actual posts notifications and uses app resources) behind the shared [DownloadFileDownloader]
 * seam. Call [install] once at app startup.
 */
object DownloadFileDownloaderAdapter {
    fun install() {
        DownloadFileDownloaderProvider.downloader = object : DownloadFileDownloader {
            override fun start(
                request: DownloadPlatformRequest,
                onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
                onSuccess: (localFileUri: String, totalBytes: Long?) -> Unit,
                onFailure: (message: String) -> Unit,
            ): DownloadsTaskHandle =
                DownloadsPlatformDownloader.start(request, onProgress, onSuccess, onFailure)

            override fun removeFile(localFileUri: String?): Boolean =
                DownloadsPlatformDownloader.removeFile(localFileUri)

            override fun removePartialFile(destinationFileName: String): Boolean =
                DownloadsPlatformDownloader.removePartialFile(destinationFileName)

            override fun resolveLocalFileUri(localFileUri: String?, destinationFileName: String): String? =
                DownloadsPlatformDownloader.resolveLocalFileUri(localFileUri, destinationFileName)
        }
    }
}
