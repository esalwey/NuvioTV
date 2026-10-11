package com.nuvio.app.core.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CustomThemeColorsTest {

    @Test
    fun parseHexAcceptsOptionalHashAndAnyCase() {
        assertEquals(0x2255AA, parseHexColor("#2255aa"))
        assertEquals(0x2255AA, parseHexColor(" 2255AA "))
        assertEquals(0, parseHexColor("000000"))
    }

    @Test
    fun parseHexRejectsMalformedInput() {
        assertNull(parseHexColor(""))
        assertNull(parseHexColor("#12345"))
        assertNull(parseHexColor("#1234567"))
        assertNull(parseHexColor("#GGGGGG"))
        assertNull(parseHexColor("#12 456"))
    }

    @Test
    fun formatPadsAndUppercases() {
        assertEquals("#000FA0", formatHexColor(0x000FA0))
        assertEquals("#FFFFFF", formatHexColor(0xFFFFFF))
    }

    @Test
    fun encodeDecodeRoundTrips() {
        val colors = CustomThemeColors(0x123456, 0xABCDEF, 0x654321)
        assertEquals("#123456,#ABCDEF,#654321", colors.encode())
        assertEquals(colors, CustomThemeColors.decode(colors.encode()))
    }

    @Test
    fun decodeFallsBackToDefault() {
        assertEquals(CustomThemeColors.Default, CustomThemeColors.decode(null))
        assertEquals(CustomThemeColors.Default, CustomThemeColors.decode(""))
        assertEquals(CustomThemeColors.Default, CustomThemeColors.decode("#112233"))
        assertEquals(CustomThemeColors.Default, CustomThemeColors.decode("#112233,#445566,nope"))
        assertEquals(CustomThemeColors.Default, CustomThemeColors.decode("#112233,#445566"))
    }

    @Test
    fun solidColorAccentIsTheColorAndFocusIsLighter() {
        val solid = CustomThemeColors.solid(0x2255AA)
        assertTrue(solid.isSolid)
        assertEquals("#2255AA", solid.accentHex)
        assertTrue(relativeLuminance(solid.focus) > relativeLuminance(solid.accent))
    }

    @Test
    fun gradientAccentIsMiddleAndFocusIsBrightest() {
        val colors = CustomThemeColors(0x101010, 0x3366CC, 0xFFEE88)
        assertFalse(colors.isSolid)
        assertEquals(0x3366CC, colors.accent)
        assertEquals(0xFFEE88, colors.focus)
    }

    @Test
    fun lightenKeepsWhiteAndMovesTowardWhite() {
        assertEquals(0xFFFFFF, lighten(0xFFFFFF, 0.5f))
        assertEquals(0x000000, lighten(0x000000, 0f))
        val lighter = lighten(0x204060, 0.5f)
        assertTrue(relativeLuminance(lighter) > relativeLuminance(0x204060))
    }

    @Test
    fun luminanceBounds() {
        assertEquals(0f, relativeLuminance(0x000000))
        assertTrue(relativeLuminance(0xFFFFFF) > 0.99f)
    }

    @Test
    fun builtInThemesHaveDistinctNativeAccent() {
        val fixed = AppTheme.entries.filter { it != AppTheme.CUSTOM }.map { it.nativeAccentHex }
        assertEquals(fixed.size, fixed.toSet().size)
    }

    @Test
    fun customNativeAccentFollowsStoredColors() {
        val colors = CustomThemeColors.solid(0x2255AA)
        assertEquals(colors.focusHex, AppTheme.CUSTOM.resolvedNativeAccentHex(colors))
        assertEquals("#E53935", AppTheme.CRIMSON.resolvedNativeAccentHex(colors))
    }
}
