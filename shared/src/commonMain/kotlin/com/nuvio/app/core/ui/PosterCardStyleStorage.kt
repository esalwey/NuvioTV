package com.nuvio.app.core.ui

expect object PosterCardStyleStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}