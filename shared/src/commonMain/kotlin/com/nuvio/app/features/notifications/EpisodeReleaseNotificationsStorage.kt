package com.nuvio.app.features.notifications

expect object EpisodeReleaseNotificationsStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}
