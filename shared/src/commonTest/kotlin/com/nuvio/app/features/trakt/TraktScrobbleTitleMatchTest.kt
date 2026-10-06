package com.nuvio.app.features.trakt

import com.nuvio.app.features.watchprogress.WatchProgressEntry
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * CW sync #4: which optimistic rows a Trakt scrobble stop holds (while in flight, and for a day after
 * it failed) — every row of the scrobbled title, whatever the episode numbering.
 */
class TraktScrobbleTitleMatchTest {
    private val show = TraktScrobbleItem.Episode(
        showTitle = "Game of Thrones",
        showYear = 2011,
        showIds = TraktExternalIds(imdb = "tt0944947", tmdb = 1399),
        season = 1,
        number = 3,
        episodeTitle = "Lord Snow",
    )

    @Test
    fun `every episode row of the scrobbled show matches`() {
        assertTrue(row("tt0944947", season = 1, episode = 3).isOfTraktScrobbleTitle(show))
        assertTrue(row("tt0944947", season = 2, episode = 1).isOfTraktScrobbleTitle(show))
        assertTrue(row("tmdb:1399", season = 1, episode = 4).isOfTraktScrobbleTitle(show))
    }

    @Test
    fun `another title or a movie row does not match a show`() {
        assertFalse(row("tt0903747", season = 1, episode = 3).isOfTraktScrobbleTitle(show))
        assertFalse(row("tt0944947").isOfTraktScrobbleTitle(show))
        assertFalse(row("kitsu:1376", season = 1, episode = 3).isOfTraktScrobbleTitle(show))
    }

    @Test
    fun `a movie matches its own row only`() {
        val movie = TraktScrobbleItem.Movie(title = "Heat", year = 1995, ids = TraktExternalIds(trakt = 1234))
        assertTrue(row("trakt:1234").isOfTraktScrobbleTitle(movie))
        assertFalse(row("trakt:1234", season = 1, episode = 1).isOfTraktScrobbleTitle(movie))
        assertFalse(row("trakt:999").isOfTraktScrobbleTitle(movie))
    }

    private fun row(contentId: String, season: Int? = null, episode: Int? = null) = WatchProgressEntry(
        contentType = if (season == null) "movie" else "series",
        parentMetaId = contentId,
        parentMetaType = if (season == null) "movie" else "series",
        videoId = if (season == null) contentId else "$contentId:$season:$episode",
        title = "Title",
        seasonNumber = season,
        episodeNumber = episode,
        lastPositionMs = 60_000L,
        durationMs = 3_600_000L,
        lastUpdatedEpochMs = 1_790_000_000_000L,
    )
}
