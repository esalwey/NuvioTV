package com.nuvio.app.core.network

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.addons.httpRequestRaw
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

enum class NetworkCondition {
    Unknown,
    Checking,
    Online,
    NoInternet,
    ServersUnreachable,
}

data class NetworkStatusUiState(
    val condition: NetworkCondition = NetworkCondition.Unknown,
) {
    val isOnline: Boolean
        get() = condition == NetworkCondition.Online

    val isOfflineLike: Boolean
        get() = condition == NetworkCondition.NoInternet || condition == NetworkCondition.ServersUnreachable
}

object NetworkStatusRepository {
    private const val REQUEST_TIMEOUT_MS = 4_500L
    private const val FOREGROUND_REFRESH_DELAY_MS = 6_000L
    private const val FOREGROUND_FAILURE_CONFIRM_DELAY_MS = 2_000L
    private const val PUBLIC_PROBE_PRIMARY = "https://www.gstatic.com/generate_204"
    private const val PUBLIC_PROBE_FALLBACK = "https://cloudflare.com/cdn-cgi/trace"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("NetworkStatus"))
    private val _uiState = MutableStateFlow(NetworkStatusUiState())
    val uiState: StateFlow<NetworkStatusUiState> = _uiState.asStateFlow()

    private var started = false
    private var probeInFlight = false
    private var pendingProbeAfterCurrent = false
    private var pendingProbeConfirmFailures = false
    private var foregroundRefreshJob: Job? = null

    fun ensureStarted() {
        if (started) return
        started = true
        requestRefresh(force = true)
    }

    fun requestForegroundRefresh() {
        ensureStarted()
        foregroundRefreshJob?.cancel()
        foregroundRefreshJob = scope.launch {
            delay(FOREGROUND_REFRESH_DELAY_MS)
            requestRefresh(force = true, confirmFailures = true)
        }
    }

    fun requestRefresh(force: Boolean = false, confirmFailures: Boolean = false) {
        if (!started) started = true
        if (probeInFlight) {
            if (force) {
                pendingProbeAfterCurrent = true
                pendingProbeConfirmFailures = pendingProbeConfirmFailures || confirmFailures
            }
            return
        }

        scope.launch {
            var nextConfirmFailures = confirmFailures
            do {
                val runConfirmFailures = nextConfirmFailures || pendingProbeConfirmFailures
                nextConfirmFailures = false
                pendingProbeAfterCurrent = false
                pendingProbeConfirmFailures = false
                probeInFlight = true
                runProbe(confirmFailures = runConfirmFailures)
                probeInFlight = false
            } while (pendingProbeAfterCurrent)
        }
    }

    private suspend fun runProbe(confirmFailures: Boolean) {
        if (_uiState.value.condition == NetworkCondition.Unknown) {
            _uiState.value = NetworkStatusUiState(condition = NetworkCondition.Checking)
        }

        val previousCondition = _uiState.value.condition
        var nextCondition = probeCondition()
        if (
            confirmFailures &&
            previousCondition == NetworkCondition.Online &&
            nextCondition.isOfflineLike()
        ) {
            delay(FOREGROUND_FAILURE_CONFIRM_DELAY_MS)
            nextCondition = probeCondition()
        }

        _uiState.value = NetworkStatusUiState(condition = nextCondition)
    }

    private suspend fun probeCondition(): NetworkCondition {
        val internetReachable = probePublicInternet()
        val supabaseReachable = probeSupabase()
        // Fork: a self-hosted backend can live on the LAN (or the public probes can be blocked
        // by the network) — a reachable backend must win over a failed internet probe, or the
        // app declares NoInternet and suppresses loads while its own server is right there.
        if (supabaseReachable) {
            return NetworkCondition.Online
        }
        if (!internetReachable) {
            return NetworkCondition.NoInternet
        }
        return NetworkCondition.ServersUnreachable
    }

    private suspend fun probeSupabase(): Boolean =
        SupabaseEndpointConfig.restEndpointUrls().any { url ->
            probeReachable(
                url = url,
                headers = mapOf("apikey" to ServerConfigurationRepository.active.value.publishableKey),
            )
        }

    private suspend fun probePublicInternet(): Boolean =
        probeReachable(PUBLIC_PROBE_PRIMARY) || probeReachable(PUBLIC_PROBE_FALLBACK)

    private suspend fun probeReachable(
        url: String,
        headers: Map<String, String> = emptyMap(),
    ): Boolean {
        val response = withTimeoutOrNull(REQUEST_TIMEOUT_MS) {
            runCatching {
                httpRequestRaw(
                    method = "GET",
                    url = url,
                    headers = headers,
                    body = "",
                )
            }.getOrNull()
        } ?: return false

        return response.status in 100..599
    }

    private fun NetworkCondition.isOfflineLike(): Boolean =
        this == NetworkCondition.NoInternet || this == NetworkCondition.ServersUnreachable
}
