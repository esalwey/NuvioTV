package com.nuvio.app.features.simkl

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Fork-authored Simkl auth models.
 *
 * Upstream's Simkl auth is a redirect OAuth2 + PKCE flow that hands off to a browser and comes back
 * through a `nuvio://auth/simkl` custom-scheme callback. tvOS has neither a browser handoff nor
 * URL-scheme callback delivery, so that flow is unusable here and none of its models (PKCE
 * material, callback parsing, pending-authorization state) are ported.
 *
 * What the fork implements instead is Simkl's **PIN flow**, the one Simkl publishes for TVs:
 *
 * 1. `GET https://api.simkl.com/oauth/pin?client_id={client_id}` →
 *    `{"result":"OK","device_code":…,"user_code":"ABC123","verification_url":"https://simkl.com/pin/","expires_in":900,"interval":5}`
 * 2. `GET https://api.simkl.com/oauth/pin/{user_code}?client_id={client_id}`, every `interval`
 *    seconds until `expires_in` elapses →
 *    - pending: `{"result":"KO","message":"Authorization pending"}`
 *    - polling too fast: `{"result":"KO","message":"Slow down"}`
 *    - approved: `{"result":"OK","access_token":"…"}`
 *
 * `client_id` only — no client secret, no PKCE, no redirect URI.
 *
 * The load-bearing difference from Trakt's device flow: **Simkl signals flow state in the JSON body
 * of an HTTP 200, not by status code.** Trakt's 400/404/409/410/418/429 ladder does not apply and
 * must not be copied. Simkl also documents no "denied" state, so an unrecognized `KO` message is
 * treated as transient and the loop is bounded by `expires_in`.
 */
enum class SimklConnectionMode {
    DISCONNECTED,
    AWAITING_APPROVAL,
    CONNECTED,
}

/**
 * UI-facing auth state. Deliberately shaped like `TraktAuthUiState` (minus the redirect-flow
 * fields) so the tvOS settings pane can clone `TraktViewModel.swift`.
 */
data class SimklAuthUiState(
    val mode: SimklConnectionMode = SimklConnectionMode.DISCONNECTED,
    val credentialsConfigured: Boolean = false,
    val isLoading: Boolean = false,
    val username: String? = null,
    val deviceUserCode: String? = null,
    val deviceVerificationUrl: String? = null,
    val deviceExpiresAtMillis: Long? = null,
    val statusMessage: String? = null,
    val errorMessage: String? = null,
)

/**
 * Persisted, per-profile auth state.
 *
 * Simkl PIN tokens carry no refresh token — the success payload is just an access token — so unlike
 * `TraktAuthState` there is nothing to rotate. [tokenExpiresAtEpochMs] is only populated when Simkl
 * volunteers an `expires_in`; it is normally null (Simkl tokens are long-lived).
 */
@Serializable
internal data class SimklAuthState(
    val accessToken: String? = null,
    val tokenType: String? = null,
    val tokenExpiresAtEpochMs: Long? = null,
    val username: String? = null,
    val accountId: Long? = null,
    val hasFetchedUserSettings: Boolean = false,
    val settingsActivityWatermark: String? = null,
    val connectedAtEpochMs: Long? = null,
) {
    val isAuthenticated: Boolean
        get() = !accessToken.isNullOrBlank()
}

internal enum class SimklSettingsRefreshAction {
    NONE,
    RECORD_WATERMARK,
    FETCH,
}

/**
 * Decides whether a sync pass should re-read `/users/settings`, using the `activities` watermark
 * Simkl publishes for the settings resource. Ported unchanged (modulo the state type) from
 * upstream's `SimklAuthModels.kt` — the watermark semantics are independent of the auth flow.
 */
internal fun simklSettingsRefreshAction(
    state: SimklAuthState,
    activityWatermark: String?,
): SimklSettingsRefreshAction = when {
    activityWatermark.isNullOrBlank() -> SimklSettingsRefreshAction.NONE
    activityWatermark == state.settingsActivityWatermark -> SimklSettingsRefreshAction.NONE
    state.settingsActivityWatermark == null && state.hasFetchedUserSettings -> {
        SimklSettingsRefreshAction.RECORD_WATERMARK
    }
    else -> SimklSettingsRefreshAction.FETCH
}

// ---------------------------------------------------------------------------
// PIN flow wire types
// ---------------------------------------------------------------------------

/** Response to `GET /oauth/pin?client_id=…`. Every field is optional so a `KO` body still parses. */
@Serializable
internal data class SimklPinRequestResponse(
    val result: String? = null,
    @SerialName("device_code") val deviceCode: String? = null,
    @SerialName("user_code") val userCode: String? = null,
    @SerialName("verification_url") val verificationUrl: String? = null,
    @SerialName("expires_in") val expiresIn: Long? = null,
    val interval: Int? = null,
    val message: String? = null,
)

/** Response to `GET /oauth/pin/{user_code}?client_id=…`. */
@Serializable
internal data class SimklPinPollResponse(
    val result: String? = null,
    val message: String? = null,
    @SerialName("access_token") val accessToken: String? = null,
    @SerialName("token_type") val tokenType: String? = null,
    @SerialName("expires_in") val expiresIn: Long? = null,
    val scope: String? = null,
)

/** The client-side view of an in-flight PIN authorization. */
internal data class SimklPinSession(
    val userCode: String,
    val verificationUrl: String,
    val expiresAtEpochMs: Long,
    val intervalSeconds: Int,
)

internal const val SIMKL_PIN_DEFAULT_VERIFICATION_URL = "https://simkl.com/pin/"
internal const val SIMKL_PIN_DEFAULT_EXPIRES_IN_SECONDS = 900L
internal const val SIMKL_PIN_DEFAULT_INTERVAL_SECONDS = 5
internal const val SIMKL_PIN_MAX_INTERVAL_SECONDS = 60

/**
 * Turns an initiate response into a [SimklPinSession], or null when Simkl did not actually issue a
 * code (`result` is `KO`, or `user_code` is missing/blank). Missing `expires_in` / `interval` /
 * `verification_url` fall back to the documented defaults rather than failing the flow.
 */
internal fun simklPinSession(
    response: SimklPinRequestResponse,
    nowEpochMs: Long,
): SimklPinSession? {
    val userCode = response.userCode?.trim()?.takeIf(String::isNotEmpty) ?: return null
    if (response.result?.trim()?.equals("KO", ignoreCase = true) == true) return null

    val expiresInSeconds = response.expiresIn
        ?.takeIf { seconds -> seconds > 0L }
        ?: SIMKL_PIN_DEFAULT_EXPIRES_IN_SECONDS
    val intervalSeconds = response.interval
        ?.takeIf { seconds -> seconds > 0 }
        ?.coerceAtMost(SIMKL_PIN_MAX_INTERVAL_SECONDS)
        ?: SIMKL_PIN_DEFAULT_INTERVAL_SECONDS

    return SimklPinSession(
        userCode = userCode,
        verificationUrl = response.verificationUrl?.trim()?.takeIf(String::isNotEmpty)
            ?: SIMKL_PIN_DEFAULT_VERIFICATION_URL,
        expiresAtEpochMs = nowEpochMs + expiresInSeconds * 1_000L,
        intervalSeconds = intervalSeconds,
    )
}

/** The states a poll can land in. Simkl has no user-facing "denied" state. */
internal sealed interface SimklPinPollOutcome {
    data class Authorized(
        val accessToken: String,
        val tokenType: String?,
        val expiresInSeconds: Long?,
    ) : SimklPinPollOutcome

    /** Not approved yet (or an unrecognized `KO`) — keep polling at the current interval. */
    data object Pending : SimklPinPollOutcome

    /** Simkl asked us to back off — widen the interval, then keep polling. */
    data object SlowDown : SimklPinPollOutcome

    /**
     * The credentials themselves were refused (401/403). Retrying cannot help, so this ends the
     * flow immediately rather than leaving a dead code on screen for the full expiry window.
     *
     * Defensive only — verified against the live API 2026-08-04: Simkl answers 200 with
     * `{"result":"KO","message":"Authorization pending"}` for ANY client id, including a garbage
     * or empty one, at both `/oauth/pin` and `/oauth/pin/{user_code}`. It never validates the
     * client id on these endpoints (that happens when the user approves at simkl.com/pin), so
     * this branch does not fire today. A misconfigured client id therefore shows a code that
     * simply never approves, bounded by the 900s expiry — there is no client-side fast-fail
     * available. Kept in case Simkl tightens this later.
     */
    data class Rejected(val status: Int) : SimklPinPollOutcome
}

/**
 * Classifies a poll body. Note that this reads the JSON, never a status code: Simkl answers 200 for
 * pending, slow-down, and success alike.
 *
 * A null response (transport failure or unparseable body) is [SimklPinPollOutcome.Pending] — the
 * caller's expiry deadline is what ends the loop, not a single bad response.
 */
internal fun simklPinPollOutcome(response: SimklPinPollResponse?): SimklPinPollOutcome {
    if (response == null) return SimklPinPollOutcome.Pending

    val accessToken = response.accessToken?.trim()?.takeIf(String::isNotEmpty)
    val isFailureResult = response.result?.trim()?.equals("KO", ignoreCase = true) == true
    if (accessToken != null && !isFailureResult) {
        return SimklPinPollOutcome.Authorized(
            accessToken = accessToken,
            tokenType = response.tokenType?.trim()?.takeIf(String::isNotEmpty),
            expiresInSeconds = response.expiresIn?.takeIf { seconds -> seconds > 0L },
        )
    }

    val message = response.message?.trim()?.lowercase().orEmpty()
    return if (message.contains("slow down")) {
        SimklPinPollOutcome.SlowDown
    } else {
        SimklPinPollOutcome.Pending
    }
}
