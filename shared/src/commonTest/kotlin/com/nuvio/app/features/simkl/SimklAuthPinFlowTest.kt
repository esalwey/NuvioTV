package com.nuvio.app.features.simkl

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Fork-authored coverage for the PIN flow's pure classification helpers in `SimklAuthModels.kt`.
 *
 * The flow itself lives on `SimklAuthRepository`, a Kotlin `object` wired to real network + storage,
 * so it is not unit-testable directly. What is testable — and what actually decides behaviour — are
 * [simklPinPollOutcome] (classifies a poll response body) and [simklPinSession] (turns a PIN request
 * response into a session, applying the documented fallback defaults). Both operate purely on
 * already-decoded wire models, so these tests construct those models directly rather than going
 * through JSON.
 *
 * Deliberately not covered: [SimklPinPollOutcome.Rejected]. That case is decided in
 * `SimklAuthRepository.runDeviceFlow` from the poll's HTTP status (401/403), never from the body —
 * `simklPinPollOutcome` cannot produce it.
 */
class SimklAuthPinFlowTest {
    // -----------------------------------------------------------------------------------------
    // simklPinPollOutcome
    // -----------------------------------------------------------------------------------------

    @Test
    fun `poll outcome is authorized for an OK result with a non blank access token`() {
        val outcome = simklPinPollOutcome(
            SimklPinPollResponse(
                result = "OK",
                accessToken = "abc123",
                tokenType = "bearer",
                expiresIn = 3_600L,
            ),
        )

        assertEquals(
            SimklPinPollOutcome.Authorized(
                accessToken = "abc123",
                tokenType = "bearer",
                expiresInSeconds = 3_600L,
            ),
            outcome,
        )
    }

    @Test
    fun `poll outcome is authorized when a token is present even without an explicit OK result`() {
        // The classifier keys off token presence, not the result field, as long as the body is not
        // itself a KO failure — Simkl's success payload does not reliably echo result="OK".
        val outcome = simklPinPollOutcome(SimklPinPollResponse(accessToken = "  abc123  "))

        assertEquals(
            SimklPinPollOutcome.Authorized(
                accessToken = "abc123",
                tokenType = null,
                expiresInSeconds = null,
            ),
            outcome,
        )
    }

    @Test
    fun `poll outcome is pending while Simkl reports authorization pending`() {
        assertEquals(
            SimklPinPollOutcome.Pending,
            simklPinPollOutcome(SimklPinPollResponse(result = "KO", message = "Authorization pending")),
        )
    }

    @Test
    fun `poll outcome is slow down for a slow down message regardless of case`() {
        assertEquals(
            SimklPinPollOutcome.SlowDown,
            simklPinPollOutcome(SimklPinPollResponse(result = "KO", message = "Slow down")),
        )
        assertEquals(
            SimklPinPollOutcome.SlowDown,
            simklPinPollOutcome(SimklPinPollResponse(result = "KO", message = "SLOW DOWN")),
        )
        assertEquals(
            SimklPinPollOutcome.SlowDown,
            simklPinPollOutcome(SimklPinPollResponse(result = "KO", message = "Please slow down a little")),
        )
    }

    @Test
    fun `poll outcome is pending for an unrecognized KO message`() {
        // Simkl documents no user-facing "denied" state, so an unrecognized KO is treated as
        // transient — the poll loop is bounded by the session's expiry, not by this classification.
        assertEquals(
            SimklPinPollOutcome.Pending,
            simklPinPollOutcome(SimklPinPollResponse(result = "KO", message = "Authorization declined")),
        )
    }

    @Test
    fun `poll outcome is pending for a null response`() {
        // Stands in for a transport failure or an unparseable body: the repository collapses both
        // into a null response before calling this classifier.
        assertEquals(SimklPinPollOutcome.Pending, simklPinPollOutcome(null))
    }

    // -----------------------------------------------------------------------------------------
    // simklPinSession
    // -----------------------------------------------------------------------------------------

    @Test
    fun `pin session parses every field from a fully populated request response`() {
        val session = simklPinSession(
            SimklPinRequestResponse(
                result = "OK",
                deviceCode = "device-code",
                userCode = "ABC-123",
                verificationUrl = "https://simkl.com/pin/",
                expiresIn = 900L,
                interval = 5,
            ),
            nowEpochMs = 1_000L,
        )

        assertEquals(
            SimklPinSession(
                userCode = "ABC-123",
                verificationUrl = "https://simkl.com/pin/",
                expiresAtEpochMs = 1_000L + 900L * 1_000L,
                intervalSeconds = 5,
            ),
            session,
        )
    }

    @Test
    fun `pin session falls back to documented defaults when optional fields are absent`() {
        val session = simklPinSession(
            SimklPinRequestResponse(result = "OK", userCode = "ABC-123"),
            nowEpochMs = 2_000L,
        )

        assertEquals(
            SimklPinSession(
                userCode = "ABC-123",
                verificationUrl = SIMKL_PIN_DEFAULT_VERIFICATION_URL,
                expiresAtEpochMs = 2_000L + SIMKL_PIN_DEFAULT_EXPIRES_IN_SECONDS * 1_000L,
                intervalSeconds = SIMKL_PIN_DEFAULT_INTERVAL_SECONDS,
            ),
            session,
        )
    }

    @Test
    fun `pin session caps an oversized interval at the documented maximum`() {
        val session = simklPinSession(
            SimklPinRequestResponse(result = "OK", userCode = "ABC-123", interval = 120),
            nowEpochMs = 0L,
        )

        assertEquals(SIMKL_PIN_MAX_INTERVAL_SECONDS, session?.intervalSeconds)
    }

    @Test
    fun `pin session is null when Simkl reports a KO result`() {
        assertNull(
            simklPinSession(
                SimklPinRequestResponse(result = "KO", message = "invalid client_id"),
                nowEpochMs = 0L,
            ),
        )
    }

    @Test
    fun `pin session is null when the user code is missing or blank`() {
        assertNull(simklPinSession(SimklPinRequestResponse(result = "OK"), nowEpochMs = 0L))
        assertNull(
            simklPinSession(SimklPinRequestResponse(result = "OK", userCode = "   "), nowEpochMs = 0L),
        )
    }
}
