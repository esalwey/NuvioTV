package com.nuvio.app.features.library

expect object LibraryClock {
    fun nowEpochMs(): Long
}
