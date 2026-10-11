package com.nuvio.app.core.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class ProfileSettingsCopyPolicyTest {
    private val source = buildJsonObject {
        put("tmdb_enabled", JsonPrimitive(true))
        put("tmdb_language", encodeSyncString("fr"))
        put("tmdb_api_key", encodeSyncString("source-key"))
    }

    @Test
    fun `source settings replace the target and credentials are dropped by default`() {
        val target = buildJsonObject { put("tmdb_enabled", JsonPrimitive(false)) }

        val result = copyingProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, source, target, copyMissingCredentials = false)

        assertEquals(JsonPrimitive(true), result.payload["tmdb_enabled"])
        assertEquals(encodeSyncString("fr"), result.payload["tmdb_language"])
        assertFalse("tmdb_api_key" in result.payload)
        assertEquals(emptyMap(), result.importedFromSource)
    }

    @Test
    fun `a missing credential is imported only when asked for`() {
        val target = buildJsonObject { put("tmdb_api_key", encodeSyncString("   ")) }

        val result = copyingProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, source, target, copyMissingCredentials = true)

        assertEquals(encodeSyncString("source-key"), result.payload["tmdb_api_key"])
        assertEquals(mapOf("tmdb_api_key" to "source-key"), result.importedFromSource)
    }

    @Test
    fun `the target's own credential always survives`() {
        val target = buildJsonObject { put("tmdb_api_key", encodeSyncString("target-key")) }

        for (copyMissing in listOf(false, true)) {
            val result = copyingProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, source, target, copyMissing)

            assertEquals(encodeSyncString("target-key"), result.payload["tmdb_api_key"])
            assertEquals(emptyMap(), result.importedFromSource)
        }
    }

    @Test
    fun `every debrid provider key follows the same rule`() {
        val debridSource = buildJsonObject {
            put("debrid_enabled", JsonPrimitive(true))
            put("debrid_torbox_api_key", encodeSyncString("tb"))
            put("debrid_alldebrid_api_key", encodeSyncString("ad"))
        }
        val debridTarget = buildJsonObject { put("debrid_alldebrid_api_key", encodeSyncString("mine")) }

        val result = copyingProfileCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, debridSource, debridTarget, true)

        assertEquals(encodeSyncString("tb"), result.payload["debrid_torbox_api_key"])
        assertEquals(encodeSyncString("mine"), result.payload["debrid_alldebrid_api_key"])
        assertEquals(mapOf("debrid_torbox_api_key" to "tb"), result.importedFromSource)
    }

    @Test
    fun `features without credential keys are copied verbatim`() {
        val badges = buildJsonObject { put("badges_enabled", JsonPrimitive(true)) }

        val result = copyingProfileCredentials("stream_badge_settings", badges, buildJsonObject { }, true)

        assertEquals(badges, result.payload)
    }
}
