package com.nuvio.app.features.servers

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MediaServersControllerTest {
    @AfterTest
    fun tearDown() = removeFakeServer()

    private suspend fun awaitState(predicate: (MediaServersUiState) -> Boolean): MediaServersUiState =
        withContext(Dispatchers.Default) {
            withTimeout(5_000L) {
                while (!predicate(MediaServersController.state.value)) delay(10)
                MediaServersController.state.value
            }
        }

    @Test
    fun listsProvidersBeforeAnythingIsConnected() = runBlocking<Unit> {
        val state = MediaServersController.state.value
        assertEquals(listOf("jellyfin", "emby"), state.providers.map { it.id })
        assertEquals(listOf("10.9", "4.7"), state.providers.map { it.minimumVersion })
    }

    @Test
    fun flattensConnectionsWithoutTheirToken() = runBlocking<Unit> {
        val connection = installFakeServer()

        val state = awaitState { state -> state.servers.any { it.id == connection.id } }
        val server = state.servers.single { it.id == connection.id }

        assertEquals("Box", server.name)
        assertEquals("Fake", server.providerName)
        assertEquals(MediaServerStatus.OK, server.status)
        assertTrue(server.supportsCatalogMetadata)
        assertFalse(server.supportsWatchStateImport)
        assertEquals(listOf("movie", "series"), server.libraries.map { it.kind })
        assertFalse(server.toString().contains("token"))
    }

    @Test
    fun togglesFlowBackThroughTheState() = runBlocking<Unit> {
        val connection = installFakeServer()
        awaitState { state -> state.servers.any { it.id == connection.id } }

        MediaServersController.setEnabled(connection.id, false)
        val disabled = awaitState { state -> state.servers.single { it.id == connection.id }.status == MediaServerStatus.DISABLED }
        assertFalse(disabled.servers.single { it.id == connection.id }.enabled)

        MediaServersController.setEnabled(connection.id, true)
        MediaServersController.setCatalogMetadata(connection.id, true)
        MediaServersController.setLibrarySelected(connection.id, FakeServerProvider.SERIES_LIBRARY.id, false)
        val updated = awaitState { state ->
            state.servers.single { it.id == connection.id }.let { it.useCatalogMetadata && it.libraries.any { library -> !library.selected } }
        }
        val server = updated.servers.single { it.id == connection.id }
        assertTrue(server.enabled)
        assertEquals(listOf(false), server.libraries.filter { it.kind == "series" }.map { it.selected })
    }

    @Test
    fun removingAServerForgetsIt() = runBlocking<Unit> {
        val connection = installFakeServer()
        awaitState { state -> state.servers.any { it.id == connection.id } }

        MediaServersController.remove(connection.id)

        val state = awaitState { state -> state.servers.none { it.id == connection.id } }
        assertTrue(state.servers.none { it.id == connection.id })
    }

    @Test
    fun ignoresSignInsToUnknownProviders() = runBlocking<Unit> {
        MediaServersController.connect("plex", "http://den.local", "viewer", "pw")

        assertFalse(MediaServersController.state.value.isConnecting)
    }
}
