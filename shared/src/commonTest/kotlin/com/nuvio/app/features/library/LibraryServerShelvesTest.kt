package com.nuvio.app.features.library

import com.nuvio.app.features.servers.FakeServerProvider
import com.nuvio.app.features.servers.ServerFailure
import com.nuvio.app.features.servers.ServerRepository
import com.nuvio.app.features.servers.installFakeServer
import com.nuvio.app.features.servers.removeFakeServer
import kotlinx.coroutines.runBlocking
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LibraryServerShelvesTest {
    @AfterTest
    fun tearDown() = removeFakeServer()

    @Test
    fun loadsAShelfForEverySelectedLibrary() = runBlocking<Unit> {
        installFakeServer(FakeServerProvider(movieCount = 5))

        val shelves = loadServerShelves()

        assertEquals(listOf("Box · Movies", "Box · Shows"), shelves.map { it.ref.title })
        assertTrue(shelves.all { it.failure == null && it.section?.items?.size == 5 && it.section?.hasMore == false })
    }

    @Test
    fun reportsAFailingLibraryWithoutHidingTheOthers() = runBlocking<Unit> {
        installFakeServer(FakeServerProvider(movieCount = 5).apply { failingLibraries += "20" })

        val (movies, shows) = loadServerShelves()

        assertEquals(5, movies.section?.items?.size)
        assertNull(shows.section)
        assertEquals(ServerFailure.UNREACHABLE, shows.failure)
    }

    @Test
    fun skipsDisabledServers() = runBlocking<Unit> {
        val connection = installFakeServer()
        ServerRepository.setEnabled(connection.id, false)

        assertTrue(loadServerShelves().isEmpty())
    }
}
