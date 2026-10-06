package com.nuvio.app.features.tmdb

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Upstream 90054b7b9 lets a kitsu:/mal: entry reach TMDB through the addon's `imdb_id`, which names
 * the whole franchise. The entry is one season of it with its own episode numbering, so only what
 * describes the whole show may be taken from TMDB.
 */
class TmdbFranchiseMatchTest {
    private val kitsuSeasonThree = MetaDetails(
        id = "kitsu:13569",
        type = "series",
        name = "Shingeki no Kyojin Season 3",
        imdbId = "tt2560140",
        poster = "https://kitsu.example/season3-poster.jpg",
        description = "The third season.",
        releaseInfo = "2018",
        videos = listOf(
            MetaVideo(
                id = "kitsu:13569:1",
                title = "Smoke Signal",
                released = "2018-07-23T00:00:00.000Z",
                season = 1,
                episode = 1,
            ),
        ),
    )

    private val franchise = TmdbEnrichment(
        localizedTitle = "L'Attaque des Titans",
        description = "Franchise overview",
        genres = listOf("Animation"),
        backdrop = "https://tmdb.example/backdrop.jpg",
        logo = "https://tmdb.example/logo.png",
        poster = "https://tmdb.example/poster.jpg",
        people = emptyList(),
        director = emptyList(),
        writer = emptyList(),
        releaseInfo = "2013",
        lastAirDate = "2023-11-05",
        rating = 9.1,
        runtimeMinutes = 24,
        ageRating = "16",
        status = "Ended",
        countries = listOf("JP"),
        language = "ja",
        productionCompanies = emptyList(),
        networks = emptyList(),
    )

    private val seasonOneEpisodes = mapOf(
        (1 to 1) to TmdbEpisodeEnrichment(
            title = "To You, in 2000 Years",
            overview = "Season 1 episode 1",
            thumbnail = "https://tmdb.example/s1e1.jpg",
            seasonPoster = "https://tmdb.example/s1.jpg",
            airDate = "2013-04-07",
            runtimeMinutes = 24,
        ),
    )

    private val allOn = TmdbSettings(
        enabled = true,
        apiKey = "key",
    )

    @Test
    fun `an anime entry reached only through the addon imdb id is a franchise-level match`() {
        assertTrue(TmdbMetadataService.isFranchiseLevelTmdbMatch("kitsu:13569", "kitsu:13569"))
        assertTrue(TmdbMetadataService.isFranchiseLevelTmdbMatch("mal:38524", "mal:38524"))
        assertTrue(TmdbMetadataService.isFranchiseLevelTmdbMatch("anilist:104578", "anilist:104578"))
        assertTrue(TmdbMetadataService.isFranchiseLevelTmdbMatch("Kitsu:13569", "kitsu:13569"))
    }

    @Test
    fun `a title TMDB resolves by its own id keeps the full enrichment`() {
        // The catalog id already names the title, as before 90054b7b9.
        assertFalse(TmdbMetadataService.isFranchiseLevelTmdbMatch("kitsu:13569", "tt2560140"))
        assertFalse(TmdbMetadataService.isFranchiseLevelTmdbMatch("kitsu:13569", "tmdb:1429"))
        // Custom addon ids number their seasons like the show itself.
        assertFalse(TmdbMetadataService.isFranchiseLevelTmdbMatch("myaddon:42", "myaddon:42"))
        assertFalse(TmdbMetadataService.isFranchiseLevelTmdbMatch("tt2560140", "tt2560140"))
    }

    @Test
    fun `a franchise-level match keeps the name artwork dates and episodes of the entry`() {
        val enriched = TmdbMetadataService.applyEnrichment(
            meta = kitsuSeasonThree,
            enrichment = franchise,
            episodeMap = seasonOneEpisodes,
            settings = allOn,
            franchiseLevelMatch = true,
        )

        assertEquals("Shingeki no Kyojin Season 3", enriched.name)
        assertEquals("The third season.", enriched.description)
        assertEquals("https://kitsu.example/season3-poster.jpg", enriched.poster)
        assertEquals("2018", enriched.releaseInfo)
        assertEquals(kitsuSeasonThree.videos, enriched.videos)
        // What describes the whole show still fills in.
        assertEquals("https://tmdb.example/logo.png", enriched.logo)
        assertEquals("https://tmdb.example/backdrop.jpg", enriched.background)
        assertEquals("9.1", enriched.imdbRating)
        assertEquals(listOf("Animation"), enriched.genres)
        assertEquals("16", enriched.ageRating)
    }

    @Test
    fun `a regular match still overrides with TMDB data`() {
        val enriched = TmdbMetadataService.applyEnrichment(
            meta = kitsuSeasonThree,
            enrichment = franchise,
            episodeMap = seasonOneEpisodes,
            settings = allOn,
        )

        assertEquals("L'Attaque des Titans", enriched.name)
        assertEquals("https://tmdb.example/poster.jpg", enriched.poster)
        // Upstream 3555bd07b: release dates always come from the add-on.
        assertEquals("2018", enriched.releaseInfo)
        assertEquals("To You, in 2000 Years", enriched.videos.single().title)
        assertEquals("2018-07-23T00:00:00.000Z", enriched.videos.single().released)
    }
}
