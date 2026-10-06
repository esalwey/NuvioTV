package com.nuvio.app.features.player

import kotlin.jvm.JvmInline

/**
 * Platform-neutral subtitle colour, stored as a packed `0xAARRGGBB` value.
 *
 * The shared (Compose-free) module can't use `androidx.compose.ui.graphics.Color`, so
 * [SubtitleStyleState] holds these instead. composeApp converts to/from Compose `Color` at the UI
 * boundary (see `PlayerSubtitleColorCompose.kt`). Persisted as `#AARRGGBB` hex via
 * [toStorageHexString] / [subtitleColorFromStorage], matching the previous Compose-based format so
 * stored preferences round-trip unchanged.
 */
@JvmInline
value class SubtitleColor(val argb: Long) {
    companion object {
        val White = SubtitleColor(0xFFFFFFFF)
        val Black = SubtitleColor(0xFF000000)
        val Transparent = SubtitleColor(0x00000000)
    }
}

fun SubtitleColor.toStorageHexString(): String {
    fun component(shift: Int): String =
        ((argb shr shift) and 0xFF).toString(16).padStart(2, '0').uppercase()

    return buildString {
        append('#')
        append(component(24))
        append(component(16))
        append(component(8))
        append(component(0))
    }
}

fun subtitleColorFromStorage(value: String?): SubtitleColor? {
    val normalized = value
        ?.trim()
        ?.removePrefix("#")
        ?.takeIf { it.length == 6 || it.length == 8 }
        ?: return null

    val argb = if (normalized.length == 6) "FF$normalized" else normalized
    val parsed = argb.toLongOrNull(16) ?: return null
    return SubtitleColor(parsed)
}

/** Foreground (text/outline) colour palette. */
val SubtitleColorSwatches = listOf(
    SubtitleColor(0xFFFFFFFF), // White
    SubtitleColor(0xFFFFD700),
    SubtitleColor(0xFF00E5FF),
    SubtitleColor(0xFFFF5C5C),
    SubtitleColor(0xFF00FF88),
    SubtitleColor(0xFF9B59B6),
    SubtitleColor(0xFFF97316),
    SubtitleColor(0xFF22C55E),
    SubtitleColor(0xFF3B82F6),
    SubtitleColor(0xFF000000), // Black
)

/** Background colour palette (alphas pre-rounded to match the prior Compose `copy(alpha=…)` values). */
val SubtitleBackgroundColorSwatches = listOf(
    SubtitleColor(0x00000000), // Transparent
    SubtitleColor(0x8C000000), // Black @ 0.55
    SubtitleColor(0xB8111827), // @ 0.72
    SubtitleColor(0xAD7F1D1D), // @ 0.68
    SubtitleColor(0xAD064E3B), // @ 0.68
    SubtitleColor(0xAD1E3A8A), // @ 0.68
)
