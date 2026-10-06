package com.nuvio.app.features.upcoming

import com.nuvio.app.core.time.parseZonedIsoDateTimeToEpochMs
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pure-rule coverage for the Home "Upcoming" row (tvOS): which episode a followed show
 * contributes, which shows are swept, and how the row is ordered.
 */
class UpcomingEpisodesRulesTest {

    private val today = "2026-08-19"

    /** Viewer clock: UTC. Zoned timestamps map to their UTC calendar day. */
    private val utcLocalDate: (Long) -> String? = { epochMs -> utcIsoDate(epochMs) }

    /** Viewer clock: UTC-5 (America/New_York summer). Midnight-UTC releases land on the previous day. */
    private val utcMinus5LocalDate: (Long) -> String? = { epochMs -> utcIsoDate(epochMs - 5L * 60L * 60L * 1_000L) }

    private fun ep(
        season: Int?,
        episode: Int?,
        released: String?,
        thumbnail: String? = null,
        title: String = "S${season}E$episode",
    ) = MetaVideo(
        id = "tt1:$season:$episode",
        title = title,
        released = released,
        thumbnail = thumbnail,
        season = season,
        episode = episode,
    )

    private fun meta(
        vararg videos: MetaVideo,
        type: String = "series",
        releaseInfo: String? = "2024",
    ) = MetaDetails(
        id = "tt1",
        type = type,
        name = "Show",
        poster = "poster.jpg",
        background = "bg.jpg",
        logo = "logo.png",
        releaseInfo = releaseInfo,
        videos = videos.toList(),
    )

    private fun select(meta: MetaDetails, localDate: (Long) -> String? = utcLocalDate) =
        selectUpcomingEpisode(meta = meta, todayIsoDate = today, localDateAtEpochMs = localDate)

    // ---- selectUpcomingEpisode ----

    @Test
    fun `plain TMDB date two days out is selected with its fields carried over`() {
        val item = select(meta(ep(1, 1, "2026-08-01"), ep(1, 2, "2026-08-21", thumbnail = "still.jpg")))
        assertNotNull(item)
        assertEquals(2, item.daysUntilAir)
        assertEquals("2026-08-21", item.airDateIso)
        assertEquals(1, item.season)
        assertEquals(2, item.episode)
        assertEquals("still.jpg", item.episodeThumbnail)
        assertEquals("still.jpg", item.imageUrl)
        assertEquals("tt1:1:2", item.episodeId)
        assertEquals("Show", item.showTitle)
        assertEquals("2024", item.showYear)
        assertEquals("series:tt1", item.showKey)
    }

    @Test
    fun `zoned Cinemeta midnight-UTC timestamp lands on the viewer's local day`() {
        val show = meta(ep(1, 1, "2026-08-21T00:00:00.000Z"))
        assertEquals(2, select(show, utcLocalDate)?.daysUntilAir)
        val local = select(show, utcMinus5LocalDate)
        assertEquals(1, local?.daysUntilAir)
        assertEquals("2026-08-20", local?.airDateIso)
    }

    @Test
    fun `zoned timestamp with explicit offset and fractional seconds parses`() {
        val item = select(meta(ep(1, 1, "2026-08-22T01:30:00.5+02:00")))
        assertNotNull(item)
        assertEquals("2026-08-21", item.airDateIso)
        assertEquals(2, item.daysUntilAir)
    }

    @Test
    fun `episode airing today counts as upcoming with zero days`() {
        val item = select(meta(ep(2, 4, "2026-08-12"), ep(2, 5, today)))
        assertEquals(0, item?.daysUntilAir)
        assertEquals(5, item?.episode)
    }

    @Test
    fun `exactly the horizon is included and one day past it is not`() {
        assertEquals(14, select(meta(ep(1, 1, "2026-09-02")))?.daysUntilAir)
        assertNull(select(meta(ep(1, 1, "2026-09-03"))))
    }

    @Test
    fun `past episodes are skipped`() {
        val item = select(meta(ep(1, 1, "2026-08-01"), ep(1, 2, "2026-08-26")))
        assertEquals(2, item?.episode)
        assertEquals(7, item?.daysUntilAir)
    }

    @Test
    fun `undated episodes are skipped rather than ending the walk`() {
        val item = select(meta(ep(1, 1, null), ep(1, 2, ""), ep(1, 3, "not a date"), ep(1, 4, "2026-08-20")))
        assertEquals(4, item?.episode)
        assertNull(select(meta(ep(1, 1, null), ep(1, 2, null))))
        assertNull(select(meta()))
    }

    @Test
    fun `next in season-episode order wins even if a later season is dated earlier`() {
        val item = select(meta(ep(3, 1, "2026-08-25"), ep(2, 10, "2026-08-20")))
        assertEquals(2, item?.season)
        assertEquals(10, item?.episode)
    }

    @Test
    fun `specials are excluded`() {
        val item = select(meta(ep(0, 3, "2026-08-20"), ep(2, 5, "2026-08-30")))
        assertEquals(2, item?.season)
        assertEquals(11, item?.daysUntilAir)
        assertNull(select(meta(ep(0, 1, "2026-08-20"), ep(0, 2, "2026-08-21"))))
    }

    @Test
    fun `episodes missing a season or episode number are ignored`() {
        val item = select(meta(ep(null, 3, "2026-08-20"), ep(1, null, "2026-08-21"), ep(1, 7, "2026-08-22")))
        assertEquals(7, item?.episode)
    }

    @Test
    fun `first future episode beyond the horizon decides for the show`() {
        // Order is season/episode, so the first >= today episode is the show's next; if THAT is
        // out of range the show contributes nothing even when a later entry is mis-dated closer.
        assertNull(select(meta(ep(1, 5, "2026-10-01"), ep(1, 6, "2026-08-20"))))
    }

    @Test
    fun `show type is normalized and year comes from releaseInfo`() {
        val item = select(meta(ep(1, 1, "2026-08-20"), type = "tv", releaseInfo = "2019–2023"))
        assertEquals("series", item?.showType)
        assertEquals("2019", item?.showYear)
        assertNull(select(meta(ep(1, 1, "2026-08-20"), releaseInfo = null))?.showYear)
    }

    @Test
    fun `image falls back from thumbnail to background to poster`() {
        val withThumb = select(meta(ep(1, 1, "2026-08-20", thumbnail = "still.jpg")))
        assertEquals("still.jpg", withThumb?.imageUrl)
        val noThumb = select(meta(ep(1, 1, "2026-08-20")))
        assertEquals("bg.jpg", noThumb?.imageUrl)
        val posterOnly = select(meta(ep(1, 1, "2026-08-20")).copy(background = null))
        assertEquals("poster.jpg", posterOnly?.imageUrl)
    }

    // ---- collectUpcomingShowRefs ----

    private fun progress(
        type: String,
        id: String,
        touched: Long,
        completed: Boolean = false,
    ) = WatchProgressEntry(
        contentType = "episode",
        parentMetaId = id,
        parentMetaType = type,
        videoId = "$id:1:1",
        title = id,
        seasonNumber = 1,
        episodeNumber = 1,
        lastPositionMs = if (completed) 100_000L else 10_000L,
        durationMs = 100_000L,
        lastUpdatedEpochMs = touched,
        isCompleted = completed,
    )

    private fun library(type: String, id: String, saved: Long) = LibraryItem(
        id = id,
        type = type,
        name = id,
        savedAtEpochMs = saved,
    )

    @Test
    fun `refs dedupe across type spellings and sources keeping the latest touch`() {
        val refs = collectUpcomingShowRefs(
            progressEntries = listOf(progress("series", "tt1", touched = 100L)),
            libraryItems = listOf(library("tv", " tt1 ", saved = 500L)),
        )
        assertEquals(1, refs.size)
        assertEquals("series", refs[0].type)
        assertEquals("tt1", refs[0].id)
        assertEquals(500L, refs[0].lastTouchedEpochMs)
    }

    @Test
    fun `refs exclude movies and include completed progress entries`() {
        val refs = collectUpcomingShowRefs(
            progressEntries = listOf(
                progress("movie", "ttMovie", touched = 900L),
                progress("series", "ttDone", touched = 300L, completed = true),
            ),
            libraryItems = listOf(library("movie", "ttMovie2", saved = 800L)),
        )
        assertEquals(listOf("series:ttDone"), refs.map { it.key })
    }

    @Test
    fun `refs are ordered most recently touched first and capped`() {
        val refs = collectUpcomingShowRefs(
            progressEntries = listOf(
                progress("series", "a", touched = 10L),
                progress("series", "b", touched = 30L),
            ),
            libraryItems = listOf(
                library("series", "c", saved = 20L),
                library("series", "d", saved = 40L),
            ),
            maxShows = 3,
        )
        assertEquals(listOf("d", "b", "c"), refs.map { it.id })
    }

    // ---- sortUpcomingItems ----

    private fun item(title: String, days: Int, id: String = title.lowercase()) = UpcomingEpisodeItem(
        showId = id,
        showType = "series",
        showTitle = title,
        showYear = null,
        showPoster = null,
        showBackground = null,
        showLogo = null,
        episodeId = "$id:1:1",
        season = 1,
        episode = 1,
        episodeTitle = null,
        episodeThumbnail = null,
        airDateIso = "2026-08-20",
        daysUntilAir = days,
    )

    @Test
    fun `sort is soonest first then title case-insensitively then key`() {
        val sorted = sortUpcomingItems(
            listOf(item("zeta", 3), item("Beta", 0), item("alpha", 3), item("Alpha", 3, id = "alpha2")),
        )
        assertEquals(listOf("Beta", "alpha", "Alpha", "zeta"), sorted.map { it.showTitle })
    }

    @Test
    fun `publishable items collapse refs that resolved to the same canonical show`() {
        val published = publishableUpcomingItems(
            listOf(item("Show", 3, id = "tt1"), item("Show", 3, id = "tt1"), item("Other", 1, id = "tt2")),
        )
        assertEquals(listOf("tt2", "tt1"), published.map { it.showId })
    }

    // ---- upcomingShowYearLabel / toMetaPreview ----

    @Test
    fun `year label takes the leading four digits only`() {
        assertEquals("2019", upcomingShowYearLabel("2019"))
        assertEquals("2019", upcomingShowYearLabel("2019-"))
        assertEquals("2019", upcomingShowYearLabel("2019–2023"))
        assertEquals("2019", upcomingShowYearLabel("2019-05-01"))
        assertNull(upcomingShowYearLabel(null))
        assertNull(upcomingShowYearLabel(""))
        assertNull(upcomingShowYearLabel("TBA"))
        assertNull(upcomingShowYearLabel("20190"))
    }

    @Test
    fun `toMetaPreview carries the navigation fields`() {
        val preview = item("Show", 1).copy(
            showPoster = "p.jpg",
            showBackground = "b.jpg",
            showLogo = "l.png",
            showYear = "2024",
        ).toMetaPreview()
        assertEquals("show", preview.id)
        assertEquals("series", preview.type)
        assertEquals("Show", preview.name)
        assertEquals("p.jpg", preview.poster)
        assertEquals("b.jpg", preview.banner)
        assertEquals("l.png", preview.logo)
        assertEquals("2024", preview.releaseInfo)
    }

    @Test
    fun `zoned parser sanity for the local-date lambdas used above`() {
        // Guards the test doubles themselves: midnight UTC on the 21st is 19:00 on the 20th at UTC-5.
        val epochMs = parseZonedIsoDateTimeToEpochMs("2026-08-21T00:00:00.000Z")
        assertNotNull(epochMs)
        assertEquals("2026-08-21", utcLocalDate(epochMs))
        assertEquals("2026-08-20", utcMinus5LocalDate(epochMs))
        assertTrue(epochMs > 0)
    }

    private fun utcIsoDate(epochMs: Long): String {
        val days = epochMs.floorDiv(86_400_000L)
        // Civil-from-days (Howard Hinnant), inverse of the parser's isoEpochDay.
        val z = days + 719_468L
        val era = (if (z >= 0) z else z - 146_096L) / 146_097L
        val doe = z - era * 146_097L
        val yoe = (doe - doe / 1_460L + doe / 36_524L - doe / 146_096L) / 365L
        val y = yoe + era * 400L
        val doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
        val mp = (5L * doy + 2L) / 153L
        val d = doy - (153L * mp + 2L) / 5L + 1L
        val m = if (mp < 10L) mp + 3L else mp - 9L
        val year = if (m <= 2L) y + 1L else y
        return year.toString().padStart(4, '0') + "-" +
            m.toString().padStart(2, '0') + "-" +
            d.toString().padStart(2, '0')
    }
}
