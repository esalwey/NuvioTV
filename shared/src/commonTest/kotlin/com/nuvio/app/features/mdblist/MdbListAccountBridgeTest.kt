package com.nuvio.app.features.mdblist

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

/** The flat account state the TV settings read, through the real tracker singleton. */
class MdbListAccountBridgeTest {
    @Test
    fun `a build without a client id says so instead of failing`() = runBlocking {
        // A developer machine with MDBLIST_CLIENT_ID set would start a real authorization.
        if (MdbListConfig.CLIENT_ID.isNotBlank()) return@runBlocking

        MdbListAccountBridge.ensureLoaded()
        val state = MdbListAccountBridge.state
        assertFalse(state.value.credentialsConfigured)
        assertFalse(state.value.isConnected)

        MdbListAccountBridge.connect()
        val failed = withTimeout(10_000) { state.first { it.errorCode != null } }

        assertEquals(MdbListAccountErrorCodes.MISSING_CLIENT_ID, failed.errorCode)
        assertFalse(failed.isConnected)
        assertNull(failed.userCode)
        assertNull(failed.verificationUrlWithCode)
    }

    @Test
    fun `cancel with no pending code is harmless`() {
        MdbListAccountBridge.ensureLoaded()
        MdbListAccountBridge.cancel()
        assertNull(MdbListAccountBridge.state.value.userCode)
    }
}
