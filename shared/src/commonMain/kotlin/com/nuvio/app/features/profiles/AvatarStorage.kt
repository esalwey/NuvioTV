package com.nuvio.app.features.profiles

expect object AvatarStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}