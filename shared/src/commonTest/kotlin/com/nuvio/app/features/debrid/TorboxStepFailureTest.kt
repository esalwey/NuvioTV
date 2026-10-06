package com.nuvio.app.features.debrid

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Regression coverage for BUG-21: TorBox resolve failures collapsed into a bare generic Error
 * ("Could not open this link.") that hid which of the four API calls failed. Every non-Success
 * exit of the TorBox chains now goes through [torboxStepFailure], which names the step and
 * surfaces TorBox's own `error` code + human `detail` from the response envelope.
 */
class TorboxStepFailureTest {

    @Test
    fun `names the step alone when nothing else is known`() {
        assertEquals(
            "TorBox: adding the item failed",
            torboxStepFailure("adding the item").message,
        )
    }

    @Test
    fun `includes http status and the TorBox error code with detail`() {
        val envelope = TorboxEnvelopeDto<Unit>(
            success = false,
            error = "BAD_TOKEN",
            detail = "Your token is invalid or has expired.",
        )
        assertEquals(
            "TorBox: adding the item failed (HTTP 403 · BAD_TOKEN: Your token is invalid or has expired.)",
            torboxStepFailure("adding the item", status = 403, envelope = envelope).message,
        )
    }

    @Test
    fun `omits a 2xx status but keeps the envelope error`() {
        // createtorrent can answer 200 with success=false — the HTTP status adds nothing there.
        val envelope = TorboxEnvelopeDto<Unit>(success = false, error = "ACTIVE_LIMIT")
        assertEquals(
            "TorBox: adding the item failed (ACTIVE_LIMIT)",
            torboxStepFailure("adding the item", status = 200, envelope = envelope).message,
        )
    }

    @Test
    fun `uses the exception text when there is no envelope`() {
        assertEquals(
            "TorBox: network request failed (Timed out)",
            torboxStepFailure("network request", exception = "Timed out").message,
        )
    }

    @Test
    fun `truncates an oversized detail so the toast stays readable`() {
        val envelope = TorboxEnvelopeDto<Unit>(error = "ERR", detail = "x".repeat(500))
        val message = torboxStepFailure("requesting the download link", status = 500, envelope = envelope).message
        assertEquals(
            "TorBox: requesting the download link failed (HTTP 500 · ERR: ${"x".repeat(140)})",
            message,
        )
    }

    @Test
    fun `step message flows through to the playable-result toast`() {
        val resolveError = torboxStepFailure("fetching the file list", status = 500)
        val toast = DirectDebridPlayableResult.Error(resolveError.message).toastMessage()
        assertEquals("TorBox: fetching the file list failed (HTTP 500)", toast)
    }

    @Test
    fun `bare error still falls back to the generic toast`() {
        assertEquals(
            "Could not open this link.",
            DirectDebridPlayableResult.Error().toastMessage(),
        )
    }
}
