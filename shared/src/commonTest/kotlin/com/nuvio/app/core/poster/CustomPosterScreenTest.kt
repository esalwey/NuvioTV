package com.nuvio.app.core.poster

import kotlin.test.Test
import kotlin.test.assertEquals

class CustomPosterScreenTest {
    @Test
    fun `nothing stored means every screen`() {
        assertEquals(CustomPosterScreen.ALL, CustomPosterScreen.fromStoredString(null))
        assertEquals(CustomPosterScreen.ALL, CustomPosterScreen.fromStoredString(""))
        assertEquals(CustomPosterScreen.ALL, CustomPosterScreen.fromStoredString("  "))
    }

    @Test
    fun `a stored list round trips in declaration order`() {
        val screens = setOf(CustomPosterScreen.SEARCH, CustomPosterScreen.HOME)
        val stored = CustomPosterScreen.toStoredString(screens)

        assertEquals("home,search", stored)
        assertEquals(screens, CustomPosterScreen.fromStoredString(stored))
    }

    @Test
    fun `no enabled screen is stored distinctly from never chosen`() {
        val stored = CustomPosterScreen.toStoredString(emptySet())

        assertEquals("none", stored)
        assertEquals(emptySet(), CustomPosterScreen.fromStoredString(stored))
    }

    @Test
    fun `unknown keys are dropped`() {
        assertEquals(
            setOf(CustomPosterScreen.LIBRARY),
            CustomPosterScreen.fromStoredString("library, widgets"),
        )
    }
}
