package com.nuvio.app.features.search

expect object SearchHistoryStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
    /** Recent-searches switch for the active profile; null when never set (= on). */
    fun loadEnabled(): Boolean?
    fun saveEnabled(enabled: Boolean)
}
