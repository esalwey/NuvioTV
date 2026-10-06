package com.nuvio.app.features.addons

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The two bootstrap facts [AddonRepository] keeps about the active profile, held together so they
 * cannot drift apart:
 *
 * - [initialized]: bootstrap has begun. `initialize()` reads it as its reentrancy guard, and a
 *   server pull that applied a list sets it so a later `initialize()` does not overwrite that list
 *   with the local one.
 * - [initializedState]: the observable mirror. It flips only once a list has actually been
 *   PUBLISHED to `uiState`, so a consumer that awaits it (the player's subtitle fetch) never
 *   snapshots the pre-bootstrap empty state.
 *
 * Every completion path goes through [complete], which sets both. Before this seam the pull path
 * set the guard alone, so a pull that won the race with `initialize()` left the mirror false for
 * the life of the profile and the subtitle fetch waited on it until its timeout.
 */
internal class AddonBootstrapState {
    var initialized: Boolean = false
        private set

    private val _initializedState = MutableStateFlow(false)
    val initializedState: StateFlow<Boolean> = _initializedState.asStateFlow()

    /** `initialize()` has started reading the local list. The mirror stays false until [complete]. */
    fun begin() {
        initialized = true
    }

    /** A list for the active profile has been published, by `initialize()` or by a server pull. */
    fun complete() {
        initialized = true
        _initializedState.value = true
    }

    fun reset() {
        initialized = false
        _initializedState.value = false
    }
}
