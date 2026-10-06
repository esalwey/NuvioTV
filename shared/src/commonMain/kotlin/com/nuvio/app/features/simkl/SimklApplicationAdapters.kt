package com.nuvio.app.features.simkl

import co.touchlab.kermit.Logger
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tracking.TrackingHistoryItem
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProgressProvider
import com.nuvio.app.features.tracking.TrackingProgressSnapshot
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import com.nuvio.app.features.tracking.TrackingWatchedProvider
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watchprogress.TrackerOptimisticProgressTtlMs
import com.nuvio.app.features.watchprogress.WatchProgressEntry
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

object SimklWatchedSyncAdapter : TrackingWatchedProvider {
    private val log = Logger.withTag("SimklWatched")
    override val providerId: TrackingProviderId = TrackingProviderId.SIMKL
    override suspend fun pull(profileId: Int, pageSize: Int): List<WatchedItem> {
        if (profileId != ProfileRepository.activeProfileId) return emptyList()
        SimklSyncRepository.refresh(
            intent = TrackingRefreshIntent.AUTOMATIC,
            origin = SimklRefreshOrigin.WATCHED_ITEMS,
        )
        val snapshot = SimklSyncRepository.state.value.snapshot
        val projection = snapshot.toSimklWatchedProjection()
        SimklWatchDiagnostics.logProjection(
            stage = "items-pull",
            snapshot = snapshot,
            projection = projection,
        )
        return projection.items
    }

    override suspend fun pullFullyWatchedSeriesKeys(profileId: Int): Set<String>? {
        // Simkl "completed" = all episodes watched; Nuvio "completed" = all
        // *available* episodes watched. Let local revalidation decide.
        return null
    }

    override suspend fun pullExtraWatchedKeys(profileId: Int): Set<String> {
        if (profileId != ProfileRepository.activeProfileId) return emptySet()
        SimklSyncRepository.refresh(
            intent = TrackingRefreshIntent.AUTOMATIC,
            origin = SimklRefreshOrigin.WATCHED_ITEMS,
        )
        val snapshot = SimklSyncRepository.state.value.snapshot
        return snapshot.animeAlternateWatchedKeys() + snapshot.movieAlternateWatchedKeys()
    }

    override fun observeExtraWatchedKeys(profileId: Int): kotlinx.coroutines.flow.Flow<Set<String>> =
        SimklSyncRepository.state
            .map { state ->
                SimklAnimeWatchedFallback.clearOptimisticRemovals()
                state.snapshot.animeAlternateWatchedKeys() + state.snapshot.movieAlternateWatchedKeys()
            }
            .distinctUntilChanged()

    override suspend fun push(profileId: Int, items: Collection<WatchedItem>) {
        if (profileId != ProfileRepository.activeProfileId || items.isEmpty()) return
        // Upstream ba7862154: a mark without episode coordinates is a whole series, which Simkl
        // answers by marking every episode of the show watched.
        val pushableItems = simklHistoryPushItems(items)
        if (pushableItems.isEmpty()) {
            log.i { "Skipped ${items.size} Simkl history items: nothing but whole-series marks" }
            return
        }
        SimklSyncRepository.ensureLoaded()
        val snapshot = SimklSyncRepository.state.value.snapshot
        val historyItems = pushableItems.map { item ->
            TrackingHistoryItem(
                media = snapshot.mediaReference(
                    contentId = item.id,
                    contentType = item.type,
                    title = item.name,
                    releaseInfo = item.releaseInfo,
                    season = item.season,
                    episode = item.episode,
                    videoId = item.videoId,
                    // Upstream 542aa5701: the catalog poster seeds the local entry until Simkl's own
                    // poster arrives with the next library refresh.
                    posterUrl = item.poster,
                ),
                watchedAtEpochMs = item.markedAtEpochMs,
            )
        }
        val result = SimklMutationRepository.addToHistory(profileId = profileId, items = historyItems)
        check(result.isComplete) {
            "Simkl could not match ${result.notFoundCount} of ${result.attemptedCount} watched items"
        }
    }

    override suspend fun delete(profileId: Int, items: Collection<WatchedItem>) {
        if (profileId != ProfileRepository.activeProfileId || items.isEmpty()) return
        // Fork: upstream filters to episode entries here and returns early when there are none,
        // so unmarking a MOVIE never reached /sync/history/remove — it vanished locally and
        // reappeared on the next refresh. Movies are forwarded now, but series-level markers are
        // NOT: such an item has no season/episode, so it would become a show-level
        // /sync/history/remove that deletes the entire show's episode history on Simkl. That is
        // not hypothetical — reconcileSeriesWatchedState drops the series marker AUTOMATICALLY
        // (e.g. once a new episode airs and the show is no longer fully watched), which would
        // silently wipe history the user never asked to remove.
        // Allowlist, not denylist: an unrecognized type is skipped rather than sent destructively.
        val removableItems = items.filter { item -> item.isSimklHistoryRemovable() }
        if (removableItems.isEmpty()) return
        val episodeItems = removableItems.filter { item -> item.season != null && item.episode != null }
        // Optimistically mark video IDs as removed so fallback won't show them as watched
        episodeItems.forEach { item -> item.videoId?.let(SimklAnimeWatchedFallback::markOptimisticallyRemoved) }
        SimklSyncRepository.ensureLoaded()
        val snapshot = SimklSyncRepository.state.value.snapshot
        val media = removableItems.map { item ->
            snapshot.mediaReference(
                contentId = item.id,
                contentType = item.type,
                title = item.name,
                releaseInfo = item.releaseInfo,
                season = item.season,
                episode = item.episode,
                videoId = item.videoId,
            ).let { ref ->
                val enriched = snapshot.enrichMediaReference(ref)
                // Anime episode resolution is meaningless without a season/episode pair.
                if (item.season != null && item.episode != null) {
                    enriched.resolveAnimeEpisodeForSimkl()
                } else {
                    enriched
                }
            }
        }
        val result = SimklMutationRepository.removeFromHistory(profileId = profileId, items = media)
        check(result.isComplete) {
            "Simkl could not match ${result.notFoundCount} of ${result.attemptedCount} watched items"
        }
    }
}

data class SimklProgressUiState(
    val entries: List<WatchProgressEntry> = emptyList(),
    val isLoading: Boolean = false,
    val hasLoadedRemoteProgress: Boolean = false,
    val errorMessage: String? = null,
    val hiddenContentIds: Set<String> = emptySet(),
)

/**
 * What may travel to Simkl as a watched mark (upstream ba7862154).
 *
 * A mark without episode coordinates describes a whole series. Simkl turns that into a show-level
 * entry and answers by marking every episode of the show watched, including episodes the user never
 * opened, which is how a single ill-timed mark wiped a full series. Only films are allowed through
 * without coordinates; a whole-series action still reports its episodes one by one (`WatchingActions`
 * marks the series and its released episodes together), which carries the same information and cannot
 * touch anything else. A mark whose type is `anime` is dropped too: the app cannot tell an anime film
 * from an anime series without more metadata, and Trakt's adapter drops both for the same reason. That
 * is the accepted trade, because a mark the user made by hand staying out of the history is cheaper
 * than a single call stamping a whole series.
 */
internal fun simklHistoryPushItems(items: Collection<WatchedItem>): List<WatchedItem> =
    items.filterNot(WatchedItem::isWholeSeriesMark)

private fun WatchedItem.isWholeSeriesMark(): Boolean =
    season == null && episode == null && type.trim().lowercase() !in MOVIE_LIKE_WATCHED_TYPES

/** Content types that stand on their own and need no episode to be a real mark. */
private val MOVIE_LIKE_WATCHED_TYPES = setOf("movie", "film")

object SimklProgressRepository {
    private val log = Logger.withTag("SimklProgress")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _uiState = MutableStateFlow(SimklProgressUiState())
    val uiState: StateFlow<SimklProgressUiState> = _uiState.asStateFlow()
    private val publicationLock = SynchronizedObject()
    private val projectionCache = SimklSnapshotProjectionCache(SimklSyncSnapshot::toSimklProgressEntries)
    private var publishedSyncState: SimklSyncUiState? = null

    /** CW sync #3: local playback over the snapshot until Simkl catches up. Guarded by [publicationLock]. */
    private val optimisticProgress = SimklOptimisticProgressOverlay()

    init {
        scope.launch {
            SimklSyncRepository.state.collectLatest { syncState -> publish(syncState) }
        }
    }

    fun ensureLoaded() {
        SimklAuthRepository.ensureLoaded()
        SimklSyncRepository.ensureLoaded()
        publish(SimklSyncRepository.state.value)
    }

    suspend fun refresh(intent: TrackingRefreshIntent) {
        SimklSyncRepository.refresh(
            intent = intent,
            origin = SimklRefreshOrigin.PROGRESS,
        )
        publish(SimklSyncRepository.state.value)
    }

    suspend fun removeProgress(entries: Collection<WatchProgressEntry>) {
        val sessionIds = entries.mapNotNullTo(linkedSetOf()) { entry ->
            entry.progressKey
                ?.removePrefix(SIMKL_PLAYBACK_PROGRESS_KEY_PREFIX)
                ?.takeIf { entry.progressKey.startsWith(SIMKL_PLAYBACK_PROGRESS_KEY_PREFIX) }
                ?.toLongOrNull()
                ?.takeIf { it > 0L }
        }
        if (sessionIds.isEmpty()) return

        val removed = linkedSetOf<Long>()
        for (sessionId in sessionIds) {
            try {
                SimklApi.client.execute(
                    SimklApiRequest(
                        method = SimklHttpMethod.DELETE,
                        path = "/sync/playback/$sessionId",
                    ),
                )
                removed += sessionId
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                val apiError = error as? SimklApiException
                log.w {
                    "Failed to remove Simkl playback: status=${apiError?.status} " +
                        "code=${apiError?.errorCode ?: "transport_failure"}"
                }
            }
        }
        SimklSyncRepository.commitPlaybackRemoval(removed)
    }

    /**
     * CW sync #3: a local progress write (the players' ticks and flushes, through
     * `WatchProgressRepository.upsert` while Simkl is the source) shows on Continue Watching right
     * away instead of waiting for a scrobble to commit — see [SimklOptimisticProgressOverlay].
     */
    fun applyOptimisticProgress(entry: WatchProgressEntry) {
        if (!SimklAuthRepository.isAuthenticated.value) return
        synchronized(publicationLock) {
            val changed = optimisticProgress.put(
                profileId = ProfileRepository.activeProfileId,
                entry = entry,
                nowEpochMs = SimklPlatformClock.nowEpochMs(),
            )
            if (changed) publishLocked(SimklSyncRepository.state.value, overlayChanged = true)
        }
    }

    /** A removal from Continue Watching takes the local rows of those episodes along. */
    fun applyOptimisticRemoval(entries: Collection<WatchProgressEntry>) {
        if (entries.isEmpty()) return
        synchronized(publicationLock) {
            if (optimisticProgress.removeEpisodes(entries)) {
                publishLocked(SimklSyncRepository.state.value, overlayChanged = true)
            }
        }
    }

    fun applyOptimisticRemovalByVideoIds(videoIds: Collection<String>) {
        if (videoIds.isEmpty()) return
        synchronized(publicationLock) {
            if (optimisticProgress.removeVideoIds(videoIds)) {
                publishLocked(SimklSyncRepository.state.value, overlayChanged = true)
            }
        }
    }

    /**
     * Keeps the local rows of [contentId] on Continue Watching until at least [untilEpochMs] — while
     * a scrobble stop is in flight, and after one failed (`SimklMutationRepository.scrobble`). Both
     * the id as played and Simkl's canonical id for it match (rows are written under the canonical
     * one). Returns how many rows it holds.
     */
    internal fun holdOptimisticProgress(profileId: Int, contentId: String, untilEpochMs: Long): Int {
        val canonicalId = runCatching {
            SimklSyncRepository.state.value.snapshot.resolveCanonicalContentId(contentId)
        }.getOrNull()
        return synchronized(publicationLock) {
            optimisticProgress.hold(
                profileId = profileId,
                contentIds = listOfNotNull(contentId, canonicalId),
                untilEpochMs = untilEpochMs,
                nowEpochMs = SimklPlatformClock.nowEpochMs(),
            )
        }
    }

    /**
     * CW sync #3 (review): a stop of [contentId] reached Simkl, so the in-flight hold that
     * [holdOptimisticProgress] set up to [heldUntilEpochMs] is released. The rows go back to the
     * plain TTL, counted from now, like Trakt's `releaseOptimisticProgressHold`. Returns how many
     * rows it released.
     */
    internal fun releaseOptimisticProgressHold(profileId: Int, contentId: String, heldUntilEpochMs: Long): Int {
        val canonicalId = runCatching {
            SimklSyncRepository.state.value.snapshot.resolveCanonicalContentId(contentId)
        }.getOrNull()
        return synchronized(publicationLock) {
            optimisticProgress.release(
                profileId = profileId,
                contentIds = listOfNotNull(contentId, canonicalId),
                untilEpochMs = SimklPlatformClock.nowEpochMs() + TrackerOptimisticProgressTtlMs,
                heldUntilEpochMs = heldUntilEpochMs,
            )
        }
    }

    /** Profile switch, sign-out, or Simkl becoming the source again: no local rows carry over. */
    fun clearOptimisticProgress() {
        synchronized(publicationLock) {
            if (optimisticProgress.clear()) {
                publishLocked(SimklSyncRepository.state.value, overlayChanged = true)
            }
        }
    }

    // Upstream 73005d996: the same sync state is published once, and its progress projection and
    // hidden ids are computed once per snapshot instead of on every read.
    private fun publish(syncState: SimklSyncUiState) {
        synchronized(publicationLock) {
            publishLocked(syncState, overlayChanged = false)
        }
    }

    /**
     * Caller holds [publicationLock]. The same sync state is published again only when the local
     * rows changed; a new one first reconciles them with its projection (CW sync #3).
     */
    private fun publishLocked(syncState: SimklSyncUiState, overlayChanged: Boolean) {
        if (syncState !== SimklSyncRepository.state.value) return
        val snapshotChanged = syncState !== publishedSyncState
        if (!snapshotChanged && !overlayChanged) return
        val nowEpochMs = SimklPlatformClock.nowEpochMs()
        val projected = projectionCache.get(syncState)
        if (snapshotChanged) optimisticProgress.reconcile(projected, nowEpochMs)
        _uiState.value = SimklProgressUiState(
            entries = optimisticProgress.merge(
                profileId = ProfileRepository.activeProfileId,
                snapshotEntries = projected,
                nowEpochMs = nowEpochMs,
            ),
            isLoading = syncState.isLoading,
            hasLoadedRemoteProgress = syncState.hasLoaded && syncState.errorMessage == null,
            errorMessage = syncState.errorMessage,
            hiddenContentIds = syncState.snapshot.hiddenFromContinueWatchingContentIds(),
        )
        publishedSyncState = syncState
    }
}

/** One projection per snapshot and projection version (upstream 73005d996). */
internal class SimklSnapshotProjectionCache<T : Any>(
    private val project: (SimklSyncSnapshot) -> T,
) {
    private var snapshot: SimklSyncSnapshot? = null
    private var projectionVersion = 0L
    private var projection: T? = null

    fun get(state: SimklSyncUiState): T {
        val current = projection
        if (current != null && snapshot === state.snapshot && projectionVersion == state.projectionVersion) {
            return current
        }
        return project(state.snapshot).also { updated ->
            snapshot = state.snapshot
            projectionVersion = state.projectionVersion
            projection = updated
        }
    }
}

object SimklTrackingProgressProvider : TrackingProgressProvider {
    override val providerId: TrackingProviderId = TrackingProviderId.SIMKL
    override val changes: Flow<Unit> = SimklProgressRepository.uiState.map { Unit }

    override fun ensureLoaded() = SimklProgressRepository.ensureLoaded()

    override fun onProfileChanged() {
        SimklProgressRepository.clearOptimisticProgress()
        SimklProgressRepository.ensureLoaded()
    }

    override fun clearLocalState() = SimklProgressRepository.clearOptimisticProgress()

    override fun onActivated() = SimklProgressRepository.clearOptimisticProgress()

    override suspend fun refresh(force: Boolean, sourceChanged: Boolean) =
        SimklProgressRepository.refresh(simklProgressRefreshIntent)

    override fun snapshot(): TrackingProgressSnapshot {
        val state = SimklProgressRepository.uiState.value
        return TrackingProgressSnapshot(
            entries = state.entries,
            hiddenContentIds = state.hiddenContentIds,
            hasLoadedRemoteProgress = state.hasLoadedRemoteProgress,
            errorMessage = state.errorMessage,
        )
    }

    override suspend fun removeProgress(entries: Collection<WatchProgressEntry>) =
        SimklProgressRepository.removeProgress(entries)

    override fun applyOptimisticProgress(entry: WatchProgressEntry) =
        SimklProgressRepository.applyOptimisticProgress(entry)

    override fun applyOptimisticRemoval(entries: Collection<WatchProgressEntry>) =
        SimklProgressRepository.applyOptimisticRemoval(entries)

    override fun applyOptimisticRemovalByVideoIds(videoIds: Collection<String>) =
        SimklProgressRepository.applyOptimisticRemovalByVideoIds(videoIds)

    override fun isHiddenFromProgress(contentId: String): Boolean =
        SimklSyncRepository.state.value.snapshot.isHiddenFromContinueWatching(contentId)

    override fun normalizeParentContentId(parentContentId: String, videoId: String?): String {
        val snapshot = SimklSyncRepository.state.value.snapshot
        val resolvedId = snapshot.resolveCanonicalContentId(parentContentId)
        return resolvedId ?: parentContentId
    }
}

private const val SIMKL_PLAYBACK_PROGRESS_KEY_PREFIX = "simkl-playback:"

/**
 * Fork: which watched entries may be forwarded to Simkl's `/sync/history/remove`.
 *
 * Episodes and movies map to a single Simkl history entry, so removing them is precise. A
 * series-level marker has no season/episode and would serialize as a bare show, which Simkl treats
 * as "remove this show's entire history" — far more destructive than the local marker it mirrors.
 *
 * Deliberately an allowlist: anything whose type is unrecognized (or that carries a partial
 * season/episode pair) is skipped rather than sent, so the failure mode is a stale Simkl entry
 * instead of deleted history.
 */
private fun WatchedItem.isSimklHistoryRemovable(): Boolean {
    val isEpisode = season != null && episode != null
    val isMovie = type.trim().lowercase() in MOVIE_LIKE_WATCHED_TYPES
    return isEpisode || isMovie
}
