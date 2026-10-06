package com.nuvio.app.core.sync

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The pure push merge shared by the shared-namespace settings sync services (ported from
 * upstream `f9c13a9b`); these cases moved here from the per-service test classes when the
 * duplicated helpers were extracted.
 */
class SharedSettingsSyncSupportTest {
    @Test
    fun `shared settings merge preserves unknown remote fields`() {
        val remote = buildJsonObject {
            put("future_setting", "preserved")
            put("show_catalog_type", false)
        }
        val local = buildJsonObject {
            put("show_catalog_type", true)
            put("hide_unreleased_content", true)
        }

        val merged = mergeSharedSettingsJson(remoteJson = remote, localJson = local)

        assertEquals("preserved", merged.getValue("future_setting").jsonPrimitive.content)
        assertEquals(true, merged.getValue("show_catalog_type").jsonPrimitive.content.toBoolean())
        assertEquals(true, merged.getValue("hide_unreleased_content").jsonPrimitive.content.toBoolean())
    }

    @Test
    fun `null remote json falls back to local only`() {
        val local = buildJsonObject {
            put("show_catalog_type", true)
        }

        val merged = mergeSharedSettingsJson(remoteJson = null, localJson = local)

        assertEquals(1, merged.size)
        assertEquals(true, merged.getValue("show_catalog_type").jsonPrimitive.content.toBoolean())
    }
}
