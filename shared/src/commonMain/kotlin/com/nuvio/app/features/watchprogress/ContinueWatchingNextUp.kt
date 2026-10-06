package com.nuvio.app.features.watchprogress

import co.touchlab.kermit.Logger
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.details.SeriesPrimaryAction
import com.nuvio.app.features.details.seriesPrimaryAction
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watched.normalizeWatchedMarkedAtEpochMs
import com.nuvio.app.features.watching.domain.WatchingContentRef
import com.nuvio.app.features.watching.domain.WatchingProgressRecord
import com.nuvio.app.features.watching.domain.WatchingWatchedRecord
import com.nuvio.app.features.watching.domain.latestCompletedSeriesEpisode
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException

/*
 * tvOS Continue Watching "Up Next" (CW-2) — the shared half of mobile HomeScreen's next-up
 * pipeline (`buildHomeNextUpSeedCandidates`, `resolveHomeNextUpCandidate`,
 * `buildHomeContinueWatchingItems`), reduced to what the tvOS row needs. A series whose latest
 * watched episode is finished leaves the in-progress row (`continueWatchingEntries` drops it); its
 * NEXT released episode comes back as an Up Next card instead of the show vanishing after a binge.
 *
 * The tvOS row is a list of `WatchProgressEntry`, so an Up Next card is a synthetic entry for the
 * next episode (no position, `source = WatchProgressSourceNextUp`) — never written to the
 * repository: it only drives the row, the hero and the stream picker, and the episode's own
 * playback then records real progress under the same `parent:season:episode` key.
 *
 * Deliberate differences from mobile: unaired next episodes are never surfaced (the tvOS Home has
 * a dedicated Upcoming row for those), and there is no release-alert sort or enrichment cache.
 */

/** `WatchProgressEntry.source` of a Continue Watching Up Next card (see the file comment). */
const val WatchProgressSourceNextUp = "next_up"

/** A series whose latest watched episode is finished: what its Up Next card is resolved from. */
data class ContinueWatchingNextUpSeed(
    val contentId: String,
    val contentType: String,
    val seasonNumber: Int,
    val episodeNumber: Int,
    val markedAtEpochMs: Long,
) {
    /** Mobile's dismiss key: a dismissed card stays hidden until another episode is finished. */
    val dismissKey: String
        get() = nextUpDismissKey(contentId, seasonNumber, episodeNumber)
}

/** The outcome of resolving one seed. */
data class ContinueWatchingNextUpResolution(
    /** The Up Next card, or null when the series has nothing to continue with right now. */
    val entry: WatchProgressEntry?,
    /** False when the series metadata could not be fetched (offline, add-on down): retry later. */
    val isConclusive: Boolean,
)

/**
 * Seeds for the row (mobile `buildHomeNextUpSeedCandidates` + its in-progress suppression): the
 * latest finished main-season episode per series — progress entries the active provider accepts as
 * next-up seeds, plus explicit episode marks unless the provider owns completed history — minus
 * series whose in-progress card is at least as recent, hidden/dropped shows, dismissed cards and
 * seeds older than the provider's Continue Watching window. Most recent first, one per series.
 *
 * "Series" is [canonicalSeriesId]'s (CW alias fix, REMAINING_FIX #2): an in-progress card under
 * one id of a show suppresses the seed of its other id, and a show stored under two ids yields
 * one seed, the most recent. Each seed keeps the id its episode was stored under.
 *
 * With [nowEpochMs], an episode mark dated more than 10 minutes ahead of it (a device with a wrong
 * clock marked it) counts as undated, as a server progress row does (CW legacy #3): it can no
 * longer outrank, and hide, the series' in-progress card.
 */
fun buildContinueWatchingNextUpSeeds(
    progressEntries: List<WatchProgressEntry>,
    watchedItems: List<WatchedItem>,
    inProgressEntries: List<WatchProgressEntry>,
    preferFurthestEpisode: Boolean,
    dismissedNextUpKeys: Set<String>,
    recencyCutoffEpochMs: Long?,
    limit: Int,
    shouldUseProgressSeed: (WatchProgressEntry) -> Boolean = { entry ->
        entry.shouldUseAsCompletedSeedForContinueWatching()
    },
    isContentHidden: (String) -> Boolean = { false },
    canonicalSeriesId: (String) -> String = ContinueWatchingSeriesIdentity::canonical,
    nowEpochMs: Long? = null,
): List<ContinueWatchingNextUpSeed> {
    val progressSeeds = progressEntries.filter { entry ->
        entry.parentMetaType.isSeriesTypeForContinueWatching() &&
            entry.seasonNumber != null && entry.episodeNumber != null && entry.seasonNumber != 0 &&
            !isMalformedNextUpSeedContentId(entry.parentMetaId) &&
            !isContentHidden(entry.parentMetaId) &&
            shouldUseProgressSeed(entry)
    }
    val watchedSeeds = watchedItems.filter { item ->
        item.type.isSeriesTypeForContinueWatching() &&
            item.season != null && item.episode != null && item.season != 0 &&
            !isMalformedNextUpSeedContentId(item.id) &&
            !isContentHidden(item.id)
    }
    val contents = buildSet {
        progressSeeds.forEach { entry -> add(WatchingContentRef(type = entry.parentMetaType, id = entry.parentMetaId)) }
        watchedSeeds.forEach { item -> add(WatchingContentRef(type = item.type, id = item.id)) }
    }
    val progressRecords = progressSeeds.map { entry ->
        val normalized = entry.normalizedCompletion()
        WatchingProgressRecord(
            content = WatchingContentRef(type = normalized.parentMetaType, id = normalized.parentMetaId),
            videoId = normalized.videoId,
            seasonNumber = normalized.seasonNumber,
            episodeNumber = normalized.episodeNumber,
            lastUpdatedEpochMs = normalized.lastUpdatedEpochMs,
            lastPositionMs = normalized.lastPositionMs,
            isCompleted = normalized.isEffectivelyCompleted,
        )
    }
    val watchedRecords = watchedSeeds.map { item ->
        WatchingWatchedRecord(
            content = WatchingContentRef(type = item.type, id = item.id),
            seasonNumber = item.season,
            episodeNumber = item.episode,
            markedAtEpochMs = normalizeWatchedMarkedAtEpochMs(item.markedAtEpochMs).let { markedAt ->
                if (nowEpochMs == null) markedAt else undatedWhenAheadOfClock(markedAt, nowEpochMs)
            },
        )
    }
    // Each series only scans its own records: the row is rebuilt on every progress emission —
    // playback ticks included — and a profile can hold thousands of imported episode marks.
    val progressRecordsByContent = progressRecords.groupBy { record -> record.content }
    val watchedRecordsByContent = watchedRecords.groupBy { record -> record.content }
    // An in-progress card at least as recent as the series' last finished episode wins.
    val inProgressAtBySeries = inProgressEntries
        .filter { entry -> entry.parentMetaType.isSeriesTypeForContinueWatching() }
        .groupBy { entry -> canonicalSeriesId(entry.parentMetaId) }
        .mapValues { (_, entries) -> entries.maxOf { entry -> entry.lastUpdatedEpochMs } }

    return contents
        .mapNotNull { content ->
            val completed = latestCompletedSeriesEpisode(
                content = content,
                progressRecords = progressRecordsByContent[content].orEmpty(),
                watchedRecords = watchedRecordsByContent[content].orEmpty(),
                preferFurthestEpisode = preferFurthestEpisode,
            ) ?: return@mapNotNull null
            if (completed.seasonNumber == 0) return@mapNotNull null
            val inProgressAt = inProgressAtBySeries[canonicalSeriesId(content.id)]
            if (inProgressAt != null && inProgressAt >= completed.markedAtEpochMs) return@mapNotNull null
            ContinueWatchingNextUpSeed(
                contentId = content.id,
                contentType = content.type,
                seasonNumber = completed.seasonNumber,
                episodeNumber = completed.episodeNumber,
                markedAtEpochMs = completed.markedAtEpochMs,
            )
        }
        .filter { seed -> recencyCutoffEpochMs == null || seed.markedAtEpochMs >= recencyCutoffEpochMs }
        .filter { seed -> seed.dismissKey !in dismissedNextUpKeys }
        .sortedWith(
            compareByDescending<ContinueWatchingNextUpSeed> { seed -> seed.markedAtEpochMs }
                .thenByDescending { seed -> seed.seasonNumber }
                .thenByDescending { seed -> seed.episodeNumber },
        )
        // The same series filed under two type aliases ("series"/"tv"), or two ids, yields one card.
        .distinctBy { seed -> canonicalSeriesId(seed.contentId) }
        .take(limit)
}

/**
 * CW alias fix (review): the dismiss keys of every Up Next seed [card]'s series has now, under
 * each of its stored ids — the card's own and every id [canonicalSeriesId] groups with it.
 * [buildContinueWatchingNextUpSeeds] keeps one seed per series, the newest; dismissing only that
 * one would let another id's older seed take its place on the next build (an "Up Next S1E4" for a
 * show just removed at S1E9). The series' own in-progress cards are left out of
 * [inProgressEntries], so every seed it has is listed, whatever those cards suppress on the row.
 * None for a card that is no series: a movie has no Up Next card, and a `tmdb:` movie id may be a
 * series' id too.
 */
internal fun continueWatchingNextUpSeriesDismissKeys(
    card: WatchProgressEntry,
    progressEntries: List<WatchProgressEntry>,
    watchedItems: List<WatchedItem>,
    inProgressEntries: List<WatchProgressEntry>,
    preferFurthestEpisode: Boolean,
    dismissedNextUpKeys: Set<String>,
    recencyCutoffEpochMs: Long?,
    shouldUseProgressSeed: (WatchProgressEntry) -> Boolean = { entry ->
        entry.shouldUseAsCompletedSeedForContinueWatching()
    },
    isContentHidden: (String) -> Boolean = { false },
    canonicalSeriesId: (String) -> String = ContinueWatchingSeriesIdentity::canonical,
    nowEpochMs: Long? = null,
): Set<String> {
    if (!card.isContinueWatchingSeries() || card.parentMetaId.isBlank()) return emptySet()
    val series = canonicalSeriesId(card.parentMetaId)
    val isOfSeries: (String) -> Boolean = { id -> canonicalSeriesId(id) == series }
    return buildContinueWatchingNextUpSeeds(
        progressEntries = progressEntries,
        watchedItems = watchedItems,
        inProgressEntries = inProgressEntries.filterNot { entry -> isOfSeries(entry.parentMetaId) },
        preferFurthestEpisode = preferFurthestEpisode,
        dismissedNextUpKeys = dismissedNextUpKeys,
        recencyCutoffEpochMs = recencyCutoffEpochMs,
        limit = Int.MAX_VALUE,
        shouldUseProgressSeed = shouldUseProgressSeed,
        isContentHidden = isContentHidden,
        // Every stored id on its own, so no seed of the series hides another.
        canonicalSeriesId = { id -> id.trim() },
        nowEpochMs = nowEpochMs,
    )
        .filter { seed -> isOfSeries(seed.contentId) }
        .mapTo(linkedSetOf()) { seed -> seed.dismissKey }
}

/**
 * The Up Next card for [seed] from its series' metadata (mobile `resolveHomeNextUpCandidate`): the
 * series primary action — resume beats next-up, only released episodes, no rewatch — when it is a
 * next episode, as a synthetic row entry. Null when there is nothing to continue with.
 */
fun MetaDetails.continueWatchingNextUpEntry(
    seed: ContinueWatchingNextUpSeed,
    progressEntries: List<WatchProgressEntry>,
    watchedItems: List<WatchedItem>,
    todayIsoDate: String,
    preferFurthestEpisode: Boolean,
): WatchProgressEntry? {
    val action = seriesPrimaryAction(
        content = WatchingContentRef(type = seed.contentType, id = seed.contentId),
        entries = progressEntries,
        watchedItems = watchedItems,
        todayIsoDate = todayIsoDate,
        preferFurthestEpisode = preferFurthestEpisode,
        showUnairedNextUp = false,
        allowRewatch = false,
    ) ?: return null
    // A resume point is the in-progress card's job, not an Up Next one.
    if (action.resumePositionMs != null) return null
    val next = videoForNextUpAction(action) ?: return null
    return WatchProgressEntry(
        contentType = seed.contentType,
        parentMetaId = seed.contentId,
        parentMetaType = seed.contentType,
        // The tvOS progress key (`parent:season:episode`, as the episode shelf and the next-episode
        // engine launch it), so this episode's playback records under the same key.
        videoId = buildPlaybackVideoId(
            parentMetaId = seed.contentId,
            seasonNumber = next.season,
            episodeNumber = next.episode,
            fallbackVideoId = next.id,
        ),
        title = name,
        logo = logo?.takeIf(String::isNotBlank),
        poster = poster?.takeIf(String::isNotBlank),
        background = background?.takeIf(String::isNotBlank),
        seasonNumber = next.season,
        episodeNumber = next.episode,
        episodeTitle = next.title.takeIf(String::isNotBlank),
        episodeThumbnail = next.thumbnail?.takeIf(String::isNotBlank),
        lastPositionMs = 0L,
        durationMs = 0L,
        // Sorted where the finished episode was: the card sits where the show left the row.
        lastUpdatedEpochMs = seed.markedAtEpochMs,
        pauseDescription = next.overview?.takeIf(String::isNotBlank),
        isCompleted = false,
        source = WatchProgressSourceNextUp,
    )
}

private fun MetaDetails.videoForNextUpAction(action: SeriesPrimaryAction): MetaVideo? {
    val season = action.seasonNumber
    val episode = action.episodeNumber
    if (season != null && episode != null) {
        videos.firstOrNull { video -> video.season == season && video.episode == episode }?.let { return it }
    }
    return videos.firstOrNull { video ->
        video.id == action.videoId ||
            buildPlaybackVideoId(
                parentMetaId = id,
                seasonNumber = video.season,
                episodeNumber = video.episode,
                fallbackVideoId = video.id,
            ) == action.videoId
    }
}

/**
 * The row: in-progress entries and Up Next cards, most recent first, one card per title — the
 * in-progress one wins a tie (mobile `buildHomeContinueWatchingItems`). A series is one title
 * under all its ids ([ContinueWatchingSeriesIdentity], CW alias fix).
 */
fun mergeContinueWatchingNextUp(
    inProgressEntries: List<WatchProgressEntry>,
    nextUpEntries: List<WatchProgressEntry>,
): List<WatchProgressEntry> = mergeContinueWatchingNextUp(
    inProgressEntries = inProgressEntries,
    nextUpEntries = nextUpEntries,
    canonicalSeriesId = ContinueWatchingSeriesIdentity::canonical,
)

// The two-parameter form above is what Swift calls (Kotlin defaults do not cross the bridge).
internal fun mergeContinueWatchingNextUp(
    inProgressEntries: List<WatchProgressEntry>,
    nextUpEntries: List<WatchProgressEntry>,
    canonicalSeriesId: (String) -> String,
): List<WatchProgressEntry> {
    if (nextUpEntries.isEmpty()) return inProgressEntries
    val seen = mutableSetOf<String>()
    return (inProgressEntries.map { entry -> entry to true } + nextUpEntries.map { entry -> entry to false })
        .sortedWith(
            compareByDescending<Pair<WatchProgressEntry, Boolean>> { (entry, _) -> entry.lastUpdatedEpochMs }
                .thenByDescending { (_, isProgress) -> isProgress },
        )
        .map { (entry, _) -> entry }
        .filter { entry -> seen.add(entry.continueWatchingSeriesKey(canonicalSeriesId).ifBlank { entry.videoId }) }
}

/** Swift-facing entry points over the active profile's live state (see the file comment). */
object ContinueWatchingNextUp {
    private val log = Logger.withTag("ContinueWatchingNextUp")
    private const val MAX_REMEMBERED_OUTCOMES = 200
    private val outcomeLock = SynchronizedObject()
    /** Seed dismiss key → what its last [resolveCard] gave, oldest first (the diagnostics' `up=`). */
    private val outcomeBySeedKey = LinkedHashMap<String, String>()

    /** The active provider's seams over the live state, as [seeds] and [seriesDismissKeys] apply them. */
    private class SeedSeams(
        val progressEntries: List<WatchProgressEntry>,
        val watchedItems: List<WatchedItem>,
        val recencyCutoffEpochMs: Long?,
        val shouldUseProgressSeed: (WatchProgressEntry) -> Boolean,
        val isContentHidden: (String) -> Boolean,
        val nowEpochMs: Long,
    )

    private fun seedSeams(watchedItems: List<WatchedItem>): SeedSeams {
        WatchProgressRepository.ensureLoaded()
        TraktSettingsRepository.ensureLoaded()
        val state = WatchProgressRepository.uiState.value
        val nowEpochMs = WatchProgressClock.nowEpochMs()
        return SeedSeams(
            progressEntries = state.entries,
            watchedItems = if (WatchProgressRepository.activeProviderOwnsCompletedHistoryProjection()) {
                emptyList()
            } else {
                watchedItems
            },
            recencyCutoffEpochMs = WatchProgressRepository.activeProviderContinueWatchingCutoffEpochMs(
                daysCap = TraktSettingsRepository.uiState.value.continueWatchingDaysCap,
                nowEpochMs = nowEpochMs,
            ),
            shouldUseProgressSeed = { entry -> WatchProgressRepository.shouldUseAsNextUpSeed(entry, nowEpochMs) },
            isContentHidden = { contentId ->
                contentId in state.hiddenContentIds || WatchProgressRepository.isDroppedShow(contentId)
            },
            nowEpochMs = nowEpochMs,
        )
    }

    /**
     * Seeds for the row given its current in-progress entries (`continueWatchingRow`), with the
     * active provider's seams applied: its next-up seed rule, hidden/dropped shows, its Continue
     * Watching window, and whether explicit episode marks count (not when it owns the history).
     */
    fun seeds(
        watchedItems: List<WatchedItem>,
        inProgressEntries: List<WatchProgressEntry>,
        preferFurthestEpisode: Boolean,
        dismissedNextUpKeys: Set<String>,
        limit: Int,
    ): List<ContinueWatchingNextUpSeed> {
        val seams = seedSeams(watchedItems)
        return buildContinueWatchingNextUpSeeds(
            progressEntries = seams.progressEntries,
            watchedItems = seams.watchedItems,
            inProgressEntries = inProgressEntries,
            preferFurthestEpisode = preferFurthestEpisode,
            dismissedNextUpKeys = dismissedNextUpKeys,
            recencyCutoffEpochMs = seams.recencyCutoffEpochMs,
            limit = limit,
            shouldUseProgressSeed = seams.shouldUseProgressSeed,
            isContentHidden = seams.isContentHidden,
            nowEpochMs = seams.nowEpochMs,
        )
    }

    /**
     * CW alias fix: the dismiss keys that keep every Up Next card of [card]'s series off the row,
     * under all of its stored ids ([continueWatchingNextUpSeriesDismissKeys]), with the same seams
     * as [seeds]. For "Remove from Continue Watching" on [card], in progress or Up Next.
     *
     * Called from the Swift main thread, so it never throws: on a failure nothing more is dismissed.
     */
    fun seriesDismissKeys(
        card: WatchProgressEntry,
        watchedItems: List<WatchedItem>,
        inProgressEntries: List<WatchProgressEntry>,
        preferFurthestEpisode: Boolean,
        dismissedNextUpKeys: Set<String>,
    ): Set<String> = try {
        val seams = seedSeams(watchedItems)
        continueWatchingNextUpSeriesDismissKeys(
            card = card,
            progressEntries = seams.progressEntries,
            watchedItems = seams.watchedItems,
            inProgressEntries = inProgressEntries,
            preferFurthestEpisode = preferFurthestEpisode,
            dismissedNextUpKeys = dismissedNextUpKeys,
            recencyCutoffEpochMs = seams.recencyCutoffEpochMs,
            shouldUseProgressSeed = seams.shouldUseProgressSeed,
            isContentHidden = seams.isContentHidden,
            nowEpochMs = seams.nowEpochMs,
        )
    } catch (error: Throwable) {
        log.e(error) { "Failed to list the Up Next dismiss keys of ${card.parentMetaId}" }
        emptySet()
    }

    /** What the last [resolveCard] of each seed gave, by dismiss key (the diagnostics' `up=`). */
    internal fun resolutionOutcomes(): Map<String, String> = synchronized(outcomeLock) { outcomeBySeedKey.toMap() }

    /** Sign-out: another account's seeds start unresolved. */
    internal fun clearResolutionOutcomes() {
        synchronized(outcomeLock) { outcomeBySeedKey.clear() }
    }

    private fun noteResolutionOutcome(seed: ContinueWatchingNextUpSeed, resolution: ContinueWatchingNextUpResolution) {
        val entry = resolution.entry
        val outcome = when {
            !resolution.isConclusive -> "fail"
            entry == null -> "none"
            else -> "S${entry.seasonNumber}E${entry.episodeNumber}"
        }
        synchronized(outcomeLock) {
            outcomeBySeedKey.remove(seed.dismissKey)
            outcomeBySeedKey[seed.dismissKey] = outcome
            while (outcomeBySeedKey.size > MAX_REMEMBERED_OUTCOMES) {
                outcomeBySeedKey.remove(outcomeBySeedKey.keys.first())
            }
        }
    }

    /**
     * Resolves [seed]'s Up Next card: the series meta (cache-first), the active provider's episode
     * numbering, then [continueWatchingNextUpEntry]. Never throws — a failure is a non-conclusive
     * resolution the caller may retry.
     */
    suspend fun resolveCard(
        seed: ContinueWatchingNextUpSeed,
        watchedItems: List<WatchedItem>,
        todayIsoDate: String,
        preferFurthestEpisode: Boolean,
    ): ContinueWatchingNextUpResolution {
        val resolution = resolveCardOrFailure(
            seed = seed,
            watchedItems = watchedItems,
            todayIsoDate = todayIsoDate,
            preferFurthestEpisode = preferFurthestEpisode,
        )
        try {
            noteResolutionOutcome(seed, resolution)
        } catch (error: Throwable) {
            log.w { "Up Next outcome not noted for ${seed.dismissKey}: ${error.message}" }
        }
        return resolution
    }

    private suspend fun resolveCardOrFailure(
        seed: ContinueWatchingNextUpSeed,
        watchedItems: List<WatchedItem>,
        todayIsoDate: String,
        preferFurthestEpisode: Boolean,
    ): ContinueWatchingNextUpResolution = try {
        val meta = MetaDetailsRepository.fetch(type = seed.contentType, id = seed.contentId)
        // CW alias fix: the series meta names its IMDb id, which the row groups the seed under.
        meta?.let { ContinueWatchingSeriesIdentity.record(requestedId = seed.contentId, meta = it) }
        if (meta == null) {
            ContinueWatchingNextUpResolution(entry = null, isConclusive = false)
        } else {
            val entries = WatchProgressRepository.prepareNextUpProgressEntries(
                entries = WatchProgressRepository.uiState.value.entries,
                contentId = seed.contentId,
            )
            ContinueWatchingNextUpResolution(
                entry = meta.continueWatchingNextUpEntry(
                    seed = seed,
                    progressEntries = entries,
                    watchedItems = if (WatchProgressRepository.activeProviderOwnsCompletedHistoryProjection()) {
                        emptyList()
                    } else {
                        watchedItems
                    },
                    todayIsoDate = todayIsoDate,
                    preferFurthestEpisode = preferFurthestEpisode,
                ),
                isConclusive = true,
            )
        }
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        ContinueWatchingNextUpResolution(entry = null, isConclusive = false)
    }
}
