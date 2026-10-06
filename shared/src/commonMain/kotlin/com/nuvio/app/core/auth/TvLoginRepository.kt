package com.nuvio.app.core.auth

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.network.ServerConfigurationRepository
import com.nuvio.app.core.network.SupabaseProvider
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

// Fork: the QR redirect base now lives on the active server —
// `ServerConfigurationRepository.active.value.tvLoginWebBaseUrl` (OFFICIAL_TV_LOGIN_WEB_BASE_URL for
// the hosted backend, `<backend>/tv-login` for a self-hosted one).

private const val TV_LOGIN_MAX_POLL_MINUTES = 10

@Serializable
data class TvLoginStartResult(
    val code: String,
    @SerialName("web_url") val webUrl: String,
    @SerialName("expires_at") val expiresAt: String,
    @SerialName("poll_interval_seconds") val pollIntervalSeconds: Int = 3,
)

@Serializable
internal data class TvLoginPollResult(
    val status: String,
    @SerialName("expires_at") val expiresAt: String? = null,
    @SerialName("poll_interval_seconds") val pollIntervalSeconds: Int? = null,
)

@Serializable
internal data class TvLoginExchangeResult(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
)

/**
 * One TV login attempt as observable state (the whole start → poll → exchange flow runs inside
 * this repository, mirroring the Trakt device-code architecture — Swift just watches).
 *
 * `status`: "pending" while waiting for the phone, "approved" momentarily during the exchange.
 * `completed`: the imported session is live — AuthRepository's session collector publishes the
 * real account; the QR screen should dismiss.
 * `unsupportedByServer`: the active (self-hosted) server does not advertise the `tv_login`
 * capability — the flow never started; the UI should offer another sign-in method instead of Retry.
 */
data class TvLoginUiState(
    val isStarting: Boolean = false,
    val code: String? = null,
    val webUrl: String? = null,
    val status: String? = null,
    val errorMessage: String? = null,
    val completed: Boolean = false,
    val unsupportedByServer: Boolean = false,
)

/**
 * QR sign-in for TVs against the ACTIVE backend (official or a self-hosted server that advertises
 * the `tv_login` capability; same protocol as the Android TV app):
 *  1. `start_tv_login_session` RPC (device nonce + redirect base) → short code + web URL. The TV
 *     renders the URL as a QR code; the phone scans it, opens the site, and the user approves.
 *  2. `poll_tv_login_session` RPC every few seconds until "approved" (or expired/cancelled).
 *  3. `tv-logins-exchange` edge function → access/refresh tokens → imported into the Supabase
 *     client, at which point the normal session collector takes over.
 *
 * The RPCs and the exchange require SOME authenticated session, so the flow first signs into a
 * throwaway **anonymous Supabase session** (scaffolding only — AuthRepository's collector ignores
 * anonymous sessions, so the UI never mistakes it for a real account).
 */
object TvLoginRepository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("TvLoginRepository"))
    private val log = Logger.withTag("TvLoginRepository")
    private val json = Json { ignoreUnknownKeys = true }

    private val _uiState = MutableStateFlow(TvLoginUiState())
    val uiState: StateFlow<TvLoginUiState> = _uiState.asStateFlow()

    private var flowJob: Job? = null

    @OptIn(ExperimentalUuidApi::class)
    fun startFlow(deviceName: String?) {
        if (flowJob?.isActive == true) return
        // Fork: a self-hosted server may not ship the tv-login RPCs/edge function/approve page.
        val server = ServerConfigurationRepository.active.value
        if (!server.capabilities.tvLogin) {
            _uiState.value = TvLoginUiState(
                errorMessage = "QR sign-in is not available on this server",
                unsupportedByServer = true,
            )
            return
        }
        _uiState.value = TvLoginUiState(isStarting = true)

        flowJob = scope.launch {
            val deviceNonce = Uuid.random().toString()
            try {
                ensureScaffoldSession()

                val params = buildJsonObject {
                    put("p_device_nonce", deviceNonce)
                    put("p_redirect_base_url", server.tvLoginWebBaseUrl)
                    if (!deviceName.isNullOrBlank()) put("p_device_name", deviceName)
                }
                val start = SupabaseProvider.client.postgrest
                    .rpc("start_tv_login_session", params)
                    .decodeList<TvLoginStartResult>()
                    .firstOrNull()
                    ?: error("Empty response from start_tv_login_session")

                _uiState.value = TvLoginUiState(
                    code = start.code,
                    webUrl = start.webUrl,
                    status = "pending",
                )

                pollUntilApproved(code = start.code, deviceNonce = deviceNonce, intervalSeconds = start.pollIntervalSeconds)
            } catch (e: Exception) {
                log.e(e) { "TV login flow failed" }
                _uiState.value = TvLoginUiState(errorMessage = e.message ?: "TV login failed")
            }
        }
    }

    fun cancel() {
        flowJob?.cancel()
        flowJob = null
        _uiState.value = TvLoginUiState()
    }

    private suspend fun pollUntilApproved(code: String, deviceNonce: String, intervalSeconds: Int) {
        val interval = intervalSeconds.coerceAtLeast(2)
        val maxAttempts = (TV_LOGIN_MAX_POLL_MINUTES * 60) / interval
        repeat(maxAttempts) {
            delay(interval * 1000L)
            val poll = try {
                val params = buildJsonObject {
                    put("p_code", code)
                    put("p_device_nonce", deviceNonce)
                }
                SupabaseProvider.client.postgrest
                    .rpc("poll_tv_login_session", params)
                    .decodeList<TvLoginPollResult>()
                    .firstOrNull()
            } catch (e: Exception) {
                log.w(e) { "TV login poll failed; retrying" }
                null // transient network — keep polling within the deadline
            }

            when (poll?.status) {
                null, "pending" -> {
                    _uiState.value = _uiState.value.copy(status = "pending")
                }
                "approved" -> {
                    _uiState.value = _uiState.value.copy(status = "approved")
                    exchange(code = code, deviceNonce = deviceNonce)
                    return
                }
                else -> { // expired / used / cancelled
                    _uiState.value = TvLoginUiState(
                        errorMessage = when (poll.status) {
                            "expired" -> "The code expired before it was approved. Try again."
                            else -> "This sign-in was ${poll.status}. Try again."
                        }
                    )
                    return
                }
            }
        }
        _uiState.value = TvLoginUiState(errorMessage = "Timed out waiting for approval. Try again.")
    }

    private suspend fun exchange(code: String, deviceNonce: String) {
        val body = buildJsonObject {
            put("code", code)
            put("device_nonce", deviceNonce)
        }
        val response = SupabaseProvider.client.functions.invoke(function = "tv-logins-exchange", body = body)
        val tokens = json.decodeFromString<TvLoginExchangeResult>(response.bodyAsText())
        SupabaseProvider.client.auth.importAuthToken(
            accessToken = tokens.accessToken,
            refreshToken = tokens.refreshToken,
            retrieveUser = true,
            autoRefresh = true,
        )
        _uiState.value = _uiState.value.copy(completed = true)
    }

    /**
     * The backend requires an authenticated caller even to START a login session; a throwaway
     * anonymous Supabase session provides that. AuthRepository's session collector skips
     * anonymous sessions, so this never surfaces in the UI.
     */
    private suspend fun ensureScaffoldSession() {
        val auth = SupabaseProvider.client.auth
        if (auth.currentUserOrNull() != null && auth.currentAccessTokenOrNull() != null) return
        auth.signInAnonymously()
    }
}
