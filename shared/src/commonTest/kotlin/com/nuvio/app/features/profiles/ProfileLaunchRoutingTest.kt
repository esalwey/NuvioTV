package com.nuvio.app.features.profiles

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ProfileLaunchRoutingTest {
    private fun profile(index: Int, pin: Boolean = false) =
        NuvioProfile(profileIndex = index, name = "P$index", pinEnabled = pin)

    private fun state(
        remember: Boolean = true,
        everSelected: Boolean = true,
        vararg profiles: NuvioProfile,
    ) = ProfileState(
        profiles = profiles.toList(),
        isLoaded = true,
        hasEverSelectedProfile = everSelected,
        rememberLastProfileEnabled = remember,
    )

    @Test
    fun resumesTheLastProfileWhenRememberIsOn() {
        val resolved = resolveLaunchProfile(state(true, true, profile(1), profile(2)), lastActiveProfileIndex = 2)
        assertEquals(2, resolved?.profileIndex)
    }

    @Test
    fun showsThePickerWhenRememberIsOff() {
        assertNull(resolveLaunchProfile(state(false, true, profile(1), profile(2)), lastActiveProfileIndex = 2))
    }

    @Test
    fun showsThePickerBeforeAnyProfileWasEverSelected() {
        assertNull(resolveLaunchProfile(state(true, false, profile(1)), lastActiveProfileIndex = 1))
    }

    @Test
    fun aLockedProfileAlwaysAsksForItsPin() {
        assertNull(resolveLaunchProfile(state(true, true, profile(1), profile(2, pin = true)), lastActiveProfileIndex = 2))
    }

    @Test
    fun aDeletedLastProfileFallsBackToThePicker() {
        assertNull(resolveLaunchProfile(state(true, true, profile(1)), lastActiveProfileIndex = 3))
    }
}
