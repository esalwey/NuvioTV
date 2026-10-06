package com.nuvio.app.features.watchprogress

expect object ContinueWatchingPreferencesStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}
