package com.nuvio.app.features.trakt

expect object TraktPlatformClock {
    fun nowEpochMs(): Long
    fun parseIsoDateTimeToEpochMs(value: String): Long?
    fun availableProcessors(): Int
}
