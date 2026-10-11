package com.nuvio.app.features.servers

import kotlinx.coroutines.runBlocking
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A server episode's watch-progress key (`<series>:<season>:<episode>`) finds its stream on the server. */
class ServerEpisodeProgressKeyTest {
    @AfterTest
    fun tearDown() = removeFakeServer()

    @Test
    fun readsTheSeriesAndTheEpisodeNumbers() {
        val series = ServerItemRef("cfake", "a:b")

        val key = EpisodeProgressKey.parse("${series.encode()}:2:13")

        assertEquals(series, key?.series)
        assertEquals(2, key?.season)
        assertEquals(13, key?.episode)
    }

    @Test
    fun aPlainItemAndAForeignIdAreNotProgressKeys() {
        assertNull(EpisodeProgressKey.parse(ServerItemRef("cfake", "42").encode()))
        assertNull(EpisodeProgressKey.parse("tt0944947:1:1"))
        assertNull(EpisodeProgressKey.parse("srv1:cfake:42:x:1"))
    }

    @Test
    fun theKeyOfAnEpisodeResolvesToItsOwnFile() = runBlocking<Unit> {
        val provider = FakeServerProvider().apply { episodes[1 to 2] = ServerEpisode(itemId = "902", premiereDate = null) }
        val connection = installFakeServer(provider)
        val key = "${ServerItemRef(connection.id, FakeServerProvider.SHOW_ID).encode()}:1:2"

        assertTrue(ServerStreams.canServe("series", key))
        val group = ServerStreams.sources("series", key, season = 1, episode = 2).single().load()

        assertEquals(ServerItemRef(connection.id, "902"), group.streams.single().serverTarget?.item)
    }

    @Test
    fun anEpisodeTheServerDoesNotHaveIsAnEmptyGroup() = runBlocking<Unit> {
        val connection = installFakeServer(FakeServerProvider())
        val key = "${ServerItemRef(connection.id, FakeServerProvider.SHOW_ID).encode()}:9:9"

        val group = ServerStreams.sources("series", key, season = 9, episode = 9).single().load()

        assertTrue(group.streams.isEmpty())
        assertFalse(group.isLoading)
        assertNull(group.error)
    }
}
