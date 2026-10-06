package com.nuvio.app.core.coroutines

import co.touchlab.kermit.Logger
import kotlinx.coroutines.CoroutineExceptionHandler

/**
 * Last-resort handler for repository background scopes: on Kotlin/Native an exception that
 * escapes a `launch` (including a failed child coroutine, which a `try/catch` in the parent
 * cannot intercept) reaches the platform's unhandled-exception hook and terminates the iOS
 * process. Attaching this to a scope downgrades that to an error log.
 *
 * This is a safety net, not error handling — paths that can fail for expected reasons
 * (network, decode) should still catch locally and degrade gracefully.
 */
fun uncaughtCoroutineLogger(tag: String): CoroutineExceptionHandler =
    CoroutineExceptionHandler { _, error ->
        Logger.withTag(tag).e(error) {
            "Uncaught coroutine exception suppressed (would have killed the process)"
        }
    }
