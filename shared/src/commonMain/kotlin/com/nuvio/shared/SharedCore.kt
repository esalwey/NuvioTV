package com.nuvio.shared

/**
 * Phase 0 walking-skeleton surface. Proves the SharedCore framework links into the
 * tvOS app and that we can call Kotlin from Swift. Real repositories/models land here
 * as we migrate them out of composeApp.
 */
object SharedCore {
    const val VERSION: String = "0.0.1-phase0"

    fun greeting(): String = "SharedCore is linked — Nuvio tvOS Phase 0"
}
