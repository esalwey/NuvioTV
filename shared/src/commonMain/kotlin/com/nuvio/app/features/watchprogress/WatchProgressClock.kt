package com.nuvio.app.features.watchprogress

expect object WatchProgressClock {
    fun nowEpochMs(): Long
}
