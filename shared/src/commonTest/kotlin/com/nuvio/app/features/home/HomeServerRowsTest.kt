package com.nuvio.app.features.home

import com.nuvio.app.features.addons.AddonCatalog
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.servers.FakeServerProvider
import com.nuvio.app.features.servers.ServerRepository
import com.nuvio.app.features.servers.installFakeServer
import com.nuvio.app.features.servers.removeFakeServer
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Jellyfin / Emby libraries as Home rows: they follow the add-on catalogs, stay off the hero and off the account payload. */
class HomeServerRowsTest {
    @BeforeTest
    fun setUp() {
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsStorage.savePayload("")
        CollectionRepository.clearLocalState()
    }

    @AfterTest
    fun tearDown() {
        removeFakeServer()
        HomeCatalogSettingsRepository.clearLocalState()
        HomeCatalogSettingsStorage.savePayload("")
        CollectionRepository.clearLocalState()
    }

    private fun addon(): ManagedAddon {
        val manifest = AddonManifest(
            id = "row-test-addon",
            name = "Row Test Addon",
            description = "",
            version = "1.0.0",
            resources = listOf(AddonResource(name = "catalog", types = listOf("movie"))),
            types = listOf("movie"),
            catalogs = listOf(AddonCatalog(type = "movie", id = "top", name = "Top")),
            transportUrl = "https://example.com/row-test-addon/manifest.json",
        )
        return ManagedAddon(manifestUrl = manifest.transportUrl, manifest = manifest, enabled = true)
    }

    @Test
    fun everySelectedLibraryIsARowAfterTheAddonCatalogs() {
        val connection = installFakeServer()

        val definitions = buildHomeCatalogDefinitions(listOf(addon()))

        assertEquals("row-test-addon:movie:top", definitions.first().key)
        val serverRows = definitions.filter { it.serverConnectionId == connection.id }
        assertEquals(listOf("Box · Movies", "Box · Shows"), serverRows.map { it.catalogName })
        assertTrue(serverRows.all { it.manifestUrl.isEmpty() && it.supportsPagination })
    }

    @Test
    fun aDisabledServerAddsNoRows() {
        val connection = installFakeServer()
        ServerRepository.setEnabled(connection.id, false)

        val definitions = buildHomeCatalogDefinitions(listOf(addon()))

        assertTrue(definitions.none { it.serverConnectionId != null })
    }

    @Test
    fun serverRowsNeverTakeAHeroSlotAndNeverReachTheAccountPayload() {
        installFakeServer(FakeServerProvider(movieCount = 5))
        HomeCatalogSettingsRepository.syncCatalogs(listOf(addon()))

        val items = HomeCatalogSettingsRepository.uiState.value.items
        val serverItems = items.filter { it.key.startsWith("server:") }
        assertEquals(2, serverItems.size)
        assertTrue(serverItems.none { it.heroSourceEnabled })
        assertNotNull(items.firstOrNull { it.key == "row-test-addon:movie:top" && it.heroSourceEnabled })

        val payload = HomeCatalogSettingsRepository.exportToSyncPayload()
        assertFalse(payload.items.any { it.key.startsWith("server:") })
        assertTrue(payload.items.any { it.key == "row-test-addon:movie:top" })
    }
}
