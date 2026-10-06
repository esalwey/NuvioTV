package com.nuvio.app.features.simkl

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.addons.httpRequestRaw
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tracking.TrackingAuthProvider
import com.nuvio.app.features.tracking.TrackingCapability
import com.nuvio.app.features.tracking.TrackingProviderDescriptor
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import io.ktor.http.encodeURLParameter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Simkl authentication for the tvOS fork.
 *
 * Upstream's `SimklAuthRepository` runs redirect OAuth2 + PKCE against a `nuvio://auth/simkl`
 * custom-scheme callback. tvOS can neither hand off to a browser nor receive a URL-scheme callback,
 * so that repository is not ported — this is fork-authored code implementing Simkl's **PIN flow**,
 * the one Simkl publishes for TVs. See `SimklAuthModels.kt` for the wire format and for why Trakt's
 * status-code polling ladder does not apply (Simkl signals state in the body of an HTTP 200).
 *
 * Structurally this mirrors `TraktAuthRepository`: same [SupervisorJob] + [Dispatchers.Default] +
 * [uncaughtCoroutineLogger] scope, same `onStartDeviceFlow` / `runDeviceFlow` /
 * `cancelDeviceFlowInternal` shape, same per-profile credential isolation, same
 * `runCatching { … }.onFailure { if (it is CancellationException) throw it; … }` idiom.
 *
 * Threading note (inherited from Trakt and from upstream Simkl): the mutable auth fields are not
 * guarded by a lock. `authorizedAccessToken` / `onUnauthorizedResponse` are non-suspend because
 * `SimklApiClient` takes them as plain function references, and they are only ever reached from the
 * sync spine's single serialized request path.
 */
object SimklAuthRepository : TrackingAuthProvider {
    private const val PIN_PATH = "/oauth/pin"
    private const val TOKEN_EXPIRY_SKEW_MS = 60_000L

    private val log = Logger.withTag("SimklAuth")
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("SimklAuthRepository"))

    private val _uiState = MutableStateFlow(SimklAuthUiState())
    val uiState: StateFlow<SimklAuthUiState> = _uiState.asStateFlow()

    private val _isAuthenticated = MutableStateFlow(false)
    override val isAuthenticated: StateFlow<Boolean> = _isAuthenticated.asStateFlow()

    // Same capability set as upstream's Simkl descriptor (no COMMENTS, no RECOMMENDATIONS — Simkl
    // exposes neither), under TrackingProviderId.SIMKL.
    override val descriptor = TrackingProviderDescriptor(
        id = TrackingProviderId.SIMKL,
        displayName = "Simkl",
        capabilities = setOf(
            TrackingCapability.AUTHENTICATION,
            TrackingCapability.LIBRARY_READ,
            TrackingCapability.LIBRARY_WRITE,
            TrackingCapability.WATCHED_READ,
            TrackingCapability.WATCHED_WRITE,
            TrackingCapability.PROGRESS_READ,
            TrackingCapability.PROGRESS_WRITE,
            TrackingCapability.SCROBBLE,
        ),
    )

    init {
        TrackingProviderRegistry.register(this)
    }

    private var hasLoaded = false
    private var currentProfileId: Int = 1
    private var profileGeneration: Long = 0L
    private var authState = SimklAuthState()

    private var deviceFlowJob: Job? = null
    private var deviceFlowGeneration: Long = 0L
    private var deviceUserCode: String? = null
    private var deviceVerificationUrl: String? = null
    private var deviceExpiresAtMillis: Long? = null

    // TrackingAuthProvider speaks the provider-neutral (no-argument) lifecycle; the fork's
    // per-profile auth isolation lives in the `profileId` overloads below, which stay the
    // authoritative entry points. The no-argument overrides resolve the active profile and
    // delegate, so registry-driven calls cannot silently load another profile's credentials.
    override fun ensureLoaded() {
        ensureLoaded(ProfileRepository.activeProfileId)
    }

    override fun ensureLoaded(profileId: Int) {
        if (hasLoaded && currentProfileId == profileId) return
        loadFromDisk(profileId)
    }

    override fun onProfileChanged() {
        onProfileChanged(ProfileRepository.activeProfileId)
    }

    fun onProfileChanged(profileId: Int) {
        loadFromDisk(profileId)
    }

    override fun clearLocalState() {
        cancelDeviceFlowInternal()
        hasLoaded = false
        currentProfileId = 1
        profileGeneration += 1L
        authState = SimklAuthState()
        publish(isLoading = false, statusMessage = null, errorMessage = null)
    }

    override fun removeStoredProfile(profileId: Int) {
        SimklAuthStorage.removeProfile(profileId)
    }

    fun snapshot(profileId: Int = ProfileRepository.activeProfileId): SimklAuthUiState {
        ensureLoaded(profileId)
        return _uiState.value
    }

    /** The PIN flow authenticates with a client id alone — there is no secret to configure. */
    fun hasRequiredCredentials(): Boolean = SimklConfig.CLIENT_ID.isNotBlank()

    // ---------------------------------------------------------------------
    // PIN flow
    // ---------------------------------------------------------------------

    /**
     * Starts Simkl's PIN flow: requests a user code, publishes it via
     * [SimklAuthUiState.deviceUserCode] / [SimklAuthUiState.deviceVerificationUrl], then polls
     * `/oauth/pin/{user_code}` until the user approves it or the code expires.
     */
    fun onStartDeviceFlow(profileId: Int = ProfileRepository.activeProfileId) {
        ensureLoaded(profileId)
        if (!hasRequiredCredentials()) {
            publish(isLoading = false, errorMessage = "Missing Simkl client ID")
            return
        }
        if (deviceFlowJob?.isActive == true) return
        // Captured here, not inside the coroutine: the body starts on another dispatcher, and a
        // generation read there could already reflect a cancel that happened in between.
        deviceFlowGeneration += 1L
        val flowGeneration = deviceFlowGeneration
        val startProfileGeneration = profileGeneration
        deviceFlowJob = scope.launch {
            runDeviceFlow(profileId, flowGeneration, startProfileGeneration)
        }
    }

    fun onCancelDeviceFlow(profileId: Int = ProfileRepository.activeProfileId) {
        cancelDeviceFlowInternal()
        ensureLoaded(profileId)
        publish(isLoading = false, statusMessage = null, errorMessage = null)
    }

    private suspend fun runDeviceFlow(
        profileId: Int,
        flowGeneration: Long,
        startProfileGeneration: Long,
    ) {
        publish(isLoading = true, statusMessage = null, errorMessage = null)

        val headers = simklRequestHeaders()

        val pinResponse = runCatching {
            httpRequestRaw(
                method = "GET",
                url = pinRequestUrl(),
                headers = headers,
                body = "",
            )
        }.onFailure { error ->
            if (error is CancellationException) throw error
            log.w { "Simkl PIN request failed: ${error.message}" }
        }.getOrNull()

        val session = pinResponse
            ?.takeIf { response -> response.status in 200..299 }
            ?.let { response ->
                runCatching { json.decodeFromString<SimklPinRequestResponse>(response.body) }
                    .onFailure { error -> log.w { "Invalid Simkl PIN response: ${error.message}" } }
                    .getOrNull()
            }
            ?.let { parsed -> simklPinSession(parsed, SimklPlatformClock.nowEpochMs()) }

        if (!isCurrentDeviceFlow(flowGeneration, startProfileGeneration)) return

        if (session == null) {
            clearDeviceFlowState()
            publish(
                isLoading = false,
                statusMessage = null,
                errorMessage = "Could not start Simkl sign in. Try again.",
            )
            return
        }

        deviceUserCode = session.userCode
        deviceVerificationUrl = session.verificationUrl
        deviceExpiresAtMillis = session.expiresAtEpochMs
        publish(isLoading = false, statusMessage = null, errorMessage = null)

        // Poll cadence comes from Simkl's `interval` (5s); the loop is bounded client-side by
        // `expires_in` (900s). Simkl documents no "denied" state, so nothing short of a token or
        // the deadline ends this loop.
        var intervalSeconds = session.intervalSeconds
        val pollUrl = pinPollUrl(session.userCode)

        while (SimklPlatformClock.nowEpochMs() < session.expiresAtEpochMs) {
            delay(intervalSeconds * 1_000L)
            if (!isCurrentDeviceFlow(flowGeneration, startProfileGeneration)) return

            val poll = runCatching {
                httpRequestRaw(
                    method = "GET",
                    url = pollUrl,
                    headers = headers,
                    body = "",
                )
            }.onFailure { error ->
                if (error is CancellationException) throw error
                log.w { "Simkl PIN poll failed: ${error.message}" }
            }.getOrNull()

            if (!isCurrentDeviceFlow(flowGeneration, startProfileGeneration)) return

            // The state lives in the JSON body of an HTTP 200 — this is the one place where the
            // Trakt template must not be copied. Status codes only carry transport-level signals:
            // 429 is a back-off hint, anything else non-2xx is transient and bounded by expiry.
            val outcome = when {
                poll == null -> SimklPinPollOutcome.Pending
                poll.status == 429 -> SimklPinPollOutcome.SlowDown
                poll.status == 401 || poll.status == 403 -> SimklPinPollOutcome.Rejected(poll.status)
                poll.status !in 200..299 -> SimklPinPollOutcome.Pending
                else -> simklPinPollOutcome(
                    runCatching { json.decodeFromString<SimklPinPollResponse>(poll.body) }
                        .onFailure { error -> log.w { "Invalid Simkl PIN poll response: ${error.message}" } }
                        .getOrNull(),
                )
            }

            when (outcome) {
                is SimklPinPollOutcome.Authorized -> {
                    clearDeviceFlowState()
                    applyAuthorizedToken(outcome, profileId)
                    return
                }

                SimklPinPollOutcome.SlowDown -> {
                    intervalSeconds = (intervalSeconds + 1).coerceAtMost(SIMKL_PIN_MAX_INTERVAL_SECONDS)
                }

                is SimklPinPollOutcome.Rejected -> {
                    log.w { "Simkl rejected the PIN poll credentials (HTTP ${outcome.status})" }
                    clearDeviceFlowState()
                    publish(
                        isLoading = false,
                        statusMessage = null,
                        errorMessage = "Simkl refused the connection. Check the Simkl client ID and try again.",
                    )
                    return
                }

                SimklPinPollOutcome.Pending -> Unit
            }
        }

        clearDeviceFlowState()
        publish(
            isLoading = false,
            statusMessage = null,
            errorMessage = "The Simkl code expired. Start again to get a new one.",
        )
    }

    private fun cancelDeviceFlowInternal() {
        deviceFlowGeneration += 1L
        deviceFlowJob?.cancel()
        deviceFlowJob = null
        clearDeviceFlowState()
    }

    private fun clearDeviceFlowState() {
        deviceUserCode = null
        deviceVerificationUrl = null
        deviceExpiresAtMillis = null
    }

    /**
     * True while the in-flight poll loop is still the current one. Guards every mutation after a
     * suspension point so a cancelled flow (profile switch, `clearLocalState`, explicit cancel)
     * cannot publish over the state its replacement just installed.
     */
    private fun isCurrentDeviceFlow(flowGeneration: Long, startProfileGeneration: Long): Boolean =
        flowGeneration == deviceFlowGeneration && startProfileGeneration == profileGeneration

    private suspend fun applyAuthorizedToken(
        outcome: SimklPinPollOutcome.Authorized,
        profileId: Int = currentProfileId,
    ) {
        val nowEpochMs = SimklPlatformClock.nowEpochMs()
        authState = SimklAuthState(
            accessToken = outcome.accessToken,
            tokenType = outcome.tokenType,
            // Simkl's PIN success payload normally omits `expires_in`; honour it when present.
            tokenExpiresAtEpochMs = outcome.expiresInSeconds
                ?.let { seconds -> nowEpochMs + seconds * 1_000L },
            connectedAtEpochMs = nowEpochMs,
        )
        persist(profileId)
        publish(
            isLoading = false,
            statusMessage = "Connected to Simkl",
            errorMessage = null,
        )
        fetchAndStoreUserSettings(profileId)
        SimklSyncRepository.refreshAsync(
            intent = TrackingRefreshIntent.INVALIDATED,
            origin = SimklRefreshOrigin.AUTHORIZATION,
        )
    }

    // ---------------------------------------------------------------------
    // Token access / invalidation (SimklApiClient wiring)
    // ---------------------------------------------------------------------

    /** Passed to `SimklApiClient` as its `accessToken: () -> String?` — must stay non-suspend. */
    internal fun authorizedAccessToken(): String? {
        ensureLoaded()
        val token = authState.accessToken?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val expiresAt = authState.tokenExpiresAtEpochMs
        if (expiresAt != null && SimklPlatformClock.nowEpochMs() >= expiresAt - TOKEN_EXPIRY_SKEW_MS) {
            invalidateCredentials("Your Simkl authorization expired. Connect Simkl again.")
            return null
        }
        return token
    }

    /** Passed to `SimklApiClient` as its `onUnauthorized: () -> Unit` — must stay non-suspend. */
    internal fun onUnauthorizedResponse() {
        invalidateCredentials("Simkl rejected the saved authorization. Connect Simkl again.")
    }

    private fun invalidateCredentials(message: String) {
        val profileId = currentProfileId
        cancelDeviceFlowInternal()
        authState = SimklAuthState()
        persist(profileId)
        SimklSyncRepository.clearLocalState()
        publish(isLoading = false, statusMessage = null, errorMessage = message)
    }

    // ---------------------------------------------------------------------
    // Account
    // ---------------------------------------------------------------------

    /**
     * There is no Simkl revoke endpoint for PIN-issued tokens (and no refresh token to invalidate),
     * so disconnecting is purely local — unlike Trakt's, this needs no coroutine.
     */
    fun onDisconnectRequested(profileId: Int = ProfileRepository.activeProfileId) {
        ensureLoaded(profileId)
        cancelDeviceFlowInternal()
        authState = SimklAuthState()
        persist(profileId)
        SimklSyncRepository.clearLocalState()
        publish(
            isLoading = false,
            statusMessage = "Disconnected from Simkl",
            errorMessage = null,
        )
    }

    suspend fun refreshUserSettings(profileId: Int = ProfileRepository.activeProfileId): String? {
        ensureLoaded(profileId)
        authorizedAccessToken() ?: return null
        return if (fetchAndStoreUserSettings(profileId)) authState.username else null
    }

    /**
     * Called by the sync spine with the `activities` settings watermark, so `/users/settings` is
     * only re-read when Simkl says the account actually changed.
     */
    internal suspend fun synchronizeUserSettings(activityWatermark: String?) {
        authorizedAccessToken() ?: return
        val profileId = currentProfileId
        when (simklSettingsRefreshAction(authState, activityWatermark)) {
            SimklSettingsRefreshAction.NONE -> Unit

            SimklSettingsRefreshAction.RECORD_WATERMARK -> {
                authState = authState.copy(settingsActivityWatermark = activityWatermark)
                persist(profileId)
            }

            SimklSettingsRefreshAction.FETCH -> {
                fetchAndStoreUserSettings(profileId, activityWatermark)
            }
        }
    }

    private suspend fun fetchAndStoreUserSettings(
        profileId: Int = currentProfileId,
        activityWatermark: String? = null,
    ): Boolean {
        val requestedGeneration = profileGeneration
        val response = try {
            SimklApi.client.execute(
                SimklApiRequest(
                    method = SimklHttpMethod.POST,
                    path = "/users/settings",
                ),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w { "Failed to fetch Simkl user settings: ${error.message}" }
            return false
        }

        if (requestedGeneration != profileGeneration) return false

        val settings = runCatching { json.decodeFromString<SimklUserSettingsResponse>(response.body) }
            .onFailure { error -> log.w { "Invalid Simkl user settings response: ${error.message}" } }
            .getOrNull() ?: return false

        authState = authState.copy(
            username = settings.user?.name,
            accountId = settings.account?.id,
            hasFetchedUserSettings = true,
            settingsActivityWatermark = activityWatermark ?: authState.settingsActivityWatermark,
        )
        persist(profileId)
        publish()
        return true
    }

    // ---------------------------------------------------------------------
    // Persistence / publishing
    // ---------------------------------------------------------------------

    private fun loadFromDisk(profileId: Int) {
        cancelDeviceFlowInternal()
        currentProfileId = profileId
        profileGeneration += 1L
        hasLoaded = true

        val payload = SimklAuthStorage.loadPayload(profileId).orEmpty().trim()
        authState = if (payload.isEmpty()) {
            SimklAuthState()
        } else {
            runCatching { json.decodeFromString<SimklAuthState>(payload) }
                .getOrElse { error ->
                    log.w { "Failed to parse Simkl auth payload: ${error.message}" }
                    SimklAuthState()
                }
        }

        val expiresAt = authState.tokenExpiresAtEpochMs
        if (authState.isAuthenticated &&
            expiresAt != null &&
            SimklPlatformClock.nowEpochMs() >= expiresAt - TOKEN_EXPIRY_SKEW_MS
        ) {
            authState = SimklAuthState()
            persist(profileId)
        }

        publish(isLoading = false, statusMessage = null, errorMessage = null)
    }

    private fun persist(profileId: Int = currentProfileId) {
        SimklAuthStorage.savePayload(profileId, json.encodeToString(authState))
    }

    private fun publish(
        isLoading: Boolean = _uiState.value.isLoading,
        statusMessage: String? = _uiState.value.statusMessage,
        errorMessage: String? = _uiState.value.errorMessage,
    ) {
        val authenticated = authState.isAuthenticated
        val mode = when {
            authenticated -> SimklConnectionMode.CONNECTED
            !deviceUserCode.isNullOrBlank() -> SimklConnectionMode.AWAITING_APPROVAL
            else -> SimklConnectionMode.DISCONNECTED
        }

        _isAuthenticated.value = authenticated
        _uiState.value = SimklAuthUiState(
            mode = mode,
            credentialsConfigured = hasRequiredCredentials(),
            isLoading = isLoading,
            username = authState.username,
            deviceUserCode = deviceUserCode,
            deviceVerificationUrl = deviceVerificationUrl,
            deviceExpiresAtMillis = deviceExpiresAtMillis,
            statusMessage = statusMessage,
            errorMessage = errorMessage,
        )
    }

    // ---------------------------------------------------------------------
    // URLs
    // ---------------------------------------------------------------------

    // Built by hand rather than through `buildSimklApiUrl`: the PIN endpoints take `client_id` and
    // nothing else, and the app-name/app-version parameters that helper appends are untested there.
    private fun pinRequestUrl(): String =
        "$SIMKL_API_BASE_URL$PIN_PATH?client_id=${SimklConfig.CLIENT_ID.encodeURLParameter()}"

    private fun pinPollUrl(userCode: String): String =
        "$SIMKL_API_BASE_URL$PIN_PATH/${userCode.trim().encodeURLParameter()}" +
            "?client_id=${SimklConfig.CLIENT_ID.encodeURLParameter()}"
}

@Serializable
private data class SimklUserSettingsResponse(
    val user: SimklUserDto? = null,
    val account: SimklAccountDto? = null,
)

@Serializable
private data class SimklUserDto(
    val name: String? = null,
)

@Serializable
private data class SimklAccountDto(
    val id: Long? = null,
)
