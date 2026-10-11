package com.nuvio.app.features.home

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Discover can live nowhere, in Search or in the sidebar. It is stored as the older "hide Discover"
 * switch plus a sidebar flag, so a client that only knows the switch keeps working.
 */
class DiscoverLocationTest {
    @Test
    fun `the old switch alone maps to off and in search`() {
        assertEquals(DiscoverLocation.IN_SEARCH, discoverLocationOf(hideDiscover = false, inSidebar = false))
        assertEquals(DiscoverLocation.OFF, discoverLocationOf(hideDiscover = true, inSidebar = false))
    }

    @Test
    fun `the sidebar flag only counts while discover is hidden in search`() {
        assertEquals(DiscoverLocation.IN_SIDEBAR, discoverLocationOf(hideDiscover = true, inSidebar = true))
        // An older client showed Discover in Search again without knowing the sidebar flag.
        assertEquals(DiscoverLocation.IN_SEARCH, discoverLocationOf(hideDiscover = false, inSidebar = true))
    }

    @Test
    fun `ui state derives the location from its two switches`() {
        assertEquals(DiscoverLocation.IN_SEARCH, HomeCatalogSettingsUiState().discoverLocation)
        assertEquals(DiscoverLocation.OFF, HomeCatalogSettingsUiState(hideDiscover = true).discoverLocation)
        assertEquals(
            DiscoverLocation.IN_SIDEBAR,
            HomeCatalogSettingsUiState(hideDiscover = true, discoverInSidebar = true).discoverLocation,
        )
    }

    @Test
    fun `a location change changes the signature so listeners republish`() {
        val off = HomeCatalogSettingsUiState(hideDiscover = true)
        val sidebar = off.copy(discoverInSidebar = true)
        assert(off.signature != sidebar.signature)
    }

    @Test
    fun `a blob from a client without the sidebar flag keeps the local sidebar flag`() {
        val local = SyncHomeCatalogPayload(hideDiscover = true, discoverInSidebar = true)
        val remote = buildJsonObject { put("hide_discover", true) }

        val decoded = decodeHomeCatalogPayloadPreservingLocalDefaults(remote, local)

        assertEquals(true, decoded?.hideDiscover)
        assertEquals(true, decoded?.discoverInSidebar)
    }

    @Test
    fun `a blob that carries the sidebar flag overrides the local one`() {
        val local = SyncHomeCatalogPayload(hideDiscover = true, discoverInSidebar = true)
        val remote = buildJsonObject {
            put("hide_discover", true)
            put("discover_in_sidebar", false)
        }

        val decoded = decodeHomeCatalogPayloadPreservingLocalDefaults(remote, local)

        assertEquals(DiscoverLocation.OFF, discoverLocationOf(decoded!!.hideDiscover, decoded.discoverInSidebar))
    }

    @Test
    fun `an old blob with only hide_discover maps to off or in search`() {
        val hidden = decodeHomeCatalogPayloadPreservingLocalDefaults(
            buildJsonObject { put("hide_discover", true) },
            SyncHomeCatalogPayload(),
        )
        val shown = decodeHomeCatalogPayloadPreservingLocalDefaults(
            buildJsonObject { put("hide_discover", false) },
            SyncHomeCatalogPayload(),
        )

        assertEquals(DiscoverLocation.OFF, discoverLocationOf(hidden!!.hideDiscover, hidden.discoverInSidebar))
        assertEquals(DiscoverLocation.IN_SEARCH, discoverLocationOf(shown!!.hideDiscover, shown.discoverInSidebar))
    }
}
