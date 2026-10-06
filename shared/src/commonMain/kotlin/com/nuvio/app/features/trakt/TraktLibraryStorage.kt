package com.nuvio.app.features.trakt

expect object TraktLibraryStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}