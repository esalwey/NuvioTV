package com.nuvio.app.features.downloads

expect object DownloadsStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}
