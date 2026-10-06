package com.nuvio.app.features.plugins.runtime.host

import co.touchlab.kermit.Logger
import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.asyncFunction
import com.dokar.quickjs.binding.define
import com.dokar.quickjs.binding.function
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withTimeoutOrNull

private const val MAX_PLUGIN_TIMER_DELAY_MS = 60_000L

internal class HostFunctions(
    private val scraperId: String,
    private val onResult: (String) -> Unit
) : HostModule {
    private val log = Logger.withTag("PluginRuntime")

    /**
     * What ends a pending `__plugin_sleep` before its delay runs out. quickjs-kt's `evaluate()` only
     * returns once every async host job has finished, so a sleep left running holds the plugin call
     * open: a cleared `setTimeout(abort, 15000)` fetch guard would delay the streams by 15 s, and an
     * interval nobody clears would run into the plugin timeout, which throws the results away.
     */
    private data class TimerWakeups(
        val resultCaptured: Boolean = false,
        val clearedTimerIds: Set<Int> = emptySet(),
    ) {
        fun wakes(timerId: Int?): Boolean =
            resultCaptured || (timerId != null && timerId in clearedTimerIds)
    }

    private val timerWakeups = MutableStateFlow(TimerWakeups())

    override fun register(runtime: QuickJs) {
        // Upstream d03d97eb7: backs the setTimeout/setInterval polyfill (JsBindings) with a
        // coroutine delay, so a timer callback runs asynchronously instead of busy-waiting.
        // Resolves true when the delay ran out and the callback may run, false when the timer was
        // cleared or the result is already in (the polyfill then skips the callback).
        runtime.asyncFunction("__plugin_sleep") { args: Array<Any?> ->
            val durationMs = (args.getOrNull(0) as? Number)
                ?.toLong()
                ?.coerceIn(0L, MAX_PLUGIN_TIMER_DELAY_MS)
                ?: 0L
            val timerId = (args.getOrNull(1) as? Number)?.toInt()
            withTimeoutOrNull(durationMs) {
                timerWakeups.first { wakeups -> wakeups.wakes(timerId) }
            }
            !timerWakeups.value.wakes(timerId)
        }

        // clearTimeout/clearInterval: ends the sleep behind the timer at once.
        runtime.function("__plugin_cancel_sleep") { args ->
            val timerId = (args.getOrNull(0) as? Number)?.toInt()
            if (timerId != null) {
                timerWakeups.update { wakeups ->
                    wakeups.copy(clearedTimerIds = wakeups.clearedTimerIds + timerId)
                }
            }
            null
        }

        runtime.define("console") {
            function("log") { args ->
                log.d { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
            function("error") { args ->
                log.e { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
            function("warn") { args ->
                log.w { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
            function("info") { args ->
                log.i { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
            function("debug") { args ->
                log.d { "Plugin:$scraperId ${args.joinToString(" ") { it?.toString() ?: "null" }}" }
                null
            }
        }

        runtime.function("__capture_result") { args ->
            onResult(args.getOrNull(0)?.toString() ?: "[]")
            // Nothing the plugin still has scheduled may keep the call open once the streams are in.
            timerWakeups.update { wakeups -> wakeups.copy(resultCaptured = true) }
            null
        }
    }
}
