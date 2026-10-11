package com.nuvio.app.features.servers

import com.nuvio.app.features.streams.StreamItem
import kotlinx.coroutines.runBlocking
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class ServerPlaybackBridgeTest {
    @AfterTest
    fun tearDown() = removeFakeServer()

    @Test
    fun aStreamThatIsNotAServerFileIsReturnedAsItIs() = runBlocking<Unit> {
        val stream = StreamItem(name = "Direct", url = "https://cdn.example/a.mkv", addonName = "Addon", addonId = "addon:a")

        val result = ServerPlaybackBridge.prepare(stream, savedAtEpochMs = 0L)

        assertSame(stream, result.stream)
        assertNull(result.failure)
        assertNull(result.resumePositionMs)
    }

    @Test
    fun preparingAServerFileFillsTheUrlAndReportsANewerServerResumePoint() = runBlocking<Unit> {
        val provider = FakeServerProvider().apply {
            userStates["7"] = listOf(ServerUserState("v7", positionMs = 30_000L, durationMs = 60_000L, played = false, lastPlayedEpochMs = 5_000L))
        }
        val connection = installFakeServer(provider)
        val candidate = ServerStreams.candidates(ServerItemRef(connection.id, "7")).single()

        val newer = ServerPlaybackBridge.prepare(candidate, savedAtEpochMs = 4_000L)
        val prepared = assertNotNull(newer.stream)
        val url = assertNotNull(prepared.playableDirectUrl)
        assertNull(newer.failure)
        assertEquals(30_000L, newer.resumePositionMs)
        assertTrue(ServerPlayback.isServerSource(url))
        ServerPlayback.stop(url)

        val older = ServerPlaybackBridge.prepare(candidate, savedAtEpochMs = 9_000L)
        assertNull(older.resumePositionMs)
        ServerPlayback.stop(assertNotNull(older.stream).playableDirectUrl)
    }

    @Test
    fun aServerThatIsGoneComesBackAsAFailureNotAnException() = runBlocking<Unit> {
        val connection = installFakeServer()
        val candidate = ServerStreams.candidates(ServerItemRef(connection.id, "7")).single()
        removeFakeServer()

        val result = ServerPlaybackBridge.prepare(candidate, savedAtEpochMs = 0L)

        assertNull(result.stream)
        assertEquals(ServerFailure.NOT_FOUND, result.failure)
    }

    @Test
    fun describesTheSessionByItsPlayMethod() = runBlocking<Unit> {
        val direct = installFakeServer(FakeServerProvider())
        val url = assertNotNull(ServerPlayback.prepare(ServerStreams.candidates(ServerItemRef(direct.id, "7")).single()).playableDirectUrl)

        assertEquals("DIRECT_PLAY", ServerPlaybackBridge.playMethod(url))
        assertTrue(ServerPlaybackBridge.transcodeReasons(url).isEmpty())
        assertFalse(ServerPlaybackBridge.canSwitchAudio(url))
        assertNull(ServerPlaybackBridge.playMethod("https://elsewhere.example/x"))
        ServerPlayback.stop(url)
    }

    @Test
    fun aTranscodeOffersItsAudioTracksAndHasNoFurtherFallback() = runBlocking<Unit> {
        val connection = installFakeServer(FakeServerProvider(transcodes = true))
        val url = assertNotNull(ServerPlayback.prepare(ServerStreams.candidates(ServerItemRef(connection.id, "42")).single()).playableDirectUrl)

        assertEquals("TRANSCODE", ServerPlaybackBridge.playMethod(url))
        assertTrue(ServerPlaybackBridge.canSwitchAudio(url))
        assertFalse(ServerPlaybackBridge.canFallBack(url))
        ServerPlayback.stop(url)
    }
}
