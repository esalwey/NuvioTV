package com.nuvio.app.features.debrid

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * BUG-21 follow-up coverage: [DebridCredentialHealth] is the signal that a stored debrid
 * credential is dead. Only definitive auth statuses may flip it — a flaky server (5xx) or a
 * transport error must never present as "session expired" — and any 2xx self-heals it.
 */
class DebridCredentialHealthTest {

    @AfterTest
    fun reset() {
        // Object state is process-wide; leave it clean for other suites.
        DebridCredentialHealth.clear(DebridProviders.TORBOX_ID)
        DebridCredentialHealth.clear(DebridProviders.PREMIUMIZE_ID)
    }

    @Test
    fun `401 and 403 mark the provider auth-failed`() {
        DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, 403)
        assertTrue(DebridCredentialHealth.isAuthFailed(DebridProviders.TORBOX_ID))

        DebridCredentialHealth.recordHttpStatus(DebridProviders.PREMIUMIZE_ID, 401)
        assertTrue(DebridCredentialHealth.isAuthFailed(DebridProviders.PREMIUMIZE_ID))
    }

    @Test
    fun `a 2xx clears a recorded failure`() {
        DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, 403)
        DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, 200)
        assertFalse(DebridCredentialHealth.isAuthFailed(DebridProviders.TORBOX_ID))
    }

    @Test
    fun `non-auth statuses change nothing in either direction`() {
        DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, 500)
        assertFalse(DebridCredentialHealth.isAuthFailed(DebridProviders.TORBOX_ID))

        DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, 403)
        DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, 500)
        DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, 409)
        assertTrue(
            DebridCredentialHealth.isAuthFailed(DebridProviders.TORBOX_ID),
            "5xx/409 must not clear a real auth failure",
        )
    }

    @Test
    fun `failures are provider-scoped`() {
        DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, 403)
        assertFalse(DebridCredentialHealth.isAuthFailed(DebridProviders.PREMIUMIZE_ID))
    }

    @Test
    fun `clear drops the failure via the key-change hook`() {
        DebridCredentialHealth.recordHttpStatus(DebridProviders.TORBOX_ID, 403)
        DebridCredentialHealth.clear(DebridProviders.TORBOX_ID)
        assertFalse(DebridCredentialHealth.isAuthFailed(DebridProviders.TORBOX_ID))
    }

    @Test
    fun `unknown provider ids are ignored not crashed on`() {
        DebridCredentialHealth.recordHttpStatus("not-a-provider", 403)
        DebridCredentialHealth.recordHttpStatus(null, 403)
        assertFalse(DebridCredentialHealth.isAuthFailed("not-a-provider"))
        assertFalse(DebridCredentialHealth.isAuthFailed(null))
    }
}
