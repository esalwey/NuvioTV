package com.nuvio.app.features.watchprogress

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * BUG-75 smoke coverage: TvOsProviderInstaller now calls clearLocalState()/ensureStarted() on
 * this object directly (guest launch, and re-arming after an account wipe), so both must be safe
 * with no authenticated session and no live network.
 */
class WatchProgressSourceCoordinatorLifecycleTest {

    @AfterTest
    fun tearDown() {
        // Leave the coordinator unarmed for the next test in this suite.
        WatchProgressSourceCoordinator.clearLocalState()
    }

    @Test
    fun clearLocalState_resetsObservableStateToDefaults() {
        WatchProgressSourceCoordinator.clearLocalState()

        assertEquals(WatchProgressSourceTransitionState(), WatchProgressSourceCoordinator.uiState.value)
    }

    @Test
    fun ensureStarted_afterClearDoesNotThrow() {
        WatchProgressSourceCoordinator.clearLocalState()

        // Must be safe pre-auth/pre-profile — exactly the state tvOS's provider installer calls
        // it in for a guest launch.
        WatchProgressSourceCoordinator.ensureStarted()
    }
}
