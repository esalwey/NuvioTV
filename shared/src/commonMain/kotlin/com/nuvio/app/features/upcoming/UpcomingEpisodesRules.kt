package com.nuvio.app.features.upcoming

import com.nuvio.app.core.time.EpisodeReleaseDatePlatform
import com.nuvio.app.core.time.daysUntilEpisodeRelease
import com.nuvio.app.core.time.parseEpisodeReleaseLocalDate
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.SPECIALS_SEASON_NUMBER
import com.nuvio.app.features.details.normalizeSeasonNumber
import com.nuvio.app.features.details.sortedPlayableEpisodes
import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.notifications.isSeriesLibraryType
import com.nuvio.app.features.notifications.normalizeSeriesType
import com.nuvio.app.features.watchprogress.WatchProgressEntry

// Fork: tvOS-first Home "Upcoming" row (no upstream twin). Pure rules — no repositories, no
// clock — so they are unit-testable in commonTest and the repository stays a thin orchestrator.

/** Episodes airing later than this many days from today are not "upcoming" (Home row horizon). */
const val UpcomingEpisodesHorizonDays: Int = 14

/** Fan-out cap: most-recently-touched shows first. Bounds cold-start addon traffic. */
const val UpcomingEpisodesMaxShows: Int = 60

private val LeadingYearRegex = Regex("""^\s*(\d{4})(?!\d)""")

/**
 * The show's next airing episode: the FIRST episode in season/episode order (specials excluded)
 * whose local air date is today or later. Returns null when there is none, or when that
 * episode lands beyond [horizonDays].
 *
 * Deliberately not anchored on watched position (unlike `nextReleasedEpisodeAfter`): a show the
 * user follows has an episode airing Thursday whether they are caught up or three seasons behind
 * — that is what the reference design surfaces.
 *
 * Episodes without a parseable release date are skipped, not treated as terminal — addons often
 * leave dates blank on some entries.
 */
fun selectUpcomingEpisode(
    meta: MetaDetails,
    todayIsoDate: String,
    horizonDays: Int = UpcomingEpisodesHorizonDays,
    localDateAtEpochMs: (Long) -> String? = EpisodeReleaseDatePlatform::localIsoDateAtEpochMs,
): UpcomingEpisodeItem? {
    val episodes = meta.sortedPlayableEpisodes().filter { video ->
        video.season != null &&
            video.episode != null &&
            normalizeSeasonNumber(video.season) > SPECIALS_SEASON_NUMBER
    }
    for (video in episodes) {
        val daysUntil = daysUntilEpisodeRelease(
            todayIsoDate = todayIsoDate,
            releasedDate = video.released,
            localDateAtEpochMs = localDateAtEpochMs,
        ) ?: continue
        if (daysUntil < 0) continue
        if (daysUntil > horizonDays) return null
        val airDateIso = parseEpisodeReleaseLocalDate(video.released, localDateAtEpochMs) ?: return null
        return UpcomingEpisodeItem(
            showId = meta.id,
            showType = normalizeSeriesType(meta.type),
            showTitle = meta.name,
            showYear = upcomingShowYearLabel(meta.releaseInfo),
            showPoster = meta.poster,
            showBackground = meta.background,
            showLogo = meta.logo,
            episodeId = video.id,
            season = video.season ?: return null,
            episode = video.episode ?: return null,
            episodeTitle = video.title.takeIf { it.isNotBlank() },
            episodeThumbnail = video.thumbnail?.takeIf { it.isNotBlank() },
            airDateIso = airDateIso,
            daysUntilAir = daysUntil,
        )
    }
    return null
}

/**
 * The shows to resolve: every series with watch progress (completed entries included — a
 * caught-up show is exactly the one whose next episode matters) plus every series saved in the
 * Library. Deduped by normalized (type, id), most recently touched first, capped at [maxShows].
 */
fun collectUpcomingShowRefs(
    progressEntries: List<WatchProgressEntry>,
    libraryItems: List<LibraryItem>,
    maxShows: Int = UpcomingEpisodesMaxShows,
): List<UpcomingShowRef> {
    val byKey = HashMap<String, UpcomingShowRef>()

    fun offer(type: String, id: String, touchedEpochMs: Long) {
        val trimmedId = id.trim()
        if (trimmedId.isEmpty() || !isSeriesLibraryType(type)) return
        val ref = UpcomingShowRef(
            type = normalizeSeriesType(type),
            id = trimmedId,
            lastTouchedEpochMs = touchedEpochMs,
        )
        val existing = byKey[ref.key]
        if (existing == null || existing.lastTouchedEpochMs < ref.lastTouchedEpochMs) {
            byKey[ref.key] = ref
        }
    }

    progressEntries.forEach { entry ->
        offer(entry.parentMetaType, entry.parentMetaId, entry.lastUpdatedEpochMs)
    }
    libraryItems.forEach { item ->
        offer(item.type, item.id, item.savedAtEpochMs)
    }

    return byKey.values
        .sortedWith(compareByDescending<UpcomingShowRef> { it.lastTouchedEpochMs }.thenBy { it.key })
        .take(maxShows.coerceAtLeast(0))
}

/** Row order: soonest first, then title (case-insensitive), then key — stable across passes. */
fun sortUpcomingItems(items: List<UpcomingEpisodeItem>): List<UpcomingEpisodeItem> =
    items.sortedWith(
        compareBy<UpcomingEpisodeItem> { it.daysUntilAir }
            .thenBy { it.showTitle.lowercase() }
            .thenBy { it.showKey },
    )

/**
 * Row contents: sorted, then one card per CANONICAL show. Two refs (e.g. `tmdb:123` from progress
 * and its IMDb id from the Library) can resolve to the same addon meta id, so the raw-ref dedupe
 * in [collectUpcomingShowRefs] is not enough — duplicates here would collide as SwiftUI ids.
 */
fun publishableUpcomingItems(items: List<UpcomingEpisodeItem>): List<UpcomingEpisodeItem> =
    sortUpcomingItems(items).distinctBy { it.showKey }

/**
 * Leading 4-digit year of a show's releaseInfo — "2019", "2019-", "2019–2023" and "2019-05-01"
 * all yield "2019"; anything without a leading year (null, blank, "TBA") yields null.
 */
fun upcomingShowYearLabel(releaseInfo: String?): String? {
    val raw = releaseInfo ?: return null
    return LeadingYearRegex.find(raw)?.groupValues?.get(1)
}
