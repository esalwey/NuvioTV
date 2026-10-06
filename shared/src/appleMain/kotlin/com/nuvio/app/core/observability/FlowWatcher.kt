package com.nuvio.app.core.observability

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Swift-facing bridge for observing a Kotlin [Flow] / [StateFlow] from SwiftUI.
 *
 * Kotlin `Flow`s can't be collected directly from Swift. This wraps a flow in a long-lived
 * collector whose emissions are delivered on the main thread via [onEach], and exposes [cancel]
 * so the Swift side can stop collection when its view disappears / the observer is deallocated.
 *
 * For a [StateFlow] the current value is delivered immediately on subscription, so SwiftUI gets an
 * initial render without extra wiring.
 *
 * Swift usage (via the generated `FlowWatcher` class + `watch` extension):
 * ```swift
 * let watcher = FlowWatcherKt.watch(SomeRepository.shared.uiState) { state in
 *     // state is Any?; cast to the concrete UiState type
 * }
 * // later:
 * watcher.cancel()
 * ```
 */
class FlowWatcher internal constructor(
    flow: Flow<*>,
    onEach: (Any?) -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main + uncaughtCoroutineLogger("FlowWatcher"))

    init {
        scope.launch {
            // An exception escaping this collector (a throwing upstream flow, or a Kotlin
            // exception out of the Swift callback) would be an uncaught coroutine failure —
            // process death on iOS. Observation is UI plumbing; log and stop watching instead.
            try {
                flow.collect { value -> onEach(value) }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                Logger.withTag("FlowWatcher").e(error) { "Flow collection failed; watcher stopped" }
            }
        }
    }

    /** Stops collection. Safe to call multiple times. Always call this when the observer goes away. */
    fun cancel() {
        scope.cancel()
    }
}

// Non-generic on purpose: Kotlin generics surface to Swift as `FlowWatcher<...>` requiring explicit
// type args at every call site. Erasing to `Any?` keeps the Swift API a plain `FlowWatcher` + an
// `(Any?) -> Void` callback the caller casts — see StateFlowObserver.swift.

/** Observe this [StateFlow] from Swift; see [FlowWatcher]. */
fun StateFlow<*>.watch(onEach: (Any?) -> Unit): FlowWatcher = FlowWatcher(this, onEach)

/** Observe any [Flow] from Swift; see [FlowWatcher]. */
fun Flow<*>.watchFlow(onEach: (Any?) -> Unit): FlowWatcher = FlowWatcher(this, onEach)
