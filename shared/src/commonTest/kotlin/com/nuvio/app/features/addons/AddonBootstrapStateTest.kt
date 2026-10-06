package com.nuvio.app.features.addons

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The bootstrap guard and its observable mirror must agree on every completion path. Before the
 * seam, `AddonRepository.pullFromServer()` set the guard alone, so a pull that finished before
 * `initialize()` left `initializedState` false for the life of the profile and
 * `SubtitleRepository` waited on it until its timeout.
 *
 * Scope note: [AddonRepository] itself is not driven here. It is a singleton whose pull path reads
 * Supabase with no injection seam, so the state pair is exercised through [AddonBootstrapState],
 * the only thing the repository writes those two facts through.
 */
class AddonBootstrapStateTest {

    @Test
    fun aServerPullCompletingBeforeInitializeFlipsTheMirror() {
        val state = AddonBootstrapState()
        assertFalse(state.initializedState.value)

        // The pull path: complete() without a preceding begin().
        state.complete()

        assertTrue(state.initializedState.value, "the mirror must follow the guard")
        assertTrue(state.initialized, "a later initialize() must return early, keeping the pulled list")
    }

    @Test
    fun beginningBootstrapDoesNotFlipTheMirror() {
        val state = AddonBootstrapState()
        state.begin()
        assertTrue(state.initialized)
        assertFalse(state.initializedState.value, "the mirror flips only once a list is published")

        state.complete()
        assertTrue(state.initializedState.value)
    }

    @Test
    fun resetClearsBothFacts() {
        val state = AddonBootstrapState()
        state.complete()
        state.reset()
        assertFalse(state.initialized)
        assertFalse(state.initializedState.value)
    }
}
