package com.nuvio.app.features.watchprogress

expect object WatchProgressStorage {
    fun loadPayload(profileId: Int): String?
    fun savePayload(profileId: Int, payload: String)
}
