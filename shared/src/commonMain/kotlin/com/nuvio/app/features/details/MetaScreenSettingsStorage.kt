package com.nuvio.app.features.details

expect object MetaScreenSettingsStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}