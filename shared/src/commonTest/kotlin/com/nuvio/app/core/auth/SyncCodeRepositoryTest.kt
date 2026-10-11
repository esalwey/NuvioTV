package com.nuvio.app.core.auth

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive

class SyncCodeRepositoryTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun pinsMustBeFourToEightCharacters() {
        assertFalse(isValidSyncPin("123"))
        assertTrue(isValidSyncPin("1234"))
        assertTrue(isValidSyncPin("abcd1234"))
        assertFalse(isValidSyncPin("123456789"))
        assertTrue(isValidSyncPin("  1234  "), "surrounding whitespace is trimmed before the check")
    }

    @Test
    fun claimParamsNormaliseTheCodeAndOmitABlankDeviceName() {
        val params = buildClaimSyncCodeParams(code = " abcd-ef12 ", pin = " 1234 ", deviceName = " ")
        assertEquals(JsonPrimitive("ABCD-EF12"), params["p_code"])
        assertEquals(JsonPrimitive("1234"), params["p_pin"])
        assertFalse("p_device_name" in params)

        val named = buildClaimSyncCodeParams(code = "A", pin = "1234", deviceName = "Living room")
        assertEquals(JsonPrimitive("Living room"), named["p_device_name"])
    }

    @Test
    fun pinAndUnlinkParamsUseTheBackendNames() {
        assertEquals(JsonPrimitive("1234"), buildSyncPinParams(" 1234")["p_pin"])
        assertEquals(JsonPrimitive("u-1"), buildUnlinkDeviceParams("u-1")["p_device_user_id"])
    }

    @Test
    fun resultRowsDecodeTheBackendShapes() {
        val claim = json.decodeFromString<ClaimSyncRow>(
            """{"result_owner_id":"o-1","success":true,"message":"ok","extra":1}""",
        )
        assertTrue(claim.success)
        assertEquals("o-1", claim.ownerId)

        val device = json.decodeFromString<LinkedDeviceRow>(
            """{"id":"x","owner_id":"o-1","device_user_id":"d-1","device_name":"Shield","linked_at":"2026-01-01T00:00:00Z"}""",
        )
        assertEquals("d-1", device.deviceUserId)
        assertEquals("Shield", device.deviceName)

        assertEquals("ABCD", json.decodeFromString<SyncCodeRow>("""{"code":"ABCD"}""").code)
    }
}
