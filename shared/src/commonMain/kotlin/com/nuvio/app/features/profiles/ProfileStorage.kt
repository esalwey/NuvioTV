package com.nuvio.app.features.profiles

expect object ProfileStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}