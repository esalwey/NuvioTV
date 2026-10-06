package com.nuvio.app.features.profiles

expect object ProfileHoverHapticFeedback {
    fun prepare()
    fun perform()
    fun release()
}
