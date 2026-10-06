package com.nuvio.app.features.library

expect object LibraryStorage {
    fun loadPayload(profileId: Int): String?
    fun savePayload(profileId: Int, payload: String)
}
