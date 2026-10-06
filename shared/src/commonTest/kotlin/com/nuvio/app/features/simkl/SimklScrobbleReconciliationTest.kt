package com.nuvio.app.features.simkl

import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SimklScrobbleReconciliationTest {
    @Test
    fun `pause replaces local playback without advancing the sync watermark`() {
        val media = showMedia(simklId = 2090L, imdb = "tt1520211")
        val snapshot = SimklSyncSnapshot(
            isInitialized = true,
            watermark = "v1",
            entries = listOf(
                SimklLibraryEntry(
                    mediaType = SimklMediaType.SHOWS,
                    status = SimklListStatus.WATCHING,
                    show = media,
                ),
            ),
            playback = listOf(
                SimklPlaybackSession(
                    id = 4L,
                    progress = 20.0,
                    pausedAt = "2023-11-14T21:00:00Z",
                    type = "episode",
                    episode = SimklPlaybackEpisode(season = 1, number = 2),
                    show = media,
                ),
            ),
        )

        val updated = snapshot.applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.PAUSE,
                playbackId = 8L,
                progress = 45.0,
                mediaType = SimklMediaType.SHOWS,
                media = media,
                episode = SimklPlaybackEpisode(season = 1, number = 2),
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        assertEquals("v1", updated.watermark)
        assertEquals(1, updated.playback.size)
        assertEquals(8L, updated.playback.single().id)
        assertEquals(45.0, updated.playback.single().progress)
        assertEquals("2023-11-14T22:13:20Z", updated.playback.single().pausedAt)
        assertTrue(updated.toSimklWatchedProjection().items.isEmpty())
    }

    @Test
    fun `completed stop records the exact episode and removes its playback`() {
        val media = showMedia(simklId = 2090L, imdb = "tt1520211")
        val snapshot = SimklSyncSnapshot(
            isInitialized = true,
            watermark = "v1",
            entries = listOf(
                SimklLibraryEntry(
                    mediaType = SimklMediaType.SHOWS,
                    status = SimklListStatus.WATCHING,
                    show = media,
                    seasons = listOf(
                        SimklSeason(
                            number = 1,
                            episodes = listOf(SimklEpisode(number = 2)),
                        ),
                    ),
                ),
            ),
            playback = listOf(
                SimklPlaybackSession(
                    id = 8L,
                    progress = 70.0,
                    pausedAt = "2023-11-14T21:00:00Z",
                    type = "episode",
                    episode = SimklPlaybackEpisode(season = 1, number = 2),
                    show = media,
                ),
            ),
        )

        val updated = snapshot.applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.SCROBBLE,
                playbackId = 9L,
                progress = 90.0,
                mediaType = SimklMediaType.SHOWS,
                media = media,
                episode = SimklPlaybackEpisode(season = 1, number = 2),
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        assertEquals("v1", updated.watermark)
        assertTrue(updated.playback.isEmpty())
        assertEquals(1, updated.entries.single().watchedEpisodesCount)
        val watched = updated.toSimklWatchedProjection().items.single()
        assertEquals(1, watched.season)
        assertEquals(2, watched.episode)
        assertEquals(1_700_000_000_000L, watched.markedAtEpochMs)
    }

    @Test
    fun `anime stop updates only the matching Simkl title when siblings share IMDb`() {
        val firstMedia = animeMedia(100L, "tt2560140", 16498L)
        val secondMedia = animeMedia(101L, "tt2560140", 25777L)
        val snapshot = SimklSyncSnapshot(
            entries = listOf(
                animeEntry(firstMedia, season = 1, episode = 3),
                animeEntry(secondMedia, season = 1, episode = 3, tvdbSeason = 2),
            ),
        )

        val updated = snapshot.applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.SCROBBLE,
                playbackId = 12L,
                progress = 95.0,
                mediaType = SimklMediaType.ANIME,
                media = secondMedia,
                episode = SimklPlaybackEpisode(
                    season = 1,
                    number = 3,
                    tvdbSeason = 2,
                    tvdbNumber = 3,
                ),
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        val first = updated.entries.first { it.media?.ids?.simklIdValue() == "100" }
        val second = updated.entries.first { it.media?.ids?.simklIdValue() == "101" }
        assertNull(first.seasons.single().episodes.single().watchedAt)
        assertEquals(
            "2023-11-14T22:13:20Z",
            second.seasons.single().episodes.single().watchedAt,
        )
        val watched = updated.toSimklWatchedProjection().items.single()
        assertEquals(2, watched.season)
        assertEquals(3, watched.episode)
    }

    @Test
    fun `completed movie stop creates watched state without an activities refresh`() {
        val media = SimklMedia(
            title = "Inception",
            year = 2010,
            ids = mapOf(
                "simkl" to JsonPrimitive(472214L),
                "imdb" to JsonPrimitive("tt1375666"),
            ),
        )

        val updated = SimklSyncSnapshot().applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.SCROBBLE,
                playbackId = 15L,
                progress = 95.0,
                mediaType = SimklMediaType.MOVIES,
                media = media,
                episode = null,
                watchedAt = "2023-11-14T21:00:00Z",
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        assertEquals(SimklListStatus.COMPLETED, updated.entries.single().status)
        assertEquals("2023-11-14T21:00:00Z", updated.entries.single().lastWatchedAt)
        assertEquals("tt1375666", updated.toSimklWatchedProjection().items.single().id)
    }

    @Test
    fun `completed anime movie stop stamps a movie entry when the library says anime_type movie`() {
        val media = animeMovieMedia(46409L, "tt0245429", 199L)
        val snapshot = SimklSyncSnapshot(entries = listOf(animeMovieEntry(media)))

        val updated = snapshot.applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.SCROBBLE,
                playbackId = 20L,
                progress = 95.0,
                mediaType = SimklMediaType.ANIME,
                media = media,
                // Simkl still echoes an episode for anime movies; anime_type must win.
                episode = SimklPlaybackEpisode(season = 1, number = 1),
                watchedAt = "2023-11-14T21:00:00Z",
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        val entry = updated.entries.single()
        assertEquals(SimklMediaType.ANIME, entry.mediaType)
        assertEquals("movie", entry.animeType)
        assertEquals(SimklListStatus.COMPLETED, entry.status)
        assertEquals("2023-11-14T21:00:00Z", entry.lastWatchedAt)
        assertTrue(entry.isMovieEntry())
        assertTrue(entry.seasons.isEmpty())
        val watched = updated.toSimklWatchedProjection().items.single()
        assertEquals("movie", watched.type)
        assertEquals("tt0245429", watched.id)
    }

    @Test
    fun `completed anime movie stop without an episode creates a stamped movie entry`() {
        val media = animeMovieMedia(46409L, "tt0245429", 199L)

        val updated = SimklSyncSnapshot().applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.SCROBBLE,
                playbackId = 21L,
                progress = 95.0,
                mediaType = SimklMediaType.ANIME,
                media = media,
                episode = null,
                watchedAt = "2023-11-14T21:00:00Z",
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        val entry = updated.entries.single()
        assertEquals(SimklMediaType.ANIME, entry.mediaType)
        assertEquals("movie", entry.animeType)
        assertEquals(SimklListStatus.COMPLETED, entry.status)
        assertTrue(entry.isMovieEntry())
        assertEquals("movie", updated.toSimklWatchedProjection().items.single().type)
    }

    @Test
    fun `paused anime movie is stored as a movie session not an anime episode`() {
        val media = animeMovieMedia(46409L, "tt0245429", 199L)
        val snapshot = SimklSyncSnapshot(entries = listOf(animeMovieEntry(media)))

        val updated = snapshot.applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.PAUSE,
                playbackId = 22L,
                progress = 45.0,
                mediaType = SimklMediaType.ANIME,
                media = media,
                episode = SimklPlaybackEpisode(season = 1, number = 1),
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        val session = updated.playback.single()
        assertEquals("movie", session.type)
        // Codex-review contract: the media STAYS in the anime field (so the derived mediaType —
        // and thus the Simkl source URL — remains anime); `type == "movie"` is the movie marker,
        // and the echoed episode is dropped rather than carried onto movie progress.
        assertNotNull(session.anime)
        assertNull(session.movie)
        assertNull(session.show)
        assertNull(session.episode)
        assertEquals(SimklMediaType.ANIME, session.mediaType)
        val progress = updated.toSimklProgressEntries().single()
        assertEquals("movie", progress.contentType)
        assertEquals("tt0245429", progress.videoId)
        assertNull(progress.seasonNumber)
        assertNull(progress.episodeNumber)
    }

    @Test
    fun `completed episodic anime with a missing episode is not reclassified as a movie`() {
        // Codex review P1: an explicit animeType "tv" must veto the null-episode movie fallback —
        // a scrobble response missing its episode is incomplete data, not evidence of a movie.
        val media = animeMedia(39687L, "tt2560140", 16498L)
        val snapshot = SimklSyncSnapshot(
            entries = listOf(
                animeEntry(media, season = 1, episode = 3).copy(animeType = "tv"),
            ),
        )

        val updated = snapshot.applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.SCROBBLE,
                playbackId = 24L,
                progress = 95.0,
                mediaType = SimklMediaType.ANIME,
                media = media,
                episode = null,
                watchedAt = "2023-11-14T21:00:00Z",
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        val entry = updated.entries.single()
        assertEquals("tv", entry.animeType)
        assertNull(entry.movie)
        assertFalse(entry.isMovieEntry())
        assertEquals(SimklListStatus.WATCHING, entry.status)
    }

    @Test
    fun `paused episodic anime with a missing episode stays an episode session`() {
        val media = animeMedia(39687L, "tt2560140", 16498L)
        val snapshot = SimklSyncSnapshot(
            entries = listOf(
                animeEntry(media, season = 1, episode = 3).copy(animeType = "tv"),
            ),
        )

        val updated = snapshot.applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.PAUSE,
                playbackId = 25L,
                progress = 40.0,
                mediaType = SimklMediaType.ANIME,
                media = media,
                episode = null,
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        val session = updated.playback.single()
        assertEquals("episode", session.type)
        assertNotNull(session.anime)
        assertNull(session.movie)
        // Incomplete episodic session (no episode coordinates) projects nothing rather than
        // masquerading as movie progress.
        assertTrue(updated.toSimklProgressEntries().isEmpty())
    }

    @Test
    fun `completed episodic anime stop is never treated as a movie`() {
        val media = animeMedia(39687L, "tt2560140", 16498L)
        val snapshot = SimklSyncSnapshot(
            entries = listOf(
                animeEntry(media, season = 1, episode = 3).copy(animeType = "tv"),
            ),
        )

        val updated = snapshot.applyScrobbleResult(
            result = SimklScrobbleResult(
                outcome = SimklScrobbleOutcome.SCROBBLE,
                playbackId = 23L,
                progress = 95.0,
                mediaType = SimklMediaType.ANIME,
                media = media,
                episode = SimklPlaybackEpisode(season = 1, number = 3),
            ),
            committedAtEpochMs = 1_700_000_000_000L,
        )

        val entry = updated.entries.single()
        assertEquals(SimklMediaType.ANIME, entry.mediaType)
        assertEquals("tv", entry.animeType)
        assertNull(entry.movie)
        assertFalse(entry.isMovieEntry())
        assertEquals(
            "2023-11-14T22:13:20Z",
            entry.seasons.single().episodes.single().watchedAt,
        )
        val watched = updated.toSimklWatchedProjection().items.single()
        assertEquals("series", watched.type)
        assertEquals(3, watched.episode)
    }

    private fun showMedia(simklId: Long, imdb: String) = SimklMedia(
        title = "The Walking Dead",
        year = 2010,
        ids = mapOf(
            "simkl" to JsonPrimitive(simklId),
            "imdb" to JsonPrimitive(imdb),
        ),
    )

    private fun animeMedia(simklId: Long, imdb: String, mal: Long) = SimklMedia(
        title = "Attack on Titan",
        year = 2013,
        ids = mapOf(
            "simkl" to JsonPrimitive(simklId),
            "imdb" to JsonPrimitive(imdb),
            "mal" to JsonPrimitive(mal),
        ),
    )

    private fun animeMovieMedia(simklId: Long, imdb: String, mal: Long) = SimklMedia(
        title = "Spirited Away",
        year = 2001,
        ids = mapOf(
            "simkl" to JsonPrimitive(simklId),
            "imdb" to JsonPrimitive(imdb),
            "mal" to JsonPrimitive(mal),
        ),
    )

    /** An anime movie: Simkl keeps it in the anime list and flags it with anime_type. */
    private fun animeMovieEntry(media: SimklMedia) = SimklLibraryEntry(
        mediaType = SimklMediaType.ANIME,
        status = SimklListStatus.WATCHING,
        animeType = "movie",
        show = media,
    )

    private fun animeEntry(
        media: SimklMedia,
        season: Int,
        episode: Int,
        tvdbSeason: Int? = null,
    ) = SimklLibraryEntry(
        mediaType = SimklMediaType.ANIME,
        status = SimklListStatus.WATCHING,
        show = media,
        seasons = listOf(
            SimklSeason(
                number = season,
                episodes = listOf(
                    SimklEpisode(
                        number = episode,
                        tvdb = tvdbSeason?.let { value ->
                            SimklEpisodeMapping(value, episode)
                        },
                    ),
                ),
            ),
        ),
    )
}
