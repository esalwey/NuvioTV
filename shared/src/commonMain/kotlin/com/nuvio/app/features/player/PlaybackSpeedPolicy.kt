package com.nuvio.app.features.player

import kotlin.math.abs

/**
 * The playback speeds the players offer and how a title's speed is remembered: 1x is "no
 * preference" (the entry is removed), anything else is stored clamped to the offered range.
 */
object PlaybackSpeedPolicy {
    /** The speeds the transport bar offers, slowest first. */
    val steps: List<Float> = listOf(0.25f, 0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f)

    const val MIN_SPEED = 0.25f
    const val MAX_SPEED = 2f

    /** What to store for [speed]: null (nothing stored) for normal speed, else the clamped speed. */
    fun storedValue(speed: Float): Float? {
        if (!speed.isFinite()) return null
        val clamped = speed.coerceIn(MIN_SPEED, MAX_SPEED)
        return clamped.takeIf { abs(it - 1f) > 0.001f }
    }

    /** A stored speed read back: only values inside the offered range are replayed. */
    fun restoredValue(stored: Float?): Float? {
        val value = stored ?: return null
        if (!value.isFinite() || value < MIN_SPEED || value > MAX_SPEED) return null
        return value.takeIf { abs(it - 1f) > 0.001f }
    }
}
