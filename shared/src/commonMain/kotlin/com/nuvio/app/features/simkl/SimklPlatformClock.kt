package com.nuvio.app.features.simkl

internal expect object SimklPlatformClock {
    fun nowEpochMs(): Long
}
