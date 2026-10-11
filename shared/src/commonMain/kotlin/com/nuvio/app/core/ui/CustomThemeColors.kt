package com.nuvio.app.core.ui

import kotlin.math.pow

/**
 * The user-defined colors behind [AppTheme.CUSTOM]. Storage format and semantics match the mobile
 * app (`custom_theme_colors` = three `#RRGGBB` values joined by commas) so the value rides profile
 * settings sync unchanged: the accent is the second color, the focus ring the brightest of the three.
 *
 * A solid theme repeats one color three times. [accentHex] / [focusHex] resolve the pair the tvOS
 * palette consumes; for a solid color the focus color is a lighter variant of the accent, mirroring
 * how every built-in theme pairs an accent with a brighter focus color.
 */
data class CustomThemeColors(
    val first: Int = 0xB75AFF,
    val second: Int = 0xEC70A9,
    val third: Int = 0xFFB37A,
) {
    init {
        require(listOf(first, second, third).all { it in 0..0xFFFFFF })
    }

    val colors: List<Int> get() = listOf(first, second, third)
    val isSolid: Boolean get() = first == second && second == third

    /** The accent color (middle of the gradient). */
    val accent: Int get() = second

    /** The focus / highlight color. */
    val focus: Int
        get() = if (isSolid) lighten(second, FOCUS_LIGHTEN_AMOUNT) else colors.maxBy { relativeLuminance(it) }

    val accentHex: String get() = formatHexColor(accent)
    val focusHex: String get() = formatHexColor(focus)

    fun withColor(index: Int, color: Int): CustomThemeColors = when (index) {
        0 -> copy(first = color)
        1 -> copy(second = color)
        2 -> copy(third = color)
        else -> this
    }

    fun encode(): String = colors.joinToString(",", transform = ::formatHexColor)

    companion object {
        val Default = CustomThemeColors()

        private const val FOCUS_LIGHTEN_AMOUNT = 0.28f

        fun solid(color: Int): CustomThemeColors = CustomThemeColors(color, color, color)

        fun decode(value: String?): CustomThemeColors {
            val parts = value?.split(",") ?: return Default
            val colors = parts.map { parseHexColor(it) ?: return Default }
            return if (colors.size == 3) CustomThemeColors(colors[0], colors[1], colors[2]) else Default
        }
    }
}

/** Parses `RRGGBB` / `#RRGGBB` (any case). Returns null for anything else. */
fun parseHexColor(value: String): Int? {
    val hex = value.trim().removePrefix("#")
    if (hex.length != 6 || hex.any { it !in '0'..'9' && it.uppercaseChar() !in 'A'..'F' }) return null
    return hex.toIntOrNull(16)
}

/** `#RRGGBB`, upper case. */
fun formatHexColor(color: Int): String = "#" + (color and 0xFFFFFF).toString(16).padStart(6, '0').uppercase()

/** WCAG relative luminance (linearised sRGB, Rec. 709 weights), 0.0 - 1.0. */
fun relativeLuminance(rgb: Int): Float {
    fun channel(shift: Int): Float {
        val c = ((rgb shr shift) and 0xFF) / 255f
        return if (c <= 0.04045f) c / 12.92f else ((c + 0.055f) / 1.055f).toDouble().pow(2.4).toFloat()
    }
    return 0.2126f * channel(16) + 0.7152f * channel(8) + 0.0722f * channel(0)
}

/** Mixes [rgb] toward white by [amount] (0.0 - 1.0). */
fun lighten(rgb: Int, amount: Float): Int {
    fun mix(shift: Int): Int {
        val c = (rgb shr shift) and 0xFF
        return (c + (255 - c) * amount).toInt().coerceIn(0, 255)
    }
    return (mix(16) shl 16) or (mix(8) shl 8) or mix(0)
}
