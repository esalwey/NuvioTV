package com.nuvio.app.features.tracking

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Ported verbatim from upstream. The second fake scrobbler only carries a provider *id*; no
 * Simkl code is referenced.
 */
class TrackingScrobbleCoordinatorTest {
    @Test
    fun `fanout isolates one provider failure`() = runBlocking {
        val successful = FakeScrobbler(TrackingProviderId.TRAKT)
        val failing = FakeScrobbler(TrackingProviderId.SIMKL, failure = IllegalStateException("offline"))
        val event = TrackingScrobbleEvent(
            media = TrackingMediaReference(
                kind = TrackingMediaKind.MOVIE,
                ids = TrackingExternalIds(imdb = "tt0111161"),
            ),
            progressPercent = 42.5,
        )

        val failures = dispatchTrackingScrobble(
            scrobblers = listOf(successful, failing),
            profileId = 2,
            action = TrackingScrobbleAction.PAUSE,
            event = event,
        )

        assertEquals(1, successful.callCount)
        assertEquals(1, failing.callCount)
        assertEquals(listOf(TrackingProviderId.SIMKL), failures.map(TrackingScrobbleFailure::providerId))
    }

    @Test
    fun `seek fanout targets only providers that restart scrobbles`() = runBlocking {
        val trakt = FakeScrobbler(
            providerId = TrackingProviderId.TRAKT,
            seekScrobblePolicy = TrackingSeekScrobblePolicy.STOP_AND_RESTART,
        )
        val simkl = FakeScrobbler(TrackingProviderId.SIMKL)
        val event = TrackingScrobbleEvent(
            media = TrackingMediaReference(
                kind = TrackingMediaKind.MOVIE,
                ids = TrackingExternalIds(imdb = "tt0111161"),
            ),
            progressPercent = 55.0,
        )

        dispatchTrackingSeekScrobble(
            scrobblers = listOf(trakt, simkl),
            profileId = 2,
            action = TrackingScrobbleAction.STOP,
            event = event,
        )

        assertEquals(1, trakt.callCount)
        assertEquals(0, simkl.callCount)
    }

    // CW sync #1: the players keep scrobbling Trakt directly, so the coordinator's "other trackers"
    // path must never reach it — a second Trakt start/stop per episode would double every session.
    @Test
    fun `other trackers fanout never reaches Trakt`() = runBlocking {
        val trakt = FakeScrobbler(TrackingProviderId.TRAKT)
        val simkl = FakeScrobbler(TrackingProviderId.SIMKL)
        val event = assertNotNull(
            buildOtherTrackerScrobbleEvent(
                contentType = "series",
                parentMetaId = "tt0944947",
                videoId = "tt0944947:1:3",
                title = "Game of Thrones",
                seasonNumber = 1,
                episodeNumber = 3,
                episodeTitle = "Lord Snow",
                progressPercent = 100.0,
            ),
        )

        val failures = dispatchTrackingScrobble(
            scrobblers = otherTrackerScrobblers(listOf(trakt, simkl)),
            profileId = 1,
            action = TrackingScrobbleAction.STOP,
            event = event,
        )

        assertEquals(0, trakt.callCount)
        assertEquals(1, simkl.callCount)
        assertEquals(TrackingScrobbleAction.STOP, simkl.lastAction)
        assertEquals(100.0, simkl.lastEvent?.progressPercent)
        assertEquals(TrackingEpisode(season = 1, number = 3, title = "Lord Snow"), simkl.lastEvent?.media?.episode)
        assertEquals(emptyList<TrackingScrobbleFailure>(), failures)
    }

    @Test
    fun `other trackers fanout reports a failing tracker instead of throwing`() = runBlocking {
        val simkl = FakeScrobbler(TrackingProviderId.SIMKL, failure = IllegalArgumentException("Simkl series scrobble requires an episode"))
        val event = assertNotNull(
            buildOtherTrackerScrobbleEvent(
                contentType = "series",
                parentMetaId = "tt0944947",
                videoId = null,
                title = "Game of Thrones",
                seasonNumber = null,
                episodeNumber = null,
                episodeTitle = null,
                progressPercent = 12.0,
            ),
        )

        val failures = dispatchTrackingScrobble(
            scrobblers = otherTrackerScrobblers(listOf(FakeScrobbler(TrackingProviderId.TRAKT), simkl)),
            profileId = 1,
            action = TrackingScrobbleAction.START,
            event = event,
        )

        assertEquals(listOf(TrackingProviderId.SIMKL), failures.map(TrackingScrobbleFailure::providerId))
    }

    @Test
    fun `other tracker event does not need an id Trakt can address`() {
        val event = assertNotNull(
            buildOtherTrackerScrobbleEvent(
                contentType = "series",
                parentMetaId = "kitsu:1376",
                videoId = "kitsu:1376:5",
                title = "Death Note",
                seasonNumber = null,
                episodeNumber = 5,
                episodeTitle = null,
                progressPercent = 37.5,
            ),
        )

        assertEquals(1376L, event.media.ids.kitsu)
        assertEquals(TrackingMediaKind.ANIME, event.media.kind)
        assertEquals(5, event.media.episode?.number)
        assertEquals("kitsu:1376:5", event.media.catalog?.videoId)
        assertEquals(37.5, event.progressPercent)
    }

    @Test
    fun `other tracker event needs an id or a title`() {
        assertNull(
            buildOtherTrackerScrobbleEvent(
                contentType = "movie",
                parentMetaId = "custom_catalog_item",
                videoId = null,
                title = "  ",
                seasonNumber = null,
                episodeNumber = null,
                episodeTitle = null,
                progressPercent = 10.0,
            ),
        )
        // A title alone is enough for a tracker's own search.
        assertNotNull(
            buildOtherTrackerScrobbleEvent(
                contentType = "movie",
                parentMetaId = "custom_catalog_item",
                videoId = null,
                title = "Some Film",
                seasonNumber = null,
                episodeNumber = null,
                episodeTitle = null,
                progressPercent = 10.0,
            ),
        )
    }

    @Test
    fun `other tracker event clamps the progress`() {
        fun percent(value: Double): Double? = buildOtherTrackerScrobbleEvent(
            contentType = "movie",
            parentMetaId = "tt0111161",
            videoId = "tt0111161",
            title = "The Shawshank Redemption",
            seasonNumber = null,
            episodeNumber = null,
            episodeTitle = null,
            progressPercent = value,
        )?.progressPercent

        assertEquals(100.0, percent(140.0))
        assertEquals(0.0, percent(-3.0))
        assertEquals(0.0, percent(Double.NaN))
        assertEquals(64.2, percent(64.2))
    }

    // CW sync #1 (review): a stop sent while its start is still on the way reaches the tracker
    // after the start. The players make both calls on the main thread, and each call runs there
    // up to its first suspension, which UNDISPATCHED reproduces.
    @Test
    fun `a stop sent while its start is still on the way reaches the tracker after it`() = runBlocking {
        val dispatch = OrderedScrobbleDispatch(context = Dispatchers.Default)
        val delivered = Channel<String>(Channel.UNLIMITED)
        val startInFlight = CompletableDeferred<Unit>()
        val startReleased = CompletableDeferred<Unit>()

        val start = launch(start = CoroutineStart.UNDISPATCHED) {
            dispatch.send {
                startInFlight.complete(Unit)
                startReleased.await()
                delivered.send("start")
            }
        }
        startInFlight.await()
        val stop = launch(start = CoroutineStart.UNDISPATCHED) {
            dispatch.send { delivered.send("stop") }
        }
        delay(100)
        assertNull(delivered.tryReceive().getOrNull(), "the stop overtook its start")

        startReleased.complete(Unit)
        joinAll(start, stop)
        assertEquals(listOf("start", "stop"), listOf(delivered.receive(), delivered.receive()))
    }

    @Test
    fun `a failed scrobble does not hold up the next one`() = runBlocking {
        val dispatch = OrderedScrobbleDispatch(context = Dispatchers.Default)

        val failure = runCatching { dispatch.send { throw IllegalStateException("offline") } }.exceptionOrNull()

        assertEquals("offline", failure?.message)
        assertEquals("stop", dispatch.send { "stop" })
    }

    private class FakeScrobbler(
        override val providerId: TrackingProviderId,
        override val seekScrobblePolicy: TrackingSeekScrobblePolicy = TrackingSeekScrobblePolicy.NONE,
        private val failure: Throwable? = null,
    ) : TrackingScrobbler {
        var callCount: Int = 0
        var lastAction: TrackingScrobbleAction? = null
        var lastEvent: TrackingScrobbleEvent? = null

        override suspend fun scrobble(
            profileId: Int,
            action: TrackingScrobbleAction,
            event: TrackingScrobbleEvent,
        ) {
            callCount += 1
            lastAction = action
            lastEvent = event
            failure?.let { throw it }
        }
    }
}
