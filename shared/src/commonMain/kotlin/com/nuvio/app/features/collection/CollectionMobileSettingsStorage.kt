package com.nuvio.app.features.collection

expect object CollectionMobileSettingsStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}
