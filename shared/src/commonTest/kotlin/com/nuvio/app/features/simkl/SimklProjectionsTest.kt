package com.nuvio.app.features.simkl

import com.nuvio.app.features.tracking.TrackingMediaKind
import com.nuvio.app.features.tracking.TrackingMembershipRemovalImpact
import com.nuvio.app.features.watched.watchedItemKey
import com.nuvio.app.features.watchprogress.WatchProgressSourceSimklPlayback
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SimklProjectionsTest {
    @Test
    fun `library presentation uses status names without a provider prefix`() {
        assertEquals(
            listOf("Watching", "Plan to Watch", "On Hold", "Completed", "Dropped"),
            simklLibraryStatusDefinitions.map { definition -> definition.title },
        )
    }

    @Test
    fun `library projection exposes every populated status with attribution`() {
        val plan = entry(
            type = SimklMediaType.MOVIES,
            status = SimklListStatus.PLAN_TO_WATCH,
            id = 53536,
            imdb = "tt0181852",
            slug = "terminator-3-rise-of-the-machines",
            addedAt = "2023-11-14T22:13:20Z",
        )
        val completed = entry(
            type = SimklMediaType.MOVIES,
            status = SimklListStatus.COMPLETED,
            id = 53434,
            imdb = "tt0068646",
        )
        val watching = entry(
            type = SimklMediaType.SHOWS,
            status = SimklListStatus.WATCHING,
            id = 2090,
            imdb = "tt1520211",
        )

        val projection = SimklSyncSnapshot(entries = listOf(plan, completed, watching)).toSimklLibraryProjection()
        val watchingDefinition = simklLibraryStatusDefinitions.single { definition ->
            definition.status == SimklListStatus.WATCHING
        }
        val planDefinition = simklLibraryStatusDefinitions.single { definition ->
            definition.status == SimklListStatus.PLAN_TO_WATCH
        }
        val completedDefinition = simklLibraryStatusDefinitions.single { definition ->
            definition.status == SimklListStatus.COMPLETED
        }

        assertEquals(
            listOf(watchingDefinition.key, planDefinition.key, completedDefinition.key),
            projection.sections.map { section -> section.type },
        )
        assertEquals(3, projection.items.size)
        val item = projection.items.single { candidate -> candidate.id == "tt0181852" }
        assertEquals("tt0181852", item.id)
        assertEquals(setOf(planDefinition.key), item.listKeys)
        assertEquals("simkl", item.trackingProviderId)
        assertEquals("simkl:53536", item.trackingProviderItemId)
        assertEquals(
            "https://simkl.com/movies/53536/terminator-3-rise-of-the-machines",
            item.trackingSourceUrl,
        )
        assertTrue(item.poster.orEmpty().contains("simkl.in/posters/12/poster_m.webp"))
        assertFalse(item.poster.orEmpty().contains("_w.webp"))
        assertEquals(1_700_000_000_000L, item.savedAtEpochMs)
        assertEquals(
            setOf(completedDefinition.key),
            projection.items.single { candidate -> candidate.id == "tt0068646" }.listKeys,
        )
        assertEquals(
            setOf(watchingDefinition.key),
            projection.items.single { candidate -> candidate.id == "tt1520211" }.listKeys,
        )
        assertTrue(watchingDefinition.isMembershipDestination)
        assertTrue(planDefinition.isMembershipDestination)
        assertFalse(completedDefinition.isMembershipDestination)
    }

    @Test
    fun `watched projection includes movie events rich episodes and completed series marker`() {
        val movie = entry(
            type = SimklMediaType.MOVIES,
            status = SimklListStatus.COMPLETED,
            id = 53536,
            imdb = "tt0181852",
            lastWatchedAt = "2023-11-14T22:13:20Z",
        )
        val richShow = entry(
            type = SimklMediaType.SHOWS,
            status = SimklListStatus.WATCHING,
            id = 2090,
            imdb = "tt1520211",
            seasons = listOf(
                SimklSeason(
                    number = 1,
                    episodes = listOf(
                        SimklEpisode(number = 1, watchedAt = "2023-11-14T23:13:20Z"),
                        SimklEpisode(number = 2, watchedAt = null),
                    ),
                ),
            ),
        )
        val summaryOnlyCompletedShow = entry(
            type = SimklMediaType.ANIME,
            status = SimklListStatus.COMPLETED,
            id = 39687,
            imdb = "tt2560140",
            lastWatchedAt = "2023-11-15T00:13:20Z",
        )

        val projection = SimklSyncSnapshot(
            entries = listOf(movie, richShow, summaryOnlyCompletedShow),
        ).toSimklWatchedProjection()

        assertEquals(3, projection.items.size)
        val movieEvent = assertNotNull(projection.items.singleOrNull { it.type == "movie" })
        assertEquals("simkl", movieEvent.trackingProviderId)
        assertEquals("simkl:53536", movieEvent.trackingProviderItemId)
        assertEquals("https://simkl.com/movies/53536", movieEvent.trackingSourceUrl)
        val episode = projection.items.single { it.season == 1 && it.episode == 1 }
        assertEquals("tt1520211", episode.id)
        assertFalse(projection.items.any { it.episode == 2 })
        assertTrue(projection.items.any { it.id == "tt2560140" && it.season == null })
        assertTrue(projection.fullyWatchedSeriesKeys.any { "tt2560140" in it })
    }

    @Test
    fun `summary counters do not fabricate exact episode markers`() {
        val summary = entry(
            type = SimklMediaType.SHOWS,
            status = SimklListStatus.WATCHING,
            id = 2090,
            imdb = "tt1520211",
            lastWatchedAt = "2023-11-14T23:13:20Z",
        ).copy(
            lastWatched = "S01E03",
            nextToWatch = "S01E04",
            watchedEpisodesCount = 3,
            totalEpisodesCount = 6,
        )

        val projection = SimklSyncSnapshot(entries = listOf(summary)).toSimklWatchedProjection()

        assertTrue(projection.items.isEmpty())
        assertTrue(projection.fullyWatchedSeriesKeys.isEmpty())
    }

    @Test
    fun `anime watched projection prefers mapped tvdb coordinates`() {
        val anime = entry(
            type = SimklMediaType.ANIME,
            status = SimklListStatus.WATCHING,
            id = 439744,
            imdb = "tt2560140",
            seasons = listOf(
                SimklSeason(
                    number = 1,
                    episodes = listOf(
                        SimklEpisode(
                            number = 4,
                            watchedAt = "2023-11-14T23:13:20Z",
                            tvdb = SimklEpisodeMapping(season = 2, episode = 4),
                        ),
                    ),
                ),
            ),
        )

        val watched = SimklSyncSnapshot(entries = listOf(anime))
            .toSimklWatchedProjection()
            .items
            .single()

        assertEquals(2, watched.season)
        assertEquals(4, watched.episode)
    }

    @Test
    fun `anime movies project a movie watched item just like a regular movie`() {
        val animeMovie = entry(
            type = SimklMediaType.ANIME,
            status = SimklListStatus.COMPLETED,
            id = 46409,
            imdb = "tt0245429",
            lastWatchedAt = "2023-11-14T22:13:20Z",
            animeType = "movie",
        )

        val projection = SimklSyncSnapshot(entries = listOf(animeMovie)).toSimklWatchedProjection()

        val watched = assertNotNull(projection.items.singleOrNull())
        assertEquals("movie", watched.type)
        assertEquals("tt0245429", watched.id)
        assertNull(watched.season)
        assertNull(watched.episode)
        assertEquals("https://simkl.com/anime/46409", watched.trackingSourceUrl)
        // An anime movie is never a "fully watched series".
        assertTrue(projection.fullyWatchedSeriesKeys.isEmpty())
    }

    @Test
    fun `anime movies use movie alternate keys and are skipped by the anime series keys`() {
        val animeMovie = entry(
            type = SimklMediaType.ANIME,
            status = SimklListStatus.COMPLETED,
            id = 46409,
            imdb = "tt0245429",
            mal = 199,
            lastWatchedAt = "2023-11-14T22:13:20Z",
            animeType = "movie",
        )
        val snapshot = SimklSyncSnapshot(entries = listOf(animeMovie))

        assertTrue(snapshot.animeAlternateWatchedKeys().isEmpty())
        val movieKeys = snapshot.movieAlternateWatchedKeys()
        assertTrue(movieKeys.contains(watchedItemKey("movie", "mal:199")))
        assertTrue(movieKeys.contains(watchedItemKey("movie", "simkl:46409")))
    }

    @Test
    fun `episodic anime entries stay series across every projection`() {
        val animeSeries = entry(
            type = SimklMediaType.ANIME,
            status = SimklListStatus.COMPLETED,
            id = 39687,
            imdb = "tt2560140",
            mal = 16498,
            lastWatchedAt = "2023-11-14T22:13:20Z",
            animeType = "tv",
            seasons = listOf(
                SimklSeason(
                    number = 1,
                    episodes = listOf(SimklEpisode(number = 1, watchedAt = "2023-11-14T23:13:20Z")),
                ),
            ),
        )
        val snapshot = SimklSyncSnapshot(entries = listOf(animeSeries))

        val projection = snapshot.toSimklWatchedProjection()
        assertTrue(projection.items.all { item -> item.type == "series" })
        assertTrue(projection.fullyWatchedSeriesKeys.any { key -> "tt2560140" in key })
        assertTrue(snapshot.animeAlternateWatchedKeys().contains(watchedItemKey("series", "mal:16498")))
        assertTrue(snapshot.movieAlternateWatchedKeys().isEmpty())
    }

    @Test
    fun `anime playback without an episode projects movie progress`() {
        val session = SimklPlaybackSession(
            id = 777,
            progress = 30.0,
            pausedAt = "2024-04-30T22:13:00.250Z",
            type = "movie",
            episode = null,
            anime = media(id = 46409, imdb = "tt0245429", runtime = 125),
        )

        val entry = SimklSyncSnapshot(playback = listOf(session)).toSimklProgressEntries().single()

        assertEquals("movie", entry.contentType)
        assertEquals("movie", entry.parentMetaType)
        assertEquals("tt0245429", entry.parentMetaId)
        assertEquals("tt0245429", entry.videoId)
        assertNull(entry.seasonNumber)
        assertNull(entry.episodeNumber)
    }

    @Test
    fun `episodic anime playback with a missing episode projects nothing`() {
        // Codex review of the 6e5e41f3 port: only the session's explicit `type == "movie"`
        // marks an anime session as a movie. An episodic (or untyped) anime session that lost
        // its episode details is incomplete data and must be discarded, not emitted as movie
        // progress.
        val episodic = SimklPlaybackSession(
            id = 778,
            progress = 30.0,
            pausedAt = "2024-04-30T22:13:00.250Z",
            type = "episode",
            episode = null,
            anime = media(id = 39687, imdb = "tt2560140", runtime = 24),
        )
        val untyped = episodic.copy(id = 779, type = null)

        assertTrue(
            SimklSyncSnapshot(playback = listOf(episodic, untyped)).toSimklProgressEntries().isEmpty(),
        )
    }

    @Test
    fun `untyped anime playback with an episode projects movie progress when library marks it a movie`() {
        // Ported from upstream 54aa75ea: a session with no `type == "movie"` marker and a
        // (spurious) non-null episode can still be recognized as an anime movie by
        // cross-referencing the user's Simkl library for a matching anime-movie entry.
        val libraryEntry = entry(
            type = SimklMediaType.ANIME,
            status = SimklListStatus.COMPLETED,
            id = 46409,
            imdb = "tt0245429",
            animeType = "movie",
        )
        val session = SimklPlaybackSession(
            id = 780,
            progress = 30.0,
            pausedAt = "2024-04-30T22:13:00.250Z",
            type = null,
            episode = SimklPlaybackEpisode(season = 1, number = 1),
            anime = media(id = 46409, imdb = "tt0245429", runtime = 125),
        )

        val entry = SimklSyncSnapshot(entries = listOf(libraryEntry), playback = listOf(session))
            .toSimklProgressEntries()
            .single()

        assertEquals("movie", entry.contentType)
        assertEquals("movie", entry.parentMetaType)
        assertEquals("tt0245429", entry.parentMetaId)
        // videoId is the bare parent id for a movie classification, even though the session
        // carried a (spurious, ignored) season/episode marker — and the coordinates are dropped,
        // so the entry never reads as an episode downstream (CW badge, stream picker, scrobble).
        assertEquals("tt0245429", entry.videoId)
        assertNull(entry.seasonNumber)
        assertNull(entry.episodeNumber)
        assertNull(entry.episodeTitle)
    }

    @Test
    fun `explicit episode anime playback stays series progress even with a matching library movie entry`() {
        // Ported from upstream 54aa75ea: a session with no `type == "movie"` marker and a
        // (spurious) non-null episode can still be recognized as an anime movie by
        // cross-referencing the user's Simkl library for a matching anime-movie entry.
        val libraryEntry = entry(
            type = SimklMediaType.ANIME,
            status = SimklListStatus.COMPLETED,
            id = 46409,
            imdb = "tt0245429",
            animeType = "movie",
        )
        val session = SimklPlaybackSession(
            id = 780,
            progress = 30.0,
            pausedAt = "2024-04-30T22:13:00.250Z",
            type = "episode",
            episode = SimklPlaybackEpisode(season = 1, number = 1),
            anime = media(id = 46409, imdb = "tt0245429", runtime = 125),
        )

        val entry = SimklSyncSnapshot(entries = listOf(libraryEntry), playback = listOf(session))
            .toSimklProgressEntries()
            .single()

        assertEquals("series", entry.contentType)
        assertEquals("series", entry.parentMetaType)
        assertEquals("tt0245429", entry.parentMetaId)
        assertEquals(1, entry.seasonNumber)
        assertEquals(1, entry.episodeNumber)
    }

    @Test
    fun `untyped anime playback with an episode projects series progress without a matching library movie entry`() {
        // Control for the library cross-reference above: same session, but with no library
        // entry (or a non-movie one) to cross-reference against — prior behaviour is preserved,
        // the session projects as ordinary series progress.
        val session = SimklPlaybackSession(
            id = 781,
            progress = 30.0,
            pausedAt = "2024-04-30T22:13:00.250Z",
            type = null,
            episode = SimklPlaybackEpisode(season = 1, number = 1),
            anime = media(id = 46409, imdb = "tt0245429", runtime = 125),
        )

        val entry = SimklSyncSnapshot(playback = listOf(session)).toSimklProgressEntries().single()

        assertEquals("series", entry.contentType)
        assertEquals(1, entry.seasonNumber)
        assertEquals(1, entry.episodeNumber)
    }

    @Test
    fun `anime playback with an episode still projects series progress`() {
        val session = SimklPlaybackSession(
            id = 778,
            progress = 30.0,
            pausedAt = "2024-04-30T22:13:00.250Z",
            type = "episode",
            episode = SimklPlaybackEpisode(season = 1, number = 4),
            anime = media(id = 39687, imdb = "tt2560140", runtime = 24),
        )

        val entry = SimklSyncSnapshot(playback = listOf(session)).toSimklProgressEntries().single()

        assertEquals("series", entry.contentType)
        assertEquals(1, entry.seasonNumber)
        assertEquals(4, entry.episodeNumber)
    }

    @Test
    fun `playback projection preserves Simkl session identity and percentage`() {
        val session = SimklPlaybackSession(
            id = 12345,
            progress = 42.2,
            pausedAt = "2024-04-30T22:13:00.250Z",
            type = "episode",
            episode = SimklPlaybackEpisode(
                season = 1,
                number = 3,
                title = "Chapter Three",
            ),
            show = media(id = 39687, imdb = "tt4574334", runtime = 50),
        )

        val entry = SimklSyncSnapshot(playback = listOf(session)).toSimklProgressEntries().single()

        assertEquals("tt4574334", entry.parentMetaId)
        assertEquals(1, entry.seasonNumber)
        assertEquals(3, entry.episodeNumber)
        assertEquals(42.2f, entry.progressPercent)
        // Upstream a298f2d72: no duration is invented from the show runtime, so the resume goes
        // through the percentage: the player scales it by the duration of the episode it opened.
        assertEquals(0L, entry.durationMs)
        assertEquals(0L, entry.lastPositionMs)
        assertEquals(0.422f, entry.progressFraction, 0.0005f)
        assertEquals("simkl-playback:12345", entry.progressKey)
        assertEquals(WatchProgressSourceSimklPlayback, entry.source)
        assertEquals("simkl", entry.trackingProviderId)
        assertEquals("simkl:39687", entry.trackingProviderItemId)
        assertEquals("https://simkl.com/tv/39687", entry.trackingSourceUrl)
        assertTrue(entry.poster.orEmpty().contains("simkl.in/posters/12/poster_m.webp"))
        assertFalse(entry.isCompleted)
        assertEquals(1_714_515_180_250L, entry.lastUpdatedEpochMs)
    }

    @Test
    fun `movie playback keeps the runtime scaled position`() {
        val session = SimklPlaybackSession(
            id = 777,
            progress = 25.0,
            pausedAt = "2024-04-30T22:13:00Z",
            movie = media(id = 472214, imdb = "tt1375666", runtime = 100),
        )

        val entry = SimklSyncSnapshot(playback = listOf(session)).toSimklProgressEntries().single()

        assertEquals("movie", entry.contentType)
        assertEquals(6_000_000L, entry.durationMs)
        assertEquals(1_500_000L, entry.lastPositionMs)
        assertEquals(0.25f, entry.progressFraction, 0.0005f)
        // The player-side resume helper the tvOS engines use for rows without a position.
        assertEquals(1_500_000L, entry.resolveResumePosition(actualDurationMs = 6_000_000L))
    }

    @Test
    fun `episode playback resumes from the percentage of the opened file`() {
        val session = SimklPlaybackSession(
            id = 778,
            progress = 83.0,
            pausedAt = "2024-04-30T22:13:00Z",
            type = "episode",
            episode = SimklPlaybackEpisode(season = 2, number = 5),
            show = media(id = 39687, imdb = "tt4574334", runtime = 52),
        )

        val entry = SimklSyncSnapshot(playback = listOf(session)).toSimklProgressEntries().single()

        assertEquals(0L, entry.durationMs)
        // 83 % of a 47-minute episode (2 340 600 ms), not of the show's 52-minute runtime.
        val resumedMs = entry.resolveResumePosition(actualDurationMs = 2_820_000L)
        assertTrue(resumedMs in 2_340_000L..2_341_000L, "resumed at $resumedMs")
    }

    @Test
    fun `media reference retains anime catalog and all accepted ids`() {
        val anime = entry(
            type = SimklMediaType.ANIME,
            status = SimklListStatus.WATCHING,
            id = 39687,
            imdb = "tt2560140",
            mal = 16498,
        )
        val snapshot = SimklSyncSnapshot(entries = listOf(anime))

        val reference = snapshot.mediaReference(
            contentId = "tt2560140",
            contentType = "series",
            season = 2,
            episode = 4,
            posterUrl = "https://catalog.example/anime.webp",
        )

        assertEquals(TrackingMediaKind.ANIME, reference.kind)
        assertEquals(39687L, reference.ids.simkl)
        assertEquals(16498L, reference.ids.mal)
        assertEquals(2, reference.episode?.season)
        assertEquals(4, reference.episode?.number)
        assertEquals("https://catalog.example/anime.webp", reference.posterUrl)
    }

    @Test
    fun `clean plan to watch removal needs no destructive confirmation`() {
        val plan = entry(
            type = SimklMediaType.MOVIES,
            status = SimklListStatus.PLAN_TO_WATCH,
            id = 53536,
            imdb = "tt0181852",
        )

        val confirmation = SimklSyncSnapshot(entries = listOf(plan))
            .membershipRemovalConfirmation("tt0181852")

        assertNull(confirmation)
    }

    @Test
    fun `watched or rated Simkl removal requires destructive confirmation`() {
        val watchedPlan = entry(
            type = SimklMediaType.MOVIES,
            status = SimklListStatus.PLAN_TO_WATCH,
            id = 53536,
            imdb = "tt0181852",
            lastWatchedAt = "2023-11-14T22:13:20Z",
        )
        val ratedPlan = entry(
            type = SimklMediaType.MOVIES,
            status = SimklListStatus.PLAN_TO_WATCH,
            id = 53434,
            imdb = "tt0068646",
        ).copy(userRating = 9)
        val episodePlan = entry(
            type = SimklMediaType.SHOWS,
            status = SimklListStatus.PLAN_TO_WATCH,
            id = 2090,
            imdb = "tt1520211",
            seasons = listOf(
                SimklSeason(
                    number = 1,
                    episodes = listOf(
                        SimklEpisode(number = 1, watchedAt = "2023-11-14T22:13:20Z"),
                    ),
                ),
            ),
        )

        val confirmation = assertNotNull(
            SimklSyncSnapshot(entries = listOf(watchedPlan, ratedPlan, episodePlan))
                .membershipRemovalConfirmation("tt0181852"),
        )
        assertNotNull(
            SimklSyncSnapshot(entries = listOf(watchedPlan, ratedPlan, episodePlan))
                .membershipRemovalConfirmation("tt0068646"),
        )
        assertNotNull(
            SimklSyncSnapshot(entries = listOf(watchedPlan, ratedPlan, episodePlan))
                .membershipRemovalConfirmation("tt1520211"),
        )

        assertEquals(
            setOf(
                TrackingMembershipRemovalImpact.WATCHED_HISTORY,
                TrackingMembershipRemovalImpact.RATING,
            ),
            confirmation.impacts,
        )
    }

    @Test
    fun `Simkl default membership toggles only its mutually exclusive status`() {
        val planKey = simklLibraryStatusDefinitions.single { definition ->
            definition.status == SimklListStatus.PLAN_TO_WATCH
        }.key
        val watchingKey = simklLibraryStatusDefinitions.single { definition ->
            definition.status == SimklListStatus.WATCHING
        }.key
        val emptyMembership = simklLibraryStatusDefinitions.associate { definition ->
            definition.key to false
        }

        val added = SimklTrackingLibraryProvider.toggledDefaultMembership(emptyMembership)
        val removed = SimklTrackingLibraryProvider.toggledDefaultMembership(
            emptyMembership + (watchingKey to true),
        )

        assertTrue(added[planKey] == true)
        assertTrue(added.filterKeys { key -> key != planKey }.values.none { it })
        assertTrue(removed.values.none { it })
    }

    @Test
    fun `timestamp parser accepts UTC fractions and rejects invalid calendar values`() {
        assertEquals(0L, parseSimklUtcEpochMs("1970-01-01T00:00:00Z"))
        assertEquals(951_782_400_123L, parseSimklUtcEpochMs("2000-02-29T00:00:00.123Z"))
        assertNull(parseSimklUtcEpochMs("2023-02-29T00:00:00Z"))
        assertNull(parseSimklUtcEpochMs("2024-01-01T00:00:00+01:00"))
    }

    private fun entry(
        type: SimklMediaType,
        status: SimklListStatus,
        id: Long,
        imdb: String? = null,
        mal: Long? = null,
        slug: String? = null,
        addedAt: String? = null,
        lastWatchedAt: String? = null,
        animeType: String? = null,
        seasons: List<SimklSeason> = emptyList(),
    ): SimklLibraryEntry = SimklLibraryEntry(
        mediaType = type,
        status = status,
        addedToWatchlistAt = addedAt,
        lastWatchedAt = lastWatchedAt,
        animeType = animeType,
        seasons = seasons,
        movie = if (type == SimklMediaType.MOVIES) media(id, imdb, mal, slug = slug) else null,
        show = if (type != SimklMediaType.MOVIES) media(id, imdb, mal, slug = slug) else null,
    )

    private fun media(
        id: Long,
        imdb: String? = null,
        mal: Long? = null,
        runtime: Int? = null,
        slug: String? = null,
    ): SimklMedia = SimklMedia(
        title = "Title $id",
        poster = "12/poster",
        year = 2020,
        runtime = runtime,
        ids = buildJsonObject {
            put("simkl", id)
            imdb?.let { put("imdb", it) }
            mal?.let { put("mal", it) }
            slug?.let { put("slug", it) }
        },
    )
}
