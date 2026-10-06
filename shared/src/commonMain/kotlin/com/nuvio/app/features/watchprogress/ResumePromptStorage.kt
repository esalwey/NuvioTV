package com.nuvio.app.features.watchprogress

expect object ResumePromptStorage {
    fun loadWasInPlayer(): Boolean
    fun saveWasInPlayer(value: Boolean)
    fun loadLastPlayerVideoId(): String?
    fun saveLastPlayerVideoId(videoId: String?)
}
