package com.nuvio.app.features.home

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The presence-gated [decodeHomeCatalogPayloadPreservingLocalDefaults] whose null return
 * pullFromServer turns into a failed (and therefore retried) sync step. The cached-remote push
 * merge this class used to cover lives in
 * [com.nuvio.app.core.sync.SharedSettingsSyncSupportTest] since the helper was deduplicated.
 */
class HomeCatalogSettingsSyncServiceTest {
    @Test
    fun `malformed remote blob decodes to null so the sync step can fail`() {
        // Not this payload's shape at all: `items` must be an array.
        val malformed = buildJsonObject {
            put("show_catalog_type", true)
            put("items", "not-a-list")
        }

        assertNull(decodeHomeCatalogPayloadPreservingLocalDefaults(malformed, SyncHomeCatalogPayload()))
    }

    @Test
    fun `absent toggle keys preserve the local values instead of resetting to defaults`() {
        // Every local toggle differs from its shipped default so "preserved local" and "fell
        // back to the default" cannot be confused.
        val local = SyncHomeCatalogPayload(
            showCatalogType = false,
            hideUnreleasedContent = true,
            hideCatalogUnderline = true,
            hideDiscover = true,
        )
        val remote = buildJsonObject {
            put("show_catalog_type", true)
            putJsonArray("items") { }
        }

        val decoded = decodeHomeCatalogPayloadPreservingLocalDefaults(remote, local)

        assertEquals(true, decoded?.showCatalogType)
        assertEquals(true, decoded?.hideUnreleasedContent)
        assertEquals(true, decoded?.hideCatalogUnderline)
        assertEquals(true, decoded?.hideDiscover)
    }

    @Test
    fun `present toggle keys override the local values`() {
        val local = SyncHomeCatalogPayload(hideUnreleasedContent = true, hideDiscover = true)
        val remote = buildJsonObject {
            put("hide_unreleased_content", false)
            put("hide_discover", false)
        }

        val decoded = decodeHomeCatalogPayloadPreservingLocalDefaults(remote, local)

        assertEquals(false, decoded?.hideUnreleasedContent)
        assertEquals(false, decoded?.hideDiscover)
    }
}
