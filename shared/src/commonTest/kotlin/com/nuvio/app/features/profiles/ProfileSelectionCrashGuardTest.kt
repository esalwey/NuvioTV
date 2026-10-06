package com.nuvio.app.features.profiles

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * `selectProfile` runs on the caller's thread — on tvOS that is the Swift main thread, where a
 * Kotlin exception escaping back into Swift is not catchable and aborts the process. A single
 * failing profile-scoped repository therefore turned every profile tap into a force-close
 * (beta tester reports 2026-07-21 and 2026-07-22). Selection must survive a throwing fan-out.
 */
class ProfileSelectionCrashGuardTest {

    private val originalCoordinator = ProfileLifecycleProvider.coordinator

    @AfterTest
    fun restoreCoordinator() {
        ProfileLifecycleProvider.coordinator = originalCoordinator
    }

    @Test
    fun selectProfile_survivesAThrowingLifecycleFanOut() {
        ProfileLifecycleProvider.coordinator = object : ProfileLifecycleCoordinator {
            override fun onProfileSelected(profileIndex: Int) {
                error("simulated repository failure during profile-select fan-out")
            }

            override fun onProfilesCached() {}
        }

        ProfileRepository.selectProfile(profileIndex = 3)

        assertEquals(
            expected = 3,
            actual = ProfileRepository.activeProfileId,
            message = "Selection must still take effect when the fan-out fails",
        )
    }

    @Test
    fun selectProfile_stillRunsTheFanOutWhenItSucceeds() {
        var observedIndex: Int? = null
        ProfileLifecycleProvider.coordinator = object : ProfileLifecycleCoordinator {
            override fun onProfileSelected(profileIndex: Int) {
                observedIndex = profileIndex
            }

            override fun onProfilesCached() {}
        }

        ProfileRepository.selectProfile(profileIndex = 2)

        assertEquals(expected = 2, actual = observedIndex, message = "Fan-out must still run normally")
        assertTrue(ProfileRepository.activeProfileId == 2)
    }
}
