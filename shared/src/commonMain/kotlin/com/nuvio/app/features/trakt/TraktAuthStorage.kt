package com.nuvio.app.features.trakt

expect object TraktAuthStorage {
    fun loadPayload(profileId: Int): String?
    fun savePayload(profileId: Int, payload: String)
}
