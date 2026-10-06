package com.nuvio.app.core.sync

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

// Pure-function coverage for ProfileSettingsSync's addon-wipe class guard (see
// docs/addon-wipe-investigation-2026-08-28.md). Deliberately does not touch ProfileSettingsSync
// itself — it's a singleton with network/platform dependencies — so this only exercises the
// top-level decision function the observer delegates to.
class ProfileSettingsPushGateTest {
    private val userA = SettingsPullToken(userId = "user-a", profileId = 1)
    private val userAOtherProfile = SettingsPullToken(userId = "user-a", profileId = 2)
    private val userB = SettingsPullToken(userId = "user-b", profileId = 1)

    @Test
    fun `blocks push when neither token exists`() {
        assertFalse(settingsPushAllowed(settledToken = null, currentToken = null))
    }

    @Test
    fun `blocks push when current token is null`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = null))
    }

    @Test
    fun `blocks push when settled token is null`() {
        assertFalse(settingsPushAllowed(settledToken = null, currentToken = userA))
    }

    @Test
    fun `allows push when settled and current tokens match`() {
        assertTrue(settingsPushAllowed(settledToken = userA, currentToken = userA))
    }

    @Test
    fun `blocks push when same user but different profileId`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = userAOtherProfile))
    }

    @Test
    fun `blocks push when same profileId but different userId`() {
        assertFalse(settingsPushAllowed(settledToken = userA, currentToken = userB))
    }
}
