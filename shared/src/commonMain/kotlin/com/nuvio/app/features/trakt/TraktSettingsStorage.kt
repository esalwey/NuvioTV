package com.nuvio.app.features.trakt

expect object TraktSettingsStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}
