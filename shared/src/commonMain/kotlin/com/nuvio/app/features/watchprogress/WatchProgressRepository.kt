package com.nuvio.app.features.watchprogress

import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.features.addons.AddonManifest
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.AddonsUiState
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.tracking.TrackingProgressProvider
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.TrackingSettingsRepository
import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.tracking.effectiveWatchProgressSource
import com.nuvio.app.features.tracking.providerId
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watching.application.WatchingActions
import com.nuvio.app.features.watching.sync.ProgressDeltaEvent
import com.nuvio.app.features.watching.sync.ProgressSyncRecord
import com.nuvio.app.features.watching.sync.ProgressSyncAdapter
import com.nuvio.app.features.watching.sync.SupabaseProgressSyncAdapter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit

private const val WATCH_PROGRESS_METADATA_RESOLUTION_CONCURRENCY = 4
private const val WATCH_PROGRESS_METADATA_RESOLUTION_LIMIT = 64
private const val WATCH_PROGRESS_METADATA_FETCH_ATTEMPTS = 3
private const val WATCH_PROGRESS_METADATA_RETRY_BASE_DELAY_MS = 750L
private const val WATCH_PROGRESS_DELTA_PAGE_SIZE = 900
private const val WATCH_PROGRESS_DELTA_OPERATION_UPSERT = "upsert"
private const val WATCH_PROGRESS_DELTA_OPERATION_DELETE = "delete"
private const val WATCH_PROGRESS_REMOTE_WRITE_DEDUP_WINDOW_MS = 5_000L
internal const val WATCH_PROGRESS_BACKLOG_PUSH_LIMIT = 200
/** Mirrors `ContinueWatchingNextUpModel.seedLimit` (Swift): the seeds a Home row build considers. */
private const val CONTINUE_WATCHING_DIAGNOSTICS_SEED_LIMIT = 20
private const val CONTINUE_WATCHING_SERIES_IDENTITY_WARM_UP_CONCURRENCY = 2

/** How far ahead of this device's clock a server row may be dated (CW legacy #3). */
internal const val WATCH_PROGRESS_SERVER_FUTURE_TOLERANCE_MS = 10 * 60_000L

/**
 * How many distinct server rows dated ahead of the clock make the log say this device's clock is
 * probably the wrong one (CW legacy #3, review): then it is behind, and every row the other
 * devices wrote in the last minutes counts as undated here.
 */
private const val WATCH_PROGRESS_FUTURE_ROWS_CLOCK_WARNING = 5

/**
 * [epochMs], or 0 (undated) when it is more than [WATCH_PROGRESS_SERVER_FUTURE_TOLERANCE_MS] ahead
 * of [nowEpochMs]: a date a device with a wrong clock wrote. 0 and not [nowEpochMs]: a clamp to
 * the clock would move forward on every read and outrank the rows written here since.
 */
internal fun undatedWhenAheadOfClock(epochMs: Long, nowEpochMs: Long): Long =
    if (epochMs > nowEpochMs + WATCH_PROGRESS_SERVER_FUTURE_TOLERANCE_MS) 0L else epochMs

/**
 * CW legacy diagnosis (REMAINING_FIX #3): the date a server row gets locally. A `last_watched`
 * more than [WATCH_PROGRESS_SERVER_FUTURE_TOLERANCE_MS] ahead of [nowEpochMs] (a device with a
 * wrong clock wrote it) becomes 0, undated: otherwise it outranks every real row of its series,
 * for good — the local rows written since are older than it, in the snapshot merge, in the delta
 * decision and in the acknowledgement alike. Undated, it loses to any dated row, a dirty local
 * row of the same key stays local and dirty (so the backlog push rewrites the account's copy),
 * and it sorts last in Continue Watching.
 */
internal fun serverLastWatchedForLocalUse(lastWatched: Long, nowEpochMs: Long): Long =
    undatedWhenAheadOfClock(epochMs = lastWatched, nowEpochMs = nowEpochMs)

/**
 * CW alias fix (review): the rows a server pull may put back locally — [entries] without the
 * progress keys removed here whose server delete has not completed yet ([pendingDeleteKeys]).
 * The delete waits for the pull lock, so a pull that read the account before a removal would
 * otherwise merge the removed rows back (as synced rows, which nothing removes again until a later
 * pull), and the card would come back on Home. A key written here again since ([dirtyProgressKeys])
 * is a new local write, and stays.
 */
internal fun withoutPendingServerDeletes(
    entries: Collection<WatchProgressEntry>,
    pendingDeleteKeys: Set<String>,
    dirtyProgressKeys: Set<String>,
): List<WatchProgressEntry> =
    if (pendingDeleteKeys.isEmpty()) {
        entries.toList()
    } else {
        entries.filter { entry ->
            val key = entry.resolvedProgressKey()
            key !in pendingDeleteKeys || key in dirtyProgressKeys
        }
    }

/** Where a playback write goes, by profile (CW legacy #4). */
internal enum class PlaybackWriteProfilePath {
    /** The loaded profile, which is the active one: the in-memory path. */
    LOADED,

    /**
     * The active profile, while another one is loaded here: that profile is loaded first, then
     * the write takes the in-memory path, so Home (which reads the in-memory state) sees it.
     */
    RELOAD_ACTIVE,

    /** A profile that is not the active one: written to its stored payload only. */
    OTHER_PROFILE,
}

internal fun playbackWriteProfilePath(
    targetProfileId: Int,
    loadedProfileId: Int,
    activeProfileId: Int,
): PlaybackWriteProfilePath = when {
    targetProfileId != activeProfileId -> PlaybackWriteProfilePath.OTHER_PROFILE
    targetProfileId != loadedProfileId -> PlaybackWriteProfilePath.RELOAD_ACTIVE
    else -> PlaybackWriteProfilePath.LOADED
}

/**
 * CW sync (REMAINING_FIX #2): the rows the one-time post-pull backlog push sends — local rows whose
 * key is still dirty, newest first, at most [limit]. Rows without a content or video id are left
 * out: the server needs both, and one malformed row would fail the whole batch.
 *
 * Run right after a successful Nuvio pull, "still dirty" means the local row is newer than the
 * account's copy or the account has none (the pull merges acknowledge every key the server already
 * matches): up to build 130 every tvOS write passed `syncRemote = false`, and PLY-4 only pushes new
 * saves, so those rows would otherwise never reach the account.
 *
 * "The account has none" can also mean the account deleted it. The deletes a delta pull brings
 * withdraw the rows they supersede ([dirtyProgressKeysWithdrawnByServerDeletes]), so those are not
 * selected here. Two cases stay out of reach, a known effect on the other devices:
 * - a delete that builds 130/131 consumed before this pass existed;
 * - a snapshot pull, which carries no deletes: a row is only missing, and the snapshot holds at
 *   most the account's 200 newest rows.
 * Rows like these are still pushed, so a show removed from Continue Watching on another device can
 * come back there.
 */
internal fun selectDirtyWatchProgressBacklog(
    entries: Collection<WatchProgressEntry>,
    dirtyProgressKeys: Set<String>,
    limit: Int = WATCH_PROGRESS_BACKLOG_PUSH_LIMIT,
): List<WatchProgressEntry> {
    if (dirtyProgressKeys.isEmpty() || limit <= 0) return emptyList()
    return entries.newestByProgressKey()
        .filter { (key, entry) ->
            key in dirtyProgressKeys && entry.parentMetaId.isNotBlank() && entry.videoId.isNotBlank()
        }
        .values
        .sortedWith(
            compareByDescending<WatchProgressEntry> { entry -> entry.lastUpdatedEpochMs }
                .thenBy { entry -> entry.resolvedProgressKey() },
        )
        .take(limit)
}

/**
 * CW sync #2 (review): the dirty keys that the server deletes of one delta pull withdraw from sync.
 * [entries] and [dirtyProgressKeys] are the local state once the pull has applied those deletes.
 *
 * A dirty row written before [writtenBeforeEpochMs] (the start of that pull) is withdrawn when:
 * - its own key was deleted ([deletedProgressKeys]): the merge keeps the row, but the other
 *   device removed that episode from Continue Watching, or marked it watched or unwatched (both
 *   clear its progress), after this row was written;
 * - or its show was deleted ([deletedContentIds]) and no synced row of the show is left on this
 *   device: the account no longer holds any progress of it, which is what a removal of the show
 *   from Continue Watching on another device looks like. The account only held the episodes that
 *   device knew, so rows of other episodes are withdrawn too. While a synced row of the show is
 *   left, the delete was about single episodes and the show's other rows are kept.
 *
 * A row written during the pull is left alone: it is a local update the delete cannot know about,
 * which is also why the merge preserves it.
 *
 * Only the backlog would push such a row again and put back what the user just removed: a row
 * still being played is written again and marked dirty again. The rows stay on this device and are
 * only no longer dirty. No push re-sends them, and the next snapshot pull (which only keeps the
 * dirty rows the server lacks) lets them go, as the account did.
 */
internal fun dirtyProgressKeysWithdrawnByServerDeletes(
    entries: Collection<WatchProgressEntry>,
    dirtyProgressKeys: Set<String>,
    deletedProgressKeys: Set<String>,
    deletedContentIds: Set<String>,
    writtenBeforeEpochMs: Long,
): Set<String> {
    if (dirtyProgressKeys.isEmpty() || (deletedProgressKeys.isEmpty() && deletedContentIds.isEmpty())) {
        return emptySet()
    }
    val entriesByKey = entries.newestByProgressKey()
    val showsGoneFromAccount = deletedContentIds.filterTo(mutableSetOf()) { contentId ->
        entriesByKey.none { (key, entry) -> key !in dirtyProgressKeys && entry.parentMetaId.trim() == contentId }
    }
    return entriesByKey
        .filter { (key, entry) ->
            key in dirtyProgressKeys &&
                entry.lastUpdatedEpochMs < writtenBeforeEpochMs &&
                (key in deletedProgressKeys || entry.parentMetaId.trim() in showsGoneFromAccount)
        }
        .keys
}

private data class RemoteMetadataResolutionResult(
    val key: WatchProgressMetadataKey,
    val entries: List<WatchProgressEntry>,
    val meta: MetaDetails?,
)

private data class MetadataProviderReadiness(
    val providers: List<AddonManifest>,
) {
    val fingerprint: String
        get() = providers.map(AddonManifest::transportUrl).sorted().joinToString(separator = "|")

    val isReady: Boolean
        get() = providers.isNotEmpty()
}

// Fork: public (upstream: internal) — composeApp WatchProgressIdentityTest consumes this cross-module.
class MetadataResolutionRetryCoordinator {
    private val lock = SynchronizedObject()
    private var generation = 0L
    private var activeGeneration: Long? = null
    private var activeProviderFingerprint: String? = null
    private var lastRequestedProviderFingerprint: String? = null
    private var pendingProviderFingerprint: String? = null

    fun reset() {
        synchronized(lock) {
            generation += 1L
            activeGeneration = null
            activeProviderFingerprint = null
            lastRequestedProviderFingerprint = null
            pendingProviderFingerprint = null
        }
    }

    fun invalidateActiveResolution() {
        synchronized(lock) {
            generation += 1L
            activeGeneration = null
            activeProviderFingerprint = null
            pendingProviderFingerprint = null
        }
    }

    fun requestForProviders(providerFingerprint: String): Boolean =
        synchronized(lock) {
            if (activeGeneration != null) {
                if (providerFingerprint != activeProviderFingerprint) {
                    pendingProviderFingerprint = providerFingerprint
                }
                return@synchronized false
            }
            if (providerFingerprint == lastRequestedProviderFingerprint) {
                return@synchronized false
            }

            lastRequestedProviderFingerprint = providerFingerprint
            true
        }

    fun beginResolution(providerFingerprint: String?): Long =
        synchronized(lock) {
            generation += 1L
            activeGeneration = generation
            activeProviderFingerprint = providerFingerprint
            pendingProviderFingerprint = null
            if (providerFingerprint != null) {
                lastRequestedProviderFingerprint = providerFingerprint
            }
            generation
        }

    fun providersObservedBeforeFetch(
        resolutionGeneration: Long,
        providerFingerprint: String,
    ) {
        synchronized(lock) {
            if (activeGeneration != resolutionGeneration) return@synchronized
            activeProviderFingerprint = providerFingerprint
            lastRequestedProviderFingerprint = providerFingerprint
            if (pendingProviderFingerprint == providerFingerprint) {
                pendingProviderFingerprint = null
            }
        }
    }

    fun finishResolution(
        resolutionGeneration: Long,
        currentProviderFingerprint: String?,
    ): Boolean = synchronized(lock) {
        if (activeGeneration != resolutionGeneration) return@synchronized false

        activeGeneration = null
        val shouldRetry = currentProviderFingerprint != null &&
            currentProviderFingerprint != activeProviderFingerprint &&
            (pendingProviderFingerprint != null ||
                currentProviderFingerprint != lastRequestedProviderFingerprint)
        activeProviderFingerprint = null
        pendingProviderFingerprint = null
        if (shouldRetry) {
            lastRequestedProviderFingerprint = currentProviderFingerprint
        }
        shouldRetry
    }
}

private data class WatchProgressDeltaApplyResult(
    val appliedUpserts: Int,
    val appliedDeletes: Int,
    val preservedLocalItems: Boolean,
    val changed: Boolean,
    /** Dirty keys the page's deletes withdrew from sync ([dirtyProgressKeysWithdrawnByServerDeletes]). */
    val withdrawnDirtyKeys: Int = 0,
)

// Fork: public (upstream: internal) — composeApp WatchProgressIdentityTest consumes these cross-module.
enum class WatchProgressDeltaDecisionType {
    UPSERT,
    DELETE,
    PRESERVE_LOCAL,
    IGNORE,
}

data class WatchProgressDeltaDecision(
    val type: WatchProgressDeltaDecisionType,
    val updatedEntry: WatchProgressEntry? = null,
    val clearsDirtyProgress: Boolean = false,
)

fun enrichWatchProgressEntry(
    current: WatchProgressEntry,
    meta: MetaDetails,
): WatchProgressEntry {
    val episodeVideo = if (current.seasonNumber != null && current.episodeNumber != null) {
        meta.videos.firstOrNull { video ->
            video.season == current.seasonNumber && video.episode == current.episodeNumber
        }
    } else {
        null
    }
    return current.copy(
        title = meta.name.takeIf(String::isNotBlank) ?: current.title,
        poster = meta.poster?.takeIf(String::isNotBlank) ?: current.poster,
        background = meta.background?.takeIf(String::isNotBlank) ?: current.background,
        logo = meta.logo?.takeIf(String::isNotBlank) ?: current.logo,
        episodeTitle = episodeVideo?.title?.takeIf(String::isNotBlank) ?: current.episodeTitle,
        episodeThumbnail = episodeVideo?.thumbnail?.takeIf(String::isNotBlank) ?: current.episodeThumbnail,
        pauseDescription = episodeVideo?.overview?.takeIf(String::isNotBlank)
            ?: meta.description?.takeIf(String::isNotBlank)
            ?: current.pauseDescription,
    )
}

fun WatchProgressEntry.needsRemoteMetadataEnrichment(): Boolean =
    title.isBlank() ||
        title.equals(parentMetaId, ignoreCase = true) ||
        poster.isNullOrBlank() ||
        background.isNullOrBlank()

private data class RemoteProgressWriteKey(
    val profileId: Int,
    val progressKey: String,
)

private data class RemoteProgressWrite(
    val entry: WatchProgressEntry,
    val sentAtEpochMs: Long,
)

// Upstream-faithful (d0c7bff7): a suppressed write is a complete no-op — local upsert, persist,
// publish, and the completion cascade are all skipped, not just the network push. That is safe
// because suppression requires the entry to be CONTENT-IDENTICAL (everything but
// `lastUpdatedEpochMs`) to one sent < windowMs ago: the first write already persisted the same
// state, marked its key dirty, and ran the cascade. The remaining hazard is DELIVERY, not state:
// entries are recorded here at send time, before the async push resolves, and dirty keys only
// win pull merges — nothing re-pushes them. So a failed first push would silently absorb an
// identical terminal flush inside the window (Codex 2026-08-24, P1). Fork divergence from
// upstream, which has the same latent gap: `pushScrobbleToServer` rolls the key back via
// [clearEntry] on failure and retries once, re-resolving the key's freshest entry at retry time
// (`latestScrobbleForRetry`) — an absorbed flush was content-identical, so delivering the current
// state delivers the flush, while progress recorded during the delay is never regressed.
internal class RemoteProgressWriteDeduplicator(
    private val windowMs: Long = WATCH_PROGRESS_REMOTE_WRITE_DEDUP_WINDOW_MS,
) {
    private val lock = SynchronizedObject()
    private val recentWrites = mutableMapOf<RemoteProgressWriteKey, RemoteProgressWrite>()

    fun shouldSend(
        profileId: Int,
        entry: WatchProgressEntry,
        nowEpochMs: Long,
    ): Boolean = synchronized(lock) {
        recentWrites.entries.removeAll { (_, write) ->
            val elapsedMs = nowEpochMs - write.sentAtEpochMs
            elapsedMs < 0L || elapsedMs >= windowMs
        }
        val key = RemoteProgressWriteKey(
            profileId = profileId,
            progressKey = entry.resolvedProgressKey(),
        )
        val normalizedEntry = entry.copy(lastUpdatedEpochMs = 0L)
        val previous = recentWrites[key]
        if (previous?.entry == normalizedEntry) {
            return@synchronized false
        }
        recentWrites[key] = RemoteProgressWrite(
            entry = normalizedEntry,
            sentAtEpochMs = nowEpochMs,
        )
        true
    }

    // Roll back one key so an identical rewrite is no longer suppressed — the failure path of
    // an unacknowledged push (see the class comment).
    fun clearEntry(profileId: Int, progressKey: String) {
        synchronized(lock) {
            recentWrites.remove(RemoteProgressWriteKey(profileId = profileId, progressKey = progressKey))
        }
    }

    fun clear() {
        synchronized(lock) {
            recentWrites.clear()
        }
    }
}

object WatchProgressRepository {
    private val syncScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("WatchProgressRepository"))
    private val accountScopeLock = SynchronizedObject()
    private var accountScopeJob: Job = SupervisorJob()
    private var accountScope =
        CoroutineScope(accountScopeJob + Dispatchers.Default + uncaughtCoroutineLogger("WatchProgressRepository"))
    private val log = Logger.withTag("WatchProgressRepository")

    private val _uiState = MutableStateFlow(WatchProgressUiState())
    val uiState: StateFlow<WatchProgressUiState> = _uiState.asStateFlow()

    /**
     * BUG-76: every show the user has progress on, **deliberately NOT source-projected** — the
     * union of the local store and the active provider's snapshot.
     *
     * [uiState]'s entries answer "what should Continue Watching show?", so they are scoped to the
     * active watch-progress source and correctly go empty when that provider has no history.
     * Consumers that mean "which shows does this user follow?" must not inherit that scoping:
     * `UpcomingEpisodesRepository` seeds its air-date sweep from progress ∪ library, and while it
     * read [uiState] a Trakt→Simkl flip emptied half the seed and took the whole Upcoming row down
     * with it — a row that depends on the Library, not on the progress source.
     */
    private val _followedShows = MutableStateFlow<List<WatchProgressEntry>>(emptyList())
    val followedShows: StateFlow<List<WatchProgressEntry>> = _followedShows.asStateFlow()

    private var hasLoaded = false
    private var hasLoadedNuvioRemoteProgress = false
    private var currentProfileId: Int = 1
    private var profileGeneration: Long = 0L
    private var activeSource: WatchProgressSource = WatchProgressSource.NUVIO_SYNC
    private val _activeSourceState = MutableStateFlow(activeSource)
    // Fork: public (upstream: internal) — composeApp HomeScreen consumes this cross-module.
    val activeSourceState: StateFlow<WatchProgressSource> = _activeSourceState.asStateFlow()
    private val entriesLock = SynchronizedObject()
    private var entriesByProgressKey: MutableMap<String, WatchProgressEntry> = mutableMapOf()
    private var dirtyProgressKeys: MutableSet<String> = mutableSetOf()
    private var metadataResolutionJob: Job? = null
    private val metadataResolutionRetryCoordinator = MetadataResolutionRetryCoordinator()
    private val providerMetadataOverlay = ProviderProgressMetadataOverlay()
    private val nuvioPullMutex = Mutex()
    private var lastSuccessfulPushEpochMs = 0L
    private var deltaCursorEventId = 0L
    private var deltaInitialized = false
    private val remoteWriteDeduplicator = RemoteProgressWriteDeduplicator()
    internal var syncAdapter: ProgressSyncAdapter = SupabaseProgressSyncAdapter
    /** Profiles whose dirty-row backlog was already pushed (or tried) by this process (#2). */
    private val backlogPushLock = SynchronizedObject()
    private val backlogPushedProfileIds = mutableSetOf<Int>()
    /**
     * CW legacy diagnosis (REMAINING_FIX #1): playback writes whose profile was not the one loaded
     * here, or not the active one — the active one is then loaded first (`reload …`, #4), another
     * one is written to disk only (`disk …`). Shown as `xprof` by [continueWatchingDiagnosticLines].
     */
    private var crossProfileWriteCount = 0
    private var lastCrossProfileWrite = ""
    /**
     * CW alias fix (REMAINING_FIX #2): what the row's warm-up ([warmUpContinueWatchingSeriesIdentity])
     * may still look up in this profile load, and the job its lookups run under — both reset, and
     * the lookups cancelled, on every profile load and sign-out.
     */
    private val seriesIdentityWarmUp = SeriesIdentityWarmUpBudget()
    private val seriesIdentityWarmUpJobLock = SynchronizedObject()
    private var seriesIdentityWarmUpJob: Job = SupervisorJob()
    private val seriesIdentityWarmUpPermits = Semaphore(CONTINUE_WATCHING_SERIES_IDENTITY_WARM_UP_CONCURRENCY)
    /**
     * CW alias fix (review): progress keys removed here whose server delete has not completed yet,
     * by profile ([withoutPendingServerDeletes]). Guarded by [entriesLock], like the entries: a
     * removal marks its keys in the same step as it removes them, and a pull filters and replaces
     * in one step too.
     */
    private val pendingServerDeletes = mutableSetOf<Pair<Int, String>>()
    /** CW legacy #3: the server rows undated for being ahead of the clock, logged once each. */
    private val futureServerRowLock = SynchronizedObject()
    private val futureServerRowKeys = mutableSetOf<String>()

    init {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.progressProviders().forEach { provider ->
            syncScope.launch {
                provider.changes.collectLatest {
                    if (activeSource.providerId == provider.providerId) {
                        publish()
                        if (hasLoaded && !provider.providesCompleteMetadata) {
                            resolveRemoteMetadata()
                        }
                    } else {
                        // BUG-76: an inactive provider still feeds `followedShows`, so its
                        // changes matter here even though they must not touch `uiState` — most
                        // importantly a profile switch, which clears the outgoing profile's
                        // snapshot only after loadFromDisk() has already published.
                        publishFollowedShows()
                    }
                }
            }
        }

        // A connect/disconnect changes which snapshots `followedShows` may include, and it does
        // not necessarily emit through any provider's `changes`.
        syncScope.launch {
            TrackingProviderRegistry.connectedProviderIds.collectLatest {
                publishFollowedShows()
            }
        }

        syncScope.launch {
            AddonRepository.uiState.collectLatest { state ->
                retryMetadataResolutionWhenAddonMetaProvidersReady(state)
            }
        }

        // CW alias fix (REMAINING_FIX #2): a learned alias regroups the Continue Watching row
        // without touching a single entry, so the state is published again (it carries the
        // version, see WatchProgressUiState.seriesIdentityVersion).
        syncScope.launch {
            ContinueWatchingSeriesIdentity.version.collect {
                if (hasLoaded) publish()
            }
        }

    }

    fun ensureLoaded() {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.ensureLoaded()
        TrackingSettingsRepository.ensureLoaded()
        TrackingProviderRegistry.progressProviders().forEach(TrackingProgressProvider::ensureLoaded)
        if (!hasLoaded) {
            updateActiveSource(
                effectiveWatchProgressSource(
                    requestedSource = TrackingSettingsRepository.uiState.value.watchProgressSource,
                    isProviderAuthenticated = ::isProgressProviderAvailable,
                ),
            )
            loadFromDisk(ProfileRepository.activeProfileId)
        }
    }

    fun onProfileChanged(profileId: Int) {
        if (profileId == currentProfileId && hasLoaded) return
        // Fork: the tvOS/composeApp profile fan-out already calls TraktSettingsRepository
        // .onProfileChanged() as its own step, so the settings reload stays where it was.
        TrackingSettingsRepository.onProfileChanged()
        updateActiveSource(
            effectiveWatchProgressSource(
                requestedSource = TrackingSettingsRepository.uiState.value.watchProgressSource,
                isProviderAuthenticated = ::isProgressProviderAvailable,
            ),
        )
        loadFromDisk(profileId)
        TrackingProviderRegistry.progressProviders().forEach(TrackingProgressProvider::onProfileChanged)
    }

    fun clearLocalState() {
        val previousAccountJob = synchronized(accountScopeLock) {
            accountScopeJob.also {
                accountScopeJob = SupervisorJob()
                accountScope = CoroutineScope(
                    accountScopeJob + Dispatchers.Default + uncaughtCoroutineLogger("WatchProgressRepository"),
                )
            }
        }
        previousAccountJob.cancel()
        cancelMetadataResolution(resetProviderHistory = true)
        hasLoaded = false
        hasLoadedNuvioRemoteProgress = false
        currentProfileId = 1
        profileGeneration += 1L
        updateActiveSource(WatchProgressSource.NUVIO_SYNC)
        providerMetadataOverlay.clear()
        // Sign-out: the learned series ids and the Up Next outcomes go with the account.
        ContinueWatchingSeriesIdentity.clear()
        ContinueWatchingNextUp.clearResolutionOutcomes()
        resetSeriesIdentityWarmUp()
        clearLocalEntries()
        synchronized(entriesLock) { pendingServerDeletes.clear() }
        lastSuccessfulPushEpochMs = 0L
        deltaCursorEventId = 0L
        deltaInitialized = false
        remoteWriteDeduplicator.clear()
        crossProfileWriteCount = 0
        lastCrossProfileWrite = ""
        synchronized(futureServerRowLock) { futureServerRowKeys.clear() }
        // Another account's profiles reuse the same ids: they get their own backlog push.
        synchronized(backlogPushLock) { backlogPushedProfileIds.clear() }
        TrackingProviderRegistry.progressProviders().forEach(TrackingProgressProvider::clearLocalState)
        TrackingSettingsRepository.clearLocalState()
        _uiState.value = WatchProgressUiState()
    }

    private fun loadFromDisk(profileId: Int) {
        cancelMetadataResolution(resetProviderHistory = true)
        currentProfileId = profileId
        profileGeneration += 1L
        hasLoaded = true
        hasLoadedNuvioRemoteProgress = false
        providerMetadataOverlay.clear()
        // The learned series ids stay (CW alias fix, review): they describe metadata, not the
        // profile, and Home's Up Next cache — which taught some of them — is not reset by every
        // load. Only this load's warm-up starts over.
        resetSeriesIdentityWarmUp()
        clearLocalEntries()

        val payload = WatchProgressStorage.loadPayload(profileId).orEmpty().trim()
        if (payload.isNotEmpty()) {
            val storedPayload = WatchProgressCodec.decodePayload(payload)
            lastSuccessfulPushEpochMs = storedPayload.lastSuccessfulPushEpochMs
            deltaCursorEventId = storedPayload.deltaCursorEventId
            deltaInitialized = storedPayload.deltaInitialized
            replaceLocalEntries(storedPayload.entries)
            replaceDirtyProgressKeys(storedPayload.dirtyProgressKeys)
        } else {
            lastSuccessfulPushEpochMs = 0L
            deltaCursorEventId = 0L
            deltaInitialized = false
        }
        log.d {
            "Loaded watch progress for profile $profileId: entries=${localEntryCount()} " +
                "deltaInitialized=$deltaInitialized cursor=$deltaCursorEventId lastPush=$lastSuccessfulPushEpochMs"
        }
        publish()
        resolveRemoteMetadata()
    }

    /**
     * CW alias fix: a profile load or a sign-out gives the row's warm-up a new budget and cancels
     * the lookups still in flight — the ones that finish anyway are dropped ([SeriesIdentityWarmUpBudget.isCurrent]).
     */
    private fun resetSeriesIdentityWarmUp() {
        seriesIdentityWarmUp.reset()
        val previousJob = synchronized(seriesIdentityWarmUpJobLock) {
            seriesIdentityWarmUpJob.also { seriesIdentityWarmUpJob = SupervisorJob() }
        }
        previousJob.cancel()
    }

    private fun activeOperationGeneration(profileId: Int): Long? {
        if (ProfileRepository.activeProfileId != profileId) return null
        if (!hasLoaded || currentProfileId != profileId) {
            loadFromDisk(profileId)
        }
        return profileGeneration
    }

    private fun isActiveOperation(profileId: Int, generation: Long): Boolean =
        currentProfileId == profileId &&
            profileGeneration == generation &&
            ProfileRepository.activeProfileId == profileId

    private fun isActiveMetadataTarget(
        profileId: Int,
        generation: Long,
        source: WatchProgressSource,
    ): Boolean = isActiveOperation(profileId, generation) && activeSource == source

    suspend fun pullFromServer(profileId: Int) {
        refreshForSource(
            profileId = profileId,
            source = activeSource,
            sourceChanged = false,
            force = false,
        )
    }

    suspend fun forceSnapshotRefreshFromServer(profileId: Int) {
        refreshForSource(
            profileId = profileId,
            source = activeSource,
            sourceChanged = false,
            force = true,
        )
    }

    suspend fun selectWatchProgressSource(profileId: Int, source: WatchProgressSource) {
        WatchProgressSourceCoordinator.selectSource(profileId = profileId, source = source)
    }

    suspend fun clearLocalAndForceSnapshotRefreshFromServer(profileId: Int) {
        ContinueWatchingEnrichmentCache.clearAll(profileId)
        WatchProgressSourceCoordinator.refreshActiveSource(profileId = profileId, force = true)
    }

    internal fun activateSource(source: WatchProgressSource) {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.ensureLoaded()
        TrackingSettingsRepository.ensureLoaded()
        TrackingProviderRegistry.progressProviders().forEach(TrackingProgressProvider::ensureLoaded)
        if (!hasLoaded) {
            loadFromDisk(ProfileRepository.activeProfileId)
        }
        if (activeSource == source) {
            publish()
            return
        }

        updateActiveSource(source)
        cancelMetadataResolution(resetProviderHistory = false)
        providerMetadataOverlay.clear()
        activeProgressProvider()?.onActivated() ?: run { hasLoadedNuvioRemoteProgress = false }
        publish()
        if (activeProgressProvider()?.providesCompleteMetadata != true) {
            resolveRemoteMetadata()
        }
    }

    internal suspend fun refreshForSource(
        profileId: Int,
        source: WatchProgressSource,
        sourceChanged: Boolean,
        force: Boolean,
    ): Boolean {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.ensureLoaded(profileId)
        ensureLoaded()
        if (currentProfileId != profileId) {
            loadFromDisk(profileId)
        }
        val operationGeneration = activeOperationGeneration(profileId) ?: run {
            log.d { "Skipping watch progress refresh for inactive profile $profileId" }
            return false
        }

        activateSource(source)
        activeProgressProvider()?.let { provider ->
            return refreshProviderSource(
                provider = provider,
                profileId = profileId,
                operationGeneration = operationGeneration,
                sourceChanged = sourceChanged,
                force = force,
            )
        }
        return refreshNuvioSource(
            profileId = profileId,
            operationGeneration = operationGeneration,
            force = force,
        )
    }

    private suspend fun refreshProviderSource(
        provider: TrackingProgressProvider,
        profileId: Int,
        operationGeneration: Long,
        sourceChanged: Boolean,
        force: Boolean,
    ): Boolean {
        if (!isProgressProviderAvailable(provider.providerId)) {
            log.d { "Skipping ${provider.providerId.storageId} progress refresh because it is unavailable" }
            return false
        }

        return try {
            provider.refresh(force = force, sourceChanged = sourceChanged)
            if (
                isActiveOperation(profileId, operationGeneration) &&
                activeSource.providerId == provider.providerId
            ) {
                publish()
            }
            val state = provider.snapshot()
            state.hasLoadedRemoteProgress && state.errorMessage == null
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Failed to refresh ${provider.providerId.storageId} watch progress" }
            false
        }
    }

    private fun activeProgressProvider(): TrackingProgressProvider? =
        activeSource.providerId?.let(TrackingProviderRegistry::progressProvider)

    private fun isProgressProviderAvailable(providerId: TrackingProviderId): Boolean =
        TrackingProviderRegistry.progressProvider(providerId) != null &&
            TrackingProviderRegistry.isAuthenticated(providerId)

    private suspend fun removeProviderProgress(
        provider: TrackingProgressProvider,
        entries: Collection<WatchProgressEntry>,
        reason: String,
    ) {
        try {
            provider.removeProgress(entries)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Failed to $reason from ${provider.providerId.storageId}" }
        }
    }

    private suspend fun refreshNuvioSource(
        profileId: Int,
        operationGeneration: Long,
        force: Boolean,
    ): Boolean {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) {
            // There is no upstream source for this account, so local state is authoritative.
            hasLoadedNuvioRemoteProgress = true
            publish()
            return true
        }

        return nuvioPullMutex.withLock {
            try {
                if (force) {
                    pullNuvioSnapshotFromServer(
                        profileId = profileId,
                        operationGeneration = operationGeneration,
                    )
                } else {
                    pullSupabaseDeltaFromServer(
                        profileId = profileId,
                        operationGeneration = operationGeneration,
                    )
                }
                // Picks and pushes under the pull mutex, once this pull has released it.
                pushDirtyProgressBacklogOnce(
                    profileId = profileId,
                    operationGeneration = operationGeneration,
                )
                true
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.e(error) { "Failed to refresh Nuvio watch progress" }
                false
            }
        }
    }

    private suspend fun pullNuvioSnapshotFromServer(
        profileId: Int,
        operationGeneration: Long,
    ) {
        val cursorBeforeSnapshot = try {
            syncAdapter.getDeltaCursor(profileId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w { "Watch progress cursor unavailable during snapshot refresh: ${error.message}" }
            null
        }

        pullFullFromAdapter(
            profileId = profileId,
            resetDeltaState = cursorBeforeSnapshot == null,
            operationGeneration = operationGeneration,
            preserveLocalEntries = true,
        )
        if (!isActiveOperation(profileId, operationGeneration)) return

        if (cursorBeforeSnapshot != null) {
            deltaCursorEventId = cursorBeforeSnapshot
            deltaInitialized = true
            persist()
        }
    }

    private suspend fun pullSupabaseDeltaFromServer(
        profileId: Int,
        operationGeneration: Long,
    ) {
        if (!isActiveOperation(profileId, operationGeneration)) return
        log.d {
            "Watch progress delta sync start: profile=$profileId entries=${localEntryCount()} " +
                "deltaInitialized=$deltaInitialized cursor=$deltaCursorEventId lastPush=$lastSuccessfulPushEpochMs"
        }
        if (!deltaInitialized) {
            log.d { "Watch progress delta not initialized for profile $profileId; requesting cursor before snapshot" }
            val cursorBeforeSnapshot = try {
                syncAdapter.getDeltaCursor(profileId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.w { "Watch progress delta cursor unavailable, falling back to full pull: ${error.message}" }
                null
            }
            if (cursorBeforeSnapshot == null) {
                log.d { "Watch progress delta cursor unavailable for profile $profileId; using snapshot fallback" }
                pullFullFromAdapter(
                    profileId = profileId,
                    resetDeltaState = true,
                    operationGeneration = operationGeneration,
                )
                return
            }

            log.d { "Watch progress delta cursor before snapshot for profile $profileId is $cursorBeforeSnapshot" }
            pullFullFromAdapter(
                profileId = profileId,
                resetDeltaState = false,
                operationGeneration = operationGeneration,
            )
            if (!isActiveOperation(profileId, operationGeneration)) return
            deltaCursorEventId = cursorBeforeSnapshot
            deltaInitialized = true
            persist()
            log.d {
                "Watch progress delta initialized for profile $profileId: cursor=$deltaCursorEventId " +
                    "entries=${localEntryCount()}"
            }
            return
        }

        var cursor = deltaCursorEventId
        var changed = false
        var totalUpserts = 0
        var totalDeletes = 0
        var preservedLocalItems = false
        var withdrawnDirtyKeys = 0
        var cursorAdvanced = false
        var page = 1
        // A local row written from here on is an update this pull's deletes cannot know about.
        val pullStartedAtEpochMs = WatchProgressClock.nowEpochMs()

        while (true) {
            log.d { "Pulling watch progress delta page $page for profile $profileId from cursor $cursor" }
            val events = try {
                syncAdapter.pullDelta(
                    profileId = profileId,
                    sinceEventId = cursor,
                    limit = WATCH_PROGRESS_DELTA_PAGE_SIZE,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.w { "Watch progress delta pull unavailable, falling back to full pull: ${error.message}" }
                pullFullFromAdapter(
                    profileId = profileId,
                    resetDeltaState = true,
                    operationGeneration = operationGeneration,
                )
                return
            }
            if (!isActiveOperation(profileId, operationGeneration)) return
            if (events.isEmpty()) {
                log.d { "Watch progress delta page $page returned no events for profile $profileId at cursor $cursor" }
                break
            }

            val firstEvent = events.firstOrNull()?.eventId
            val lastEvent = events.lastOrNull()?.eventId
            val eventUpserts = events.count { it.operation.equals(WATCH_PROGRESS_DELTA_OPERATION_UPSERT, ignoreCase = true) }
            val eventDeletes = events.count { it.operation.equals(WATCH_PROGRESS_DELTA_OPERATION_DELETE, ignoreCase = true) }
            log.d {
                "Watch progress delta page $page fetched ${events.size} events for profile $profileId " +
                    "first=$firstEvent last=$lastEvent upserts=$eventUpserts deletes=$eventDeletes"
            }

            val pageResult = applyWatchProgressDeltaEvents(
                events = events,
                withdrawWrittenBeforeEpochMs = pullStartedAtEpochMs,
            )
            changed = pageResult.changed || changed
            totalUpserts += pageResult.appliedUpserts
            totalDeletes += pageResult.appliedDeletes
            preservedLocalItems = preservedLocalItems || pageResult.preservedLocalItems
            withdrawnDirtyKeys += pageResult.withdrawnDirtyKeys
            val previousCursor = cursor
            cursor = maxOf(cursor, events.maxOf { it.eventId })
            cursorAdvanced = cursorAdvanced || cursor > previousCursor
            deltaCursorEventId = cursor
            deltaInitialized = true
            log.d {
                "Watch progress delta page $page applied for profile $profileId: " +
                    "appliedUpserts=${pageResult.appliedUpserts} appliedDeletes=${pageResult.appliedDeletes} " +
                    "preservedLocal=${pageResult.preservedLocalItems} withdrawnDirty=${pageResult.withdrawnDirtyKeys} " +
                    "newCursor=$cursor"
            }

            if (events.size < WATCH_PROGRESS_DELTA_PAGE_SIZE) break
            page += 1
        }

        hasLoaded = true
        val remoteReadinessChanged = !hasLoadedNuvioRemoteProgress
        hasLoadedNuvioRemoteProgress = true
        if (changed || remoteReadinessChanged) {
            publish()
        }
        if (changed || cursorAdvanced || withdrawnDirtyKeys > 0) {
            persist()
        }
        if (changed) {
            resolveRemoteMetadata()
        }
        if (withdrawnDirtyKeys > 0) {
            log.i {
                "Watch progress delta for profile $profileId: $withdrawnDirtyKeys unsynced row(s) older than " +
                    "a delete from another device are no longer pushed"
            }
        }
        log.d {
            "Watch progress delta sync finished for profile $profileId: changed=$changed " +
                "appliedUpserts=$totalUpserts appliedDeletes=$totalDeletes preservedLocal=$preservedLocalItems " +
                "cursor=$deltaCursorEventId entries=${localEntryCount()}"
        }
    }

    private suspend fun pullFullFromAdapter(
        profileId: Int,
        resetDeltaState: Boolean,
        operationGeneration: Long,
        preserveLocalEntries: Boolean = true,
    ) {
        val serverEntries = syncAdapter.pull(profileId = profileId)
        if (!isActiveOperation(profileId, operationGeneration)) return
        log.d {
            "Watch progress snapshot fetched ${serverEntries.size} entries for profile $profileId " +
                "resetDeltaState=$resetDeltaState preserveLocalEntries=$preserveLocalEntries"
        }
        val localBeforePull = localEntriesSnapshot()
        val reconciliation = reconcileLocalProgressKeysWithSnapshot(
            serverEntries = serverEntries,
            localEntries = localBeforePull,
        )
        migrateDirtyProgressKeys(reconciliation.migratedKeys)
        val dirtyBeforeApply = dirtyProgressKeysSnapshot()
        val updatedEntries = if (preserveLocalEntries) {
            mergeWatchProgressEntriesPreservingUnsynced(
                serverEntries = serverEntries,
                localEntries = reconciliation.entries,
                dirtyProgressKeys = dirtyBeforeApply,
            )
        } else {
            val newestRemoteByKey = linkedMapOf<String, WatchProgressEntry>()
            serverEntries.forEach { record ->
                val key = record.resolvedProgressKey()
                val candidate = record.toWatchProgressEntry(cached = null)
                val existing = newestRemoteByKey[key]
                if (existing == null || candidate.isFresherThan(existing)) {
                    newestRemoteByKey[key] = candidate
                }
            }
            newestRemoteByKey
        }
        replaceLocalEntriesFromServer(entries = updatedEntries.values, profileId = profileId)
        acknowledgeDirtyProgressFromSnapshot(
            serverEntries = serverEntries,
            localEntriesBeforeApply = reconciliation.entries,
            dirtyKeysBeforeApply = dirtyBeforeApply,
        )
        if (resetDeltaState) {
            deltaCursorEventId = 0L
            deltaInitialized = false
        }
        hasLoaded = true
        hasLoadedNuvioRemoteProgress = true
        publish()
        persist()
        resolveRemoteMetadata()
        log.d {
            "Watch progress snapshot applied for profile $profileId: entries=${localEntryCount()} " +
                "deltaInitialized=$deltaInitialized cursor=$deltaCursorEventId"
        }
    }

    /**
     * [withdrawWrittenBeforeEpochMs]: the start of the pull. The dirty rows older than it that the
     * page's deletes supersede are withdrawn from sync ([dirtyProgressKeysWithdrawnByServerDeletes]).
     */
    private fun applyWatchProgressDeltaEvents(
        events: Collection<ProgressDeltaEvent>,
        withdrawWrittenBeforeEpochMs: Long,
    ): WatchProgressDeltaApplyResult {
        var changed = false
        var appliedUpserts = 0
        var appliedDeletes = 0
        var preservedLocalItems = false
        val latestEventByProgressKey = linkedMapOf<String, ProgressDeltaEvent>()
        // Every delete of the page, even one a later upsert of the same key supersedes: each is
        // activity on the show on another device.
        val deletedProgressKeys = mutableSetOf<String>()
        val deletedContentIds = mutableSetOf<String>()
        events.sortedBy(ProgressDeltaEvent::eventId).forEach { event ->
            val progressKey = event.resolvedProgressKey()
            if (progressKey.isBlank()) {
                return@forEach
            }
            when (event.operation.lowercase()) {
                WATCH_PROGRESS_DELTA_OPERATION_DELETE -> {
                    latestEventByProgressKey[progressKey] = event
                    deletedProgressKeys += progressKey
                    event.contentId.trim()
                        .ifEmpty { localEntry(progressKey)?.parentMetaId?.trim().orEmpty() }
                        .takeIf(String::isNotEmpty)
                        ?.let(deletedContentIds::add)
                }
                WATCH_PROGRESS_DELTA_OPERATION_UPSERT -> {
                    if (event.videoId.isNotBlank()) {
                        latestEventByProgressKey[progressKey] = event
                    }
                }
                else -> Unit
            }
        }

        latestEventByProgressKey.forEach { (progressKey, event) ->
            val current = localEntry(progressKey)
            val decision = decideWatchProgressDeltaEvent(
                current = current,
                event = event,
                isLocalDirty = progressKey in dirtyProgressKeysSnapshot(),
            )
            when (decision.type) {
                WatchProgressDeltaDecisionType.UPSERT -> {
                    if (upsertLocalEntryFromServer(requireNotNull(decision.updatedEntry))) {
                        changed = true
                        appliedUpserts += 1
                    }
                }
                WatchProgressDeltaDecisionType.DELETE -> {
                    if (removeLocalEntry(progressKey) != null) {
                        changed = true
                        appliedDeletes += 1
                    }
                }
                WatchProgressDeltaDecisionType.PRESERVE_LOCAL -> {
                    preservedLocalItems = true
                }
                WatchProgressDeltaDecisionType.IGNORE -> Unit
            }
            if (decision.clearsDirtyProgress) {
                clearProgressDirty(progressKey)
            }
        }
        val withdrawnKeys = if (deletedProgressKeys.isEmpty()) {
            emptySet()
        } else {
            dirtyProgressKeysWithdrawnByServerDeletes(
                entries = localEntriesSnapshot(),
                dirtyProgressKeys = dirtyProgressKeysSnapshot(),
                deletedProgressKeys = deletedProgressKeys,
                deletedContentIds = deletedContentIds,
                writtenBeforeEpochMs = withdrawWrittenBeforeEpochMs,
            )
        }
        withdrawnKeys.forEach(::clearProgressDirty)
        return WatchProgressDeltaApplyResult(
            appliedUpserts = appliedUpserts,
            appliedDeletes = appliedDeletes,
            preservedLocalItems = preservedLocalItems,
            changed = changed,
            withdrawnDirtyKeys = withdrawnKeys.size,
        )
    }

    fun decideWatchProgressDeltaEvent(
        current: WatchProgressEntry?,
        event: ProgressDeltaEvent,
        isLocalDirty: Boolean,
    ): WatchProgressDeltaDecision = when (event.operation.lowercase()) {
        WATCH_PROGRESS_DELTA_OPERATION_UPSERT -> {
            if (event.videoId.isBlank()) {
                WatchProgressDeltaDecision(WatchProgressDeltaDecisionType.IGNORE)
            } else {
                val updated = event.toProgressSyncRecord().toWatchProgressEntry(cached = current)
                when {
                    current == null ->
                        WatchProgressDeltaDecision(
                            type = WatchProgressDeltaDecisionType.UPSERT,
                            updatedEntry = updated,
                            clearsDirtyProgress = true,
                        )
                    isLocalDirty && current.isFresherThan(updated) ->
                        WatchProgressDeltaDecision(WatchProgressDeltaDecisionType.PRESERVE_LOCAL)
                    current == updated ->
                        WatchProgressDeltaDecision(
                            type = WatchProgressDeltaDecisionType.IGNORE,
                            clearsDirtyProgress = true,
                        )
                    else -> WatchProgressDeltaDecision(
                        type = WatchProgressDeltaDecisionType.UPSERT,
                        updatedEntry = updated,
                        clearsDirtyProgress = true,
                    )
                }
            }
        }
        WATCH_PROGRESS_DELTA_OPERATION_DELETE -> when {
            current == null -> WatchProgressDeltaDecision(WatchProgressDeltaDecisionType.IGNORE)
            isLocalDirty -> WatchProgressDeltaDecision(WatchProgressDeltaDecisionType.PRESERVE_LOCAL)
            else -> WatchProgressDeltaDecision(
                type = WatchProgressDeltaDecisionType.DELETE,
                clearsDirtyProgress = true,
            )
        }
        else -> WatchProgressDeltaDecision(WatchProgressDeltaDecisionType.IGNORE)
    }

    /**
     * The one converter from a server row: the snapshot merge, the delta decision and the
     * acknowledgement all go through it, so a row dated in the future is undated for all three
     * ([serverLastWatchedForLocalUse], CW legacy #3).
     */
    private fun ProgressSyncRecord.toWatchProgressEntry(cached: WatchProgressEntry?): WatchProgressEntry {
        val progressKey = resolvedProgressKey()
        val nowEpochMs = WatchProgressClock.nowEpochMs()
        val lastUpdatedEpochMs = serverLastWatchedForLocalUse(lastWatched = lastWatched, nowEpochMs = nowEpochMs)
        if (lastUpdatedEpochMs != lastWatched) {
            noteFutureServerRow(progressKey = progressKey, aheadMs = lastWatched - nowEpochMs)
        }
        return WatchProgressEntry(
            contentType = contentType,
            parentMetaId = contentId,
            parentMetaType = cached?.parentMetaType ?: contentType,
            videoId = videoId,
            title = cached?.title?.takeIf { it.isNotBlank() } ?: contentId,
            logo = cached?.logo,
            poster = cached?.poster,
            background = cached?.background,
            seasonNumber = season,
            episodeNumber = episode,
            episodeTitle = cached?.episodeTitle,
            episodeThumbnail = cached?.episodeThumbnail,
            lastPositionMs = position,
            durationMs = duration,
            lastUpdatedEpochMs = lastUpdatedEpochMs,
            providerName = cached?.providerName,
            providerAddonId = cached?.providerAddonId,
            lastStreamTitle = cached?.lastStreamTitle,
            lastStreamSubtitle = cached?.lastStreamSubtitle,
            pauseDescription = cached?.pauseDescription,
            lastSourceUrl = cached?.lastSourceUrl,
            isCompleted = isWatchProgressComplete(position, duration, false),
            progressKey = progressKey,
        )
    }

    /** Logs a future-dated server row once per key, and counts it for the diagnostics (`fut=`). */
    private fun noteFutureServerRow(progressKey: String, aheadMs: Long) {
        val count = synchronized(futureServerRowLock) {
            if (futureServerRowKeys.add(progressKey)) futureServerRowKeys.size else 0
        }
        if (count == 0) return
        log.w {
            "Server watch progress $progressKey is dated ${aheadMs / 60_000L} min ahead of this device; " +
                "it counts as undated here"
        }
        if (count == WATCH_PROGRESS_FUTURE_ROWS_CLOCK_WARNING) {
            log.w {
                "$count server watch progress rows are dated ahead of this device: its clock is probably " +
                    "behind, and the rows the other devices wrote lately count as undated here"
            }
        }
    }

    private fun futureServerRowCount(): Int = synchronized(futureServerRowLock) { futureServerRowKeys.size }

    private fun ProgressDeltaEvent.toProgressSyncRecord(): ProgressSyncRecord =
        ProgressSyncRecord(
            progressKey = progressKey,
            contentId = contentId,
            contentType = contentType,
            videoId = videoId,
            season = season,
            episode = episode,
            position = position,
            duration = duration,
            lastWatched = lastWatched,
        )

    fun mergeWatchProgressEntriesPreservingUnsynced(
        serverEntries: Collection<ProgressSyncRecord>,
        localEntries: Collection<WatchProgressEntry>,
        dirtyProgressKeys: Set<String>,
    ): Map<String, WatchProgressEntry> {
        val reconciliation = reconcileLocalProgressKeysWithSnapshot(
            serverEntries = serverEntries,
            localEntries = localEntries,
        )
        val effectiveDirtyKeys = dirtyProgressKeys.mapTo(mutableSetOf()) { key ->
            reconciliation.migratedKeys[key] ?: key
        }
        val localByProgressKey = reconciliation.entries.newestByProgressKey()
        val merged = linkedMapOf<String, WatchProgressEntry>()
        serverEntries.forEach { record ->
            val progressKey = record.resolvedProgressKey()
            val candidate = record.toWatchProgressEntry(cached = localByProgressKey[progressKey])
            val existing = merged[progressKey]
            if (existing == null || candidate.isFresherThan(existing)) {
                merged[progressKey] = candidate
            }
        }

        localByProgressKey.forEach { (progressKey, localEntry) ->
            val remoteEntry = merged[progressKey]
            if (progressKey !in effectiveDirtyKeys) return@forEach
            if (remoteEntry == null || localEntry.isFresherThan(remoteEntry)) {
                merged[progressKey] = localEntry
            }
        }

        return merged
    }

    private fun retryMetadataResolutionWhenAddonMetaProvidersReady(state: AddonsUiState) {
        if (!hasLoaded || activeProgressProvider()?.providesCompleteMetadata == true) return

        val readiness = state.metadataProviderReadiness()
        if (!readiness.isReady) return

        val fingerprint = readiness.fingerprint
        if (!metadataResolutionRetryCoordinator.requestForProviders(fingerprint)) return
        resolveRemoteMetadata()
    }

    private fun cancelMetadataResolution(resetProviderHistory: Boolean) {
        if (resetProviderHistory) {
            metadataResolutionRetryCoordinator.reset()
        } else {
            metadataResolutionRetryCoordinator.invalidateActiveResolution()
        }
        metadataResolutionJob?.cancel()
        metadataResolutionJob = null
    }

    private fun resolveRemoteMetadata() {
        // This prefix runs on the CALLER'S thread — during profile selection that is the Swift
        // main thread, where an escaped Kotlin exception aborts at the KMP boundary. Metadata
        // enrichment is best-effort, so degrade to a log instead (tester crash-loop 2026-07-21:
        // account-add pull → persisted entries needing enrichment → crash on every profile select).
        try {
            resolveRemoteMetadataUnsafe()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Failed to start remote metadata resolution" }
        }
    }

    private fun resolveRemoteMetadataUnsafe() {
        val targetProfileId = currentProfileId
        val targetGeneration = profileGeneration
        val targetSource = activeSource
        val targetProvider = activeProgressProvider()
        // Fork: a provider that already ships display-ready metadata (Trakt) must not pull the
        // whole continue-watching list through MetaDetailsRepository on every profile load — that
        // is network the shipped build never issued. Only rows the provider cannot represent
        // (`kitsu:`, `mal:`, …), which come from local storage, stay in the candidate set.
        val displayReadyProvider = targetProvider
            ?.takeIf(TrackingProgressProvider::providesCompleteMetadata)
        val missingMetadataEntries = currentEntries()
            .filter(WatchProgressEntry::needsRemoteMetadataEnrichment)
            .filter { entry ->
                displayReadyProvider?.canRepresentContentId(entry.parentMetaId) != true
            }
        val entriesToResolve = missingMetadataEntries.continueWatchingEntries(
            limit = WATCH_PROGRESS_METADATA_RESOLUTION_LIMIT,
        )
        val needsResolution = entriesToResolve
            .groupBy(WatchProgressEntry::metadataKey)

        if (needsResolution.isEmpty()) return

        val providersAtStart = AddonRepository.uiState.value.metadataProviderReadiness()
        val resolutionGeneration = metadataResolutionRetryCoordinator.beginResolution(
            providerFingerprint = providersAtStart.fingerprint.takeIf { providersAtStart.isReady },
        )
        metadataResolutionJob?.cancel()
        metadataResolutionJob = syncScope.launch(start = CoroutineStart.LAZY) {
            try {
                if (!isActiveMetadataTarget(targetProfileId, targetGeneration, targetSource)) return@launch
                AddonRepository.initialize()
                val providerReadiness = AddonRepository.uiState.value.metadataProviderReadiness()
                if (providerReadiness.isReady) {
                    metadataResolutionRetryCoordinator.providersObservedBeforeFetch(
                        resolutionGeneration = resolutionGeneration,
                        providerFingerprint = providerReadiness.fingerprint,
                    )
                }
                val semaphore = Semaphore(WATCH_PROGRESS_METADATA_RESOLUTION_CONCURRENCY)
                val resolutionResults = Channel<RemoteMetadataResolutionResult>(Channel.UNLIMITED)
                needsResolution.forEach { (key, entries) ->
                    launch {
                        val result = semaphore.withPermit {
                            fetchRemoteMetadataGroup(key = key, entries = entries)
                        }
                        resolutionResults.send(result)
                    }
                }

                var resolvedEntries = 0
                var persistedEntries = 0
                repeat(needsResolution.size) {
                    val result = resolutionResults.receive()
                    ensureActive()
                    if (!isActiveMetadataTarget(targetProfileId, targetGeneration, targetSource)) return@launch
                    val meta = result.meta
                    if (meta == null) {
                        return@repeat
                    }
                    // CW alias fix: the series meta names the IMDb id these rows are grouped under.
                    ContinueWatchingSeriesIdentity.record(requestedId = result.key.metaId, meta = meta)

                    // Rows backed by local storage keep the shipped path: enrich in place and
                    // persist. Rows that exist only inside a provider projection are read-only, so
                    // their metadata lands in the overlay and is re-applied on every read instead.
                    var appliedLocalEntries = 0
                    var providerOwnedEntries = 0
                    for (entry in result.entries) {
                        val current = localEntry(entry.resolvedProgressKey())
                        if (current == null) {
                            providerOwnedEntries += 1
                            continue
                        }
                        val enriched = enrichWatchProgressEntry(current = current, meta = meta)
                        if (enriched == current) continue
                        upsertLocalEntry(enriched)
                        appliedLocalEntries += 1
                    }
                    var appliedEntries = appliedLocalEntries
                    if (
                        targetSource.providerId != null &&
                        providerOwnedEntries > 0 &&
                        providerMetadataOverlay.put(targetSource, result.key, meta)
                    ) {
                        appliedEntries += providerOwnedEntries
                    }
                    if (appliedEntries == 0) return@repeat

                    resolvedEntries += appliedEntries
                    persistedEntries += appliedLocalEntries

                    if (isActiveMetadataTarget(targetProfileId, targetGeneration, targetSource)) {
                        publish()
                    }
                }
                resolutionResults.close()
                if (
                    persistedEntries > 0 &&
                    isActiveMetadataTarget(targetProfileId, targetGeneration, targetSource)
                ) {
                    persist()
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                // Escaping here would reach the scope's uncaught handler; enrichment is
                // best-effort, so log and let the retry coordinator decide in `finally`.
                log.e(error) { "Remote metadata resolution failed" }
            } finally {
                runCatching {
                    val currentReadiness = AddonRepository.uiState.value.metadataProviderReadiness()
                    val shouldRetry = metadataResolutionRetryCoordinator.finishResolution(
                        resolutionGeneration = resolutionGeneration,
                        currentProviderFingerprint = currentReadiness.fingerprint.takeIf { currentReadiness.isReady },
                    )
                    if (shouldRetry && hasLoaded && activeProgressProvider()?.providesCompleteMetadata != true) {
                        resolveRemoteMetadata()
                    }
                }.onFailure { error ->
                    if (error is CancellationException) return@onFailure
                    log.e(error) { "Remote metadata resolution retry bookkeeping failed" }
                }
            }
        }
        metadataResolutionJob?.start()
    }

    private suspend fun fetchRemoteMetadataGroup(
        key: WatchProgressMetadataKey,
        entries: List<WatchProgressEntry>,
    ): RemoteMetadataResolutionResult {
        var meta: MetaDetails? = null
        for (attempt in 1..WATCH_PROGRESS_METADATA_FETCH_ATTEMPTS) {
            if (attempt > 1) {
                val retryDelayMs = WATCH_PROGRESS_METADATA_RETRY_BASE_DELAY_MS *
                    (1L shl (attempt - 2))
                delay(retryDelayMs)
            }
            meta = try {
                MetaDetailsRepository.fetch(key.metaType, key.metaId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                null
            }
            if (meta != null) break
        }
        return RemoteMetadataResolutionResult(
            key = key,
            entries = entries,
            meta = meta,
        )
    }

    fun upsertPlaybackProgress(
        session: WatchProgressPlaybackSession,
        snapshot: PlayerPlaybackSnapshot,
        syncRemote: Boolean = true,
    ) {
        ensureLoaded()
        upsert(session = session, snapshot = snapshot, persist = true, syncRemote = syncRemote)
    }

    fun flushPlaybackProgress(
        session: WatchProgressPlaybackSession,
        snapshot: PlayerPlaybackSnapshot,
        syncRemote: Boolean = true,
    ) {
        ensureLoaded()
        upsert(session = session, snapshot = snapshot, persist = true, syncRemote = syncRemote)
    }

    fun clearProgress(videoId: String, parentMetaId: String? = null) {
        clearProgress(videoIds = listOf(videoId), parentMetaId = parentMetaId)
    }

    fun clearProgress(
        videoIds: Collection<String>,
        parentMetaId: String? = null,
    ) {
        ensureLoaded()
        if (videoIds.isEmpty()) return

        activeProgressProvider()?.let { provider ->
            val entriesToRemove = currentEntries().filter { entry ->
                entry.videoId in videoIds &&
                    (parentMetaId == null || entry.parentMetaId == parentMetaId)
            }
            val locallyRemovedEntries = removeStoredLocalEntries(entriesToRemove)
            if (parentMetaId == null) {
                provider.applyOptimisticRemovalByVideoIds(videoIds)
            } else {
                provider.applyOptimisticRemoval(entriesToRemove)
            }
            if (locallyRemovedEntries.isNotEmpty()) persist()
            publish()
            if (entriesToRemove.isNotEmpty()) {
                syncScope.launch {
                    removeProviderProgress(provider, entriesToRemove, "clear playback progress")
                }
            }
            return
        }

        val removedEntries = removeLocalEntriesForVideoIds(
            videoIds = videoIds,
            parentMetaId = parentMetaId,
            pendingDeleteProfileId = currentProfileId.takeIf { activeSource.providerId == null },
        )
        if (removedEntries.isNotEmpty()) {
            publish()
            persist()
            pushDeleteToServer(removedEntries)
        }
    }

    fun removeProgress(
        contentId: String,
        seasonNumber: Int? = null,
        episodeNumber: Int? = null,
    ) {
        ensureLoaded()
        val normalizedContentId = contentId.trim()
        if (normalizedContentId.isBlank()) return

        val entriesToRemove = currentEntries().filter { entry ->
            if (entry.parentMetaId != normalizedContentId) {
                false
            } else if (seasonNumber != null && episodeNumber != null) {
                entry.seasonNumber == seasonNumber && entry.episodeNumber == episodeNumber
            } else {
                true
            }
        }
        removeProgressEntries(entriesToRemove)
    }

    /**
     * CW alias fix (REMAINING_FIX #2): every stored id a Continue Watching card stands for — the
     * card's own, then, for a series, its other ids ([ContinueWatchingSeriesIdentity]): the ids
     * "Remove from Continue Watching" passes to [removeContinueWatchingProgress].
     *
     * Called from the Swift main thread, so it never throws (it falls back to the card's own id).
     */
    fun continueWatchingCardContentIds(card: WatchProgressEntry): List<String> = try {
        ensureLoaded()
        continueWatchingSeriesContentIds(
            entries = currentEntries(),
            card = card,
            canonicalSeriesId = ContinueWatchingSeriesIdentity::canonical,
            isConfirmedAlias = ContinueWatchingSeriesIdentity::isConfirmed,
            onAliasLeftOut = { alias ->
                log.i {
                    "Remove from Continue Watching keeps $alias with ${card.parentMetaId}: only an add-on's " +
                        "imdb_id groups them, and their titles differ"
                }
            },
        )
    } catch (error: Throwable) {
        log.e(error) { "Failed to list the ids of the Continue Watching card ${card.parentMetaId}" }
        listOf(card.parentMetaId.trim()).filter(String::isNotEmpty)
    }

    /**
     * CW alias fix (REMAINING_FIX #2): removes every progress row of [contentIds] (all the ids of
     * one series, [continueWatchingCardContentIds]) in one go — one publish, and with Nuvio Sync one
     * delete on the account covering every alias row, the ones the post-pull backlog push may have
     * sent there included. The same removal as [removeProgress] for a whole title otherwise.
     *
     * Called from the Swift main thread, so it never throws.
     */
    fun removeContinueWatchingProgress(contentIds: List<String>) {
        try {
            ensureLoaded()
            val ids = contentIds.map(String::trim).filterTo(mutableSetOf(), String::isNotEmpty)
            if (ids.isEmpty()) return
            removeProgressEntries(currentEntries().filter { entry -> entry.parentMetaId.trim() in ids })
        } catch (error: Throwable) {
            log.e(error) { "Failed to remove Continue Watching progress for $contentIds" }
        }
    }

    private fun removeProgressEntries(entriesToRemove: List<WatchProgressEntry>) {
        if (entriesToRemove.isEmpty()) return

        activeProgressProvider()?.let { provider ->
            val locallyRemovedEntries = removeStoredLocalEntries(entriesToRemove)
            provider.applyOptimisticRemoval(entriesToRemove)
            if (locallyRemovedEntries.isNotEmpty()) persist()
            publish()
            syncScope.launch {
                removeProviderProgress(provider, entriesToRemove, "remove playback progress")
            }
            return
        }

        removeLocalEntriesForServerDelete(
            progressKeys = entriesToRemove.map(WatchProgressEntry::resolvedProgressKey),
            pendingDeleteProfileId = currentProfileId.takeIf { activeSource.providerId == null },
        )
        publish()
        persist()
        pushDeleteToServer(entriesToRemove)
    }

    fun progressForVideo(
        videoId: String,
        parentMetaId: String? = null,
        seasonNumber: Int? = null,
        episodeNumber: Int? = null,
    ): WatchProgressEntry? {
        ensureLoaded()
        return currentEntries().resolveProgressForVideo(
            videoId = videoId,
            parentMetaId = parentMetaId,
            seasonNumber = seasonNumber,
            episodeNumber = episodeNumber,
        )
    }

    fun resumeEntryForSeries(metaId: String): WatchProgressEntry? {
        ensureLoaded()
        return currentEntries().resumeEntryForSeries(metaId)
    }

    /**
     * Legacy 20-item row, deliberately retained with no callers as the rollback path for
     * [continueWatchingRow] (BUG-75's product decision) — remove once the provider-aware row
     * has survived a release in the wild.
     */
    fun continueWatching(): List<WatchProgressEntry> {
        ensureLoaded()
        return currentEntries().continueWatchingEntries()
    }

    /**
     * Provider-aware Continue Watching row. [continueWatching] stays as the unfiltered legacy path.
     */
    fun continueWatchingRow(limit: Int = ContinueWatchingRowScanLimit): List<WatchProgressEntry> {
        ensureLoaded()
        TraktSettingsRepository.ensureLoaded()
        val cutoffEpochMs = activeProviderContinueWatchingCutoffEpochMs(
            daysCap = TraktSettingsRepository.uiState.value.continueWatchingDaysCap,
            nowEpochMs = WatchProgressClock.nowEpochMs(),
        )
        val row = buildContinueWatchingRowEntries(
            entries = currentEntries(),
            isDroppedShow = ::isDroppedShow,
            recencyCutoffEpochMs = cutoffEpochMs,
            limit = limit,
        )
        warmUpContinueWatchingSeriesIdentity(row)
        return row
    }

    /**
     * CW alias fix (REMAINING_FIX #2): looks up, in the background, the IMDb id of the row's series
     * cards stored under a `tmdb:` id ([selectSeriesIdentityWarmUpKeys]), so the row can group them
     * with their `tt` rows. Rows whose metadata is complete are never enriched, so nothing else
     * would ever fetch their series. [MetaDetailsRepository]'s cache first; a learned id
     * republishes the state (see the collector in `init`), and the next build shows one card.
     *
     * The row is rebuilt on every playback tick and publish, so what one profile load may look up
     * is bounded by [SeriesIdentityWarmUpBudget] (review): at most
     * [ContinueWatchingSeriesIdentityWarmUpLimit] series, most recent first, and a lookup that
     * fetched nothing is tried again a few minutes later, a few times. The lookups run under
     * [seriesIdentityWarmUpJob], which a profile load or a sign-out cancels.
     *
     * Like the metadata enrichment, it leaves out the rows a display-ready provider (Trakt) can
     * represent: that is network the shipped build never issued. Runs on the Swift main thread's
     * call to [continueWatchingRow], so it never throws.
     */
    private fun warmUpContinueWatchingSeriesIdentity(rowEntries: List<WatchProgressEntry>) {
        try {
            val displayReadyProvider = activeProgressProvider()
                ?.takeIf(TrackingProgressProvider::providesCompleteMetadata)
            val candidates = selectSeriesIdentityWarmUpKeys(
                rowEntries = rowEntries.filter { entry ->
                    displayReadyProvider?.canRepresentContentId(entry.parentMetaId) != true
                },
                isResolved = ContinueWatchingSeriesIdentity::isResolved,
            )
            if (candidates.isEmpty()) return
            val claim = seriesIdentityWarmUp.claim(
                candidates = candidates.map(WatchProgressMetadataKey::metaId),
                nowEpochMs = WatchProgressClock.nowEpochMs(),
            )
            if (claim.ids.isEmpty()) return
            val claimedIds = claim.ids.toSet()
            val job = synchronized(seriesIdentityWarmUpJobLock) { seriesIdentityWarmUpJob }
            candidates
                .filter { key -> key.metaId.trim() in claimedIds }
                .distinctBy { key -> key.metaId.trim() }
                .forEach { key ->
                    syncScope.launch(job) {
                        seriesIdentityWarmUpPermits.withPermit {
                            if (!seriesIdentityWarmUp.isCurrent(claim.generation)) return@withPermit
                            val meta = try {
                                MetaDetailsRepository.fetch(type = key.metaType, id = key.metaId)
                            } catch (error: CancellationException) {
                                throw error
                            } catch (error: Throwable) {
                                null
                            }
                            // A profile loaded meanwhile: this lookup belongs to the previous one.
                            if (!seriesIdentityWarmUp.isCurrent(claim.generation)) return@withPermit
                            if (meta != null) {
                                ContinueWatchingSeriesIdentity.record(requestedId = key.metaId, meta = meta)
                            }
                            seriesIdentityWarmUp.finish(
                                generation = claim.generation,
                                id = key.metaId,
                                fetched = meta != null,
                                nowEpochMs = WatchProgressClock.nowEpochMs(),
                            )
                        }
                    }
                }
        } catch (error: Throwable) {
            log.w { "Continue Watching series id warm-up skipped: ${error.message}" }
        }
    }

    /**
     * CW legacy diagnosis (REMAINING_FIX #1): the Continue Watching report of Settings > About
     * ([buildContinueWatchingDiagnosticLines]), taken now: the in-progress cards Home shows, the
     * series of its Up Next cards and the rows behind them.
     *
     * Called from the Swift main thread, so it never throws: a failure becomes the report's only line.
     */
    fun continueWatchingDiagnosticLines(): List<String> = try {
        ensureLoaded()
        val nowEpochMs = WatchProgressClock.nowEpochMs()
        val localEntries = localEntriesSnapshot()
        val dirtyKeys = dirtyProgressKeysSnapshot()
        val rowEntries = continueWatchingRow()
        val seeds = try {
            continueWatchingNextUpSeedsForDiagnostics(rowEntries)
        } catch (error: Throwable) {
            log.w { "Continue Watching diagnostics: no Up Next seeds (${error.message})" }
            emptyList()
        }
        buildContinueWatchingDiagnosticLines(
            // Two short header lines: one long line loses its middle on the TV (review).
            header = buildList {
                add(
                    "cur=$currentProfileId act=${ProfileRepository.activeProfileId} src=$activeSource " +
                        "remote=$hasLoadedNuvioRemoteProgress deltaInit=$deltaInitialized",
                )
                add(
                    "n=${localEntries.size} dirty=${dirtyKeys.size} xprof=$crossProfileWriteCount " +
                        "map=${ContinueWatchingSeriesIdentity.aliasCount()} wu=${seriesIdentityWarmUp.claimedCount()} " +
                        "fut=${futureServerRowCount()}",
                )
                if (lastCrossProfileWrite.isNotEmpty()) add("xprof last $lastCrossProfileWrite")
            },
            entries = currentEntries(),
            dirtyKeys = dirtyKeys,
            rowEntries = rowEntries,
            nowEpochMs = nowEpochMs,
            nextUpSeeds = seeds,
            nextUpOutcomes = ContinueWatchingNextUp.resolutionOutcomes(),
            canonicalSeriesId = ContinueWatchingSeriesIdentity::canonical,
        )
    } catch (error: Throwable) {
        log.e(error) { "Continue Watching diagnostics failed" }
        listOf("Continue Watching diagnostics failed: ${error::class.simpleName}: ${error.message.orEmpty()}")
    }

    /** The Up Next seeds Home resolves its cards from, as `ContinueWatchingNextUpModel` asks for them. */
    private fun continueWatchingNextUpSeedsForDiagnostics(
        rowEntries: List<WatchProgressEntry>,
    ): List<ContinueWatchingNextUpSeed> {
        val preferences = ContinueWatchingPreferencesRepository.uiState.value
        return ContinueWatchingNextUp.seeds(
            watchedItems = WatchedRepository.uiState.value.items,
            inProgressEntries = rowEntries,
            preferFurthestEpisode = preferences.upNextFromFurthestEpisode,
            dismissedNextUpKeys = preferences.dismissedNextUpKeys,
            limit = CONTINUE_WATCHING_DIAGNOSTICS_SEED_LIMIT,
        )
    }

    fun refreshEpisodeProgress(contentId: String, forceRefresh: Boolean = false) {
        ensureLoaded()
        val provider = activeProgressProvider() ?: return
        syncScope.launch {
            runCatching {
                provider.refreshEpisodeProgress(
                    contentId = contentId,
                    forceRefresh = forceRefresh,
                )
            }.onFailure { error ->
                if (error is CancellationException) throw error
                log.w {
                    "Failed to refresh ${provider.providerId.storageId} episode progress " +
                        "for $contentId: ${error.message}"
                }
            }
        }
    }

    private fun upsert(
        session: WatchProgressPlaybackSession,
        snapshot: PlayerPlaybackSnapshot,
        persist: Boolean,
        syncRemote: Boolean,
        allowProfileReload: Boolean = true,
    ) {
        val targetProfileId = session.profileId
        val positionMs = snapshot.positionMs.coerceAtLeast(0L)
        val durationMs = snapshot.durationMs.coerceAtLeast(0L)
        val isCompleted = isWatchProgressComplete(
            positionMs = positionMs,
            durationMs = durationMs,
            isEnded = snapshot.isEnded,
        )
        if (!isCompleted && !shouldStoreWatchProgress(positionMs = positionMs, durationMs = durationMs)) {
            return
        }

        val progressProvider = activeProgressProvider()

        // If a tracker is the active CW source and parentMetaId is not resolvable by it, but
        // videoId contains an id the provider understands, use the resolved id to avoid duplicate
        // CW entries (one local with a garbage id, one from the provider with the real id).
        val effectiveParentMetaId = progressProvider?.normalizeParentContentId(
            parentContentId = session.parentMetaId,
            videoId = session.videoId,
        ) ?: session.parentMetaId

        val candidateEntry = WatchProgressEntry(
            contentType = session.contentType,
            parentMetaId = effectiveParentMetaId,
            parentMetaType = session.parentMetaType,
            videoId = session.videoId,
            title = session.title,
            logo = session.logo,
            poster = session.poster,
            background = session.background,
            seasonNumber = session.seasonNumber,
            episodeNumber = session.episodeNumber,
            episodeTitle = session.episodeTitle,
            episodeThumbnail = session.episodeThumbnail,
            lastPositionMs = if (isCompleted && durationMs > 0L) durationMs else positionMs,
            durationMs = durationMs,
            lastUpdatedEpochMs = WatchProgressClock.nowEpochMs(),
            providerName = session.providerName,
            providerAddonId = session.providerAddonId,
            lastStreamTitle = session.lastStreamTitle,
            lastStreamSubtitle = session.lastStreamSubtitle,
            pauseDescription = session.pauseDescription,
            lastSourceUrl = session.lastSourceUrl,
            isCompleted = isCompleted,
        ).normalizedCompletion()

        val activeProfileId = ProfileRepository.activeProfileId
        val profilePath = playbackWriteProfilePath(
            targetProfileId = targetProfileId,
            loadedProfileId = currentProfileId,
            activeProfileId = activeProfileId,
        )
        if (profilePath != PlaybackWriteProfilePath.LOADED) {
            val detail = "target=$targetProfileId current=$currentProfileId active=$activeProfileId"
            // CW legacy #4: a write for the active profile while another one is loaded here only
            // reached the disk, and Home — which reads the loaded state — never saw it. The active
            // profile is switched to instead, as its selection does (its source, tracking settings
            // and providers too), and the write starts over on its in-memory path: the provider
            // and parent id above belong to the profile that was loaded.
            if (
                profilePath == PlaybackWriteProfilePath.RELOAD_ACTIVE &&
                allowProfileReload &&
                reloadActiveProfileForWrite(targetProfileId)
            ) {
                recordCrossProfileWrite("reload $detail")
                upsert(
                    session = session,
                    snapshot = snapshot,
                    persist = persist,
                    syncRemote = syncRemote,
                    allowProfileReload = false,
                )
                return
            }
            recordCrossProfileWrite("disk $detail")
            writeStoredProfileProgress(
                profileId = targetProfileId,
                candidateEntry = candidateEntry,
                persist = persist,
                syncRemote = syncRemote,
            )
            return
        }

        val entry = localEntriesSnapshot().resolveIdentityForUpsert(candidateEntry)
        if (
            syncRemote &&
            !remoteWriteDeduplicator.shouldSend(
                profileId = targetProfileId,
                entry = entry,
                nowEpochMs = candidateEntry.lastUpdatedEpochMs,
            )
        ) {
            return
        }

        // Fork: every type Continue Watching seeds Up Next cards from ("tv" too, not only
        // "series") — a dismissed card must come back once the show is played again.
        if (entry.parentMetaType.isSeriesTypeForContinueWatching()) {
            ContinueWatchingPreferencesRepository.removeDismissedNextUpKeysForContent(entry.parentMetaId)
        }

        upsertLocalEntry(entry)
        markProgressDirty(entry)
        progressProvider?.applyOptimisticProgress(entry)
        publish()
        if (persist) persist()
        if (entry.needsRemoteMetadataEnrichment()) {
            resolveRemoteMetadata()
        }
        if (syncRemote) {
            pushScrobbleToServer(entry = entry, profileId = targetProfileId)
        }
        if (
            shouldCascadeCompletedProgressToWatchedHistory(
                entry = entry,
                providerOwnsCompletedHistory = progressProvider?.ownsCompletedHistoryProjection == true,
            )
        ) {
            WatchingActions.onProgressEntryUpdated(entry, syncRemote = syncRemote)
        }
    }

    /**
     * CW legacy #4: switches to the active profile [profileId] for a playback write made while
     * another profile is loaded here — the profile selection normally does it first (nothing known
     * skips it, the diagnostics count it as `xprof`). The whole switch, as [onProfileChanged] does
     * it for the selection (review): the profile's source, tracking settings and providers along
     * with its entries — a bare load would leave them on the other profile, and the selection's
     * own [onProfileChanged] would then find the profile loaded and switch nothing. The account
     * pull follows the profile selection as usual (`WatchProgressSourceCoordinator`).
     *
     * Never throws into the Swift caller: false when the switch fails, and the write then only
     * goes to disk, as before.
     */
    private fun reloadActiveProfileForWrite(profileId: Int): Boolean = try {
        onProfileChanged(profileId)
        hasLoaded && currentProfileId == profileId
    } catch (error: Throwable) {
        log.e(error) { "Failed to load profile $profileId for a playback write; it only goes to disk" }
        false
    }

    /** A playback write for a profile that is not the loaded one: its stored payload only. */
    private fun writeStoredProfileProgress(
        profileId: Int,
        candidateEntry: WatchProgressEntry,
        persist: Boolean,
        syncRemote: Boolean,
    ) {
        val resolvedEntry = resolveStoredProfileProgressIdentity(
            profileId = profileId,
            entry = candidateEntry,
        )
        if (
            syncRemote &&
            !remoteWriteDeduplicator.shouldSend(
                profileId = profileId,
                entry = resolvedEntry,
                nowEpochMs = candidateEntry.lastUpdatedEpochMs,
            )
        ) {
            return
        }
        val entry = if (persist) {
            upsertStoredProfileProgress(profileId = profileId, entry = resolvedEntry)
        } else {
            resolvedEntry
        }
        if (syncRemote) {
            pushScrobbleToServer(entry = entry, profileId = profileId)
        }
    }

    /**
     * CW legacy diagnosis (REMAINING_FIX #1): counts a playback write made for another profile than
     * the loaded or the active one ([PlaybackWriteProfilePath]). Playback saves every 5 s, so the
     * warning is only logged when the profiles involved change.
     */
    private fun recordCrossProfileWrite(detail: String) {
        crossProfileWriteCount += 1
        if (detail == lastCrossProfileWrite) return
        lastCrossProfileWrite = detail
        log.w { "Watch progress write outside the loaded profile: $detail" }
    }

    private fun upsertStoredProfileProgress(
        profileId: Int,
        entry: WatchProgressEntry,
    ): WatchProgressEntry {
        val payload = WatchProgressStorage.loadPayload(profileId).orEmpty().trim()
        val storedPayload = if (payload.isNotEmpty()) {
            WatchProgressCodec.decodePayload(payload)
        } else {
            StoredWatchProgressPayload()
        }
        val resolvedEntry = storedPayload.entries.resolveIdentityForUpsert(entry)
        val progressKey = resolvedEntry.resolvedProgressKey()
        val updatedEntries = storedPayload.entries
            .filterNot { it.resolvedProgressKey() == progressKey } + resolvedEntry
        WatchProgressStorage.savePayload(
            profileId,
            WatchProgressCodec.encodePayload(
                entries = updatedEntries,
                lastSuccessfulPushEpochMs = storedPayload.lastSuccessfulPushEpochMs,
                deltaCursorEventId = storedPayload.deltaCursorEventId,
                deltaInitialized = storedPayload.deltaInitialized,
                dirtyProgressKeys = storedPayload.dirtyProgressKeys + progressKey,
            ),
        )
        return resolvedEntry
    }

    private fun resolveStoredProfileProgressIdentity(
        profileId: Int,
        entry: WatchProgressEntry,
    ): WatchProgressEntry {
        val payload = WatchProgressStorage.loadPayload(profileId).orEmpty().trim()
        val storedEntries = if (payload.isEmpty()) {
            emptyList()
        } else {
            WatchProgressCodec.decodePayload(payload).entries
        }
        return storedEntries.resolveIdentityForUpsert(entry)
    }

    /**
     * The freshest entry to re-push for [failedEntry]'s progress key, or null to skip the retry.
     *
     * - Active profile: the in-memory entries are authoritative. Key present → retry that entry
     *   (it is the failed one, or something newer recorded during the delay). Key absent → the
     *   progress was removed (removals push their own delete) — skip.
     * - Other profiles: the stored payload is authoritative when it has the key (cross-profile
     *   scrobbles with `persist` land there; there is no cross-profile delete path to respect).
     *   A non-persisted cross-profile scrobble leaves no local trace, so the captured entry is
     *   all there is — retry it.
     */
    private fun latestScrobbleForRetry(profileId: Int, failedEntry: WatchProgressEntry): WatchProgressEntry? {
        val progressKey = failedEntry.resolvedProgressKey()
        if (profileId == currentProfileId) {
            return localEntriesSnapshot().firstOrNull { it.resolvedProgressKey() == progressKey }
        }
        val payload = WatchProgressStorage.loadPayload(profileId).orEmpty().trim()
        val storedMatch = if (payload.isEmpty()) {
            null
        } else {
            WatchProgressCodec.decodePayload(payload).entries.firstOrNull { it.resolvedProgressKey() == progressKey }
        }
        return storedMatch?.takeIf { it.lastUpdatedEpochMs >= failedEntry.lastUpdatedEpochMs } ?: failedEntry
    }

    private fun pushScrobbleToServer(entry: WatchProgressEntry, profileId: Int, isRetry: Boolean = false) {
        val operationGeneration = profileGeneration.takeIf { profileId == currentProfileId }
        accountScopeSnapshot().launch {
            runCatching {
                syncAdapter.push(profileId = profileId, entries = listOf(entry))
                recordSuccessfulPush(
                    profileId = profileId,
                    operationGeneration = operationGeneration,
                    entries = listOf(entry),
                )
            }.onFailure { e ->
                log.e(e) { "Failed to push watch progress scrobble" }
                // The deduplicator recorded this entry at send time; a failed push must not keep
                // suppressing identical rewrites (a terminal flush may already have been absorbed
                // inside the window — see RemoteProgressWriteDeduplicator). Roll the key back and
                // retry the same entry once; a second failure leaves the key rolled back so any
                // later identical write pushes again.
                remoteWriteDeduplicator.clearEntry(
                    profileId = profileId,
                    progressKey = entry.resolvedProgressKey(),
                )
                if (!isRetry) {
                    delay(WATCH_PROGRESS_REMOTE_WRITE_DEDUP_WINDOW_MS)
                    // Never re-send the captured snapshot blindly: playback may have recorded (and
                    // even successfully pushed) NEWER progress for this key during the delay, and
                    // a stale re-push would regress the backend. Retry whatever is authoritative
                    // for the key NOW; a null means the entry was removed locally — retrying
                    // would resurrect deleted progress remotely, so drop the retry instead.
                    val latestEntry = latestScrobbleForRetry(profileId = profileId, failedEntry = entry)
                    if (latestEntry != null) {
                        pushScrobbleToServer(entry = latestEntry, profileId = profileId, isRetry = true)
                    }
                }
            }
        }
    }

    /**
     * CW sync (REMAINING_FIX #2): once per profile per process, right after a successful Nuvio pull,
     * push the rows that are still dirty ([selectDirtyWatchProgressBacklog]) — progress recorded
     * while every tvOS write stayed local (builds up to 130) never reached the account, and nothing
     * else ever re-sends a dirty row. A successful push acknowledges them like any other push
     * ([recordSuccessfulPush]); a failed one is logged and tried again on the next launch.
     *
     * Only after a Nuvio pull, so only while Nuvio Sync is the Watch Progress Source. With Trakt
     * (the default whenever it is connected) or Simkl as the source, the old rows reach the
     * account once the source is switched to Nuvio Sync. Pushing without a pull could overwrite
     * rows the account has since moved past.
     *
     * The selection, the push and its acknowledgement all run under [nuvioPullMutex]. The pull
     * that called this holds the mutex, so the work starts once that pull is done. Keeping them
     * under the mutex means no later pull can apply a newer account row, and acknowledge the key,
     * between the moment a row is picked and the push that would overwrite that newer row with it.
     */
    private fun pushDirtyProgressBacklogOnce(profileId: Int, operationGeneration: Long) {
        if (!isActiveOperation(profileId, operationGeneration) || !hasLoadedNuvioRemoteProgress) return
        if (!synchronized(backlogPushLock) { backlogPushedProfileIds.add(profileId) }) return
        accountScopeSnapshot().launch {
            var pushedRows = 0
            try {
                nuvioPullMutex.withLock {
                    if (!isActiveOperation(profileId, operationGeneration)) return@withLock
                    val dirtyKeys = dirtyProgressKeysSnapshot()
                    val backlog = selectDirtyWatchProgressBacklog(
                        entries = localEntriesSnapshot(),
                        dirtyProgressKeys = dirtyKeys,
                    )
                    if (backlog.isEmpty()) return@withLock
                    pushedRows = backlog.size
                    log.i {
                        "Pushing the watch-progress backlog for profile $profileId: ${backlog.size} of " +
                            "${dirtyKeys.size} unsynced rows, newest first"
                    }
                    syncAdapter.push(profileId = profileId, entries = backlog)
                    recordSuccessfulPush(
                        profileId = profileId,
                        operationGeneration = operationGeneration,
                        entries = backlog,
                    )
                    log.i { "Pushed the watch-progress backlog for profile $profileId (${backlog.size} rows)" }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.e(error) {
                    "Failed to push the watch-progress backlog for profile $profileId ($pushedRows rows); " +
                        "it is tried again on the next launch"
                }
            }
        }
    }

    /**
     * The delete waits for [nuvioPullMutex] (CW alias fix): the one-time backlog push picks and
     * sends its rows under it, so a removal made while that push is in flight — which may carry
     * the rows just removed, alias rows included — reaches the account after it, and the removed
     * rows stay removed. A pull in flight is waited for the same way; until the delete is done,
     * the removed keys are pending ([pendingServerDeletes]), and no pull puts their rows back.
     *
     * A key written here again meanwhile (the episode played again) is no longer removed: the
     * delete leaves it out, so it cannot erase the new progress on the account.
     */
    private fun pushDeleteToServer(entries: Collection<WatchProgressEntry>) {
        val profileId = currentProfileId
        val keys = entries.mapTo(mutableSetOf(), WatchProgressEntry::resolvedProgressKey)
        if (activeSource.providerId != null) {
            clearPendingServerDeletes(profileId, keys)
            return
        }
        accountScopeSnapshot().launch {
            try {
                if (entries.isEmpty()) return@launch
                nuvioPullMutex.withLock {
                    val stillRemoved = if (profileId == currentProfileId) {
                        entries.filter { entry -> localEntry(entry.resolvedProgressKey()) == null }
                    } else {
                        entries.toList()
                    }
                    if (stillRemoved.isNotEmpty()) {
                        syncAdapter.delete(profileId = profileId, entries = stillRemoved)
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.e(error) { "Failed to push watch progress delete" }
            } finally {
                // Done either way: after a failure the account still holds the rows, and the next
                // pull may show them again.
                clearPendingServerDeletes(profileId, keys)
            }
        }
    }

    private fun clearPendingServerDeletes(profileId: Int, progressKeys: Collection<String>) {
        if (progressKeys.isEmpty()) return
        synchronized(entriesLock) {
            progressKeys.forEach { key -> pendingServerDeletes.remove(profileId to key) }
        }
    }

    private fun publish() {
        val entries = currentEntries()
        val sortedEntries = entries.sortedByDescending { it.lastUpdatedEpochMs }
        val providerSnapshot = activeProgressProvider()?.snapshot()
        publishFollowedShows()
        _uiState.value = projectWatchProgressUiState(
            source = activeSource,
            entries = sortedEntries,
            providerSnapshot = providerSnapshot,
            hasLoadedNuvioRemoteProgress = hasLoadedNuvioRemoteProgress,
            seriesIdentityVersion = ContinueWatchingSeriesIdentity.version.value,
        )
    }

    private fun persist() {
        WatchProgressStorage.savePayload(
            currentProfileId,
            WatchProgressCodec.encodePayload(
                entries = localEntriesSnapshot(),
                lastSuccessfulPushEpochMs = lastSuccessfulPushEpochMs,
                deltaCursorEventId = deltaCursorEventId,
                deltaInitialized = deltaInitialized,
                dirtyProgressKeys = dirtyProgressKeysSnapshot(),
            ),
        )
    }

    private fun recordSuccessfulPush(
        profileId: Int,
        operationGeneration: Long?,
        entries: Collection<WatchProgressEntry>,
    ) {
        if (profileId != currentProfileId) {
            acknowledgeStoredProfilePush(profileId = profileId, pushedEntries = entries)
            return
        }
        if (operationGeneration != profileGeneration) return
        val dirtyChanged = acknowledgeCurrentProfilePush(entries)
        val latestPushed = entries
            .asSequence()
            .map { entry -> entry.lastUpdatedEpochMs }
            .maxOrNull()
            ?: 0L
        val watermarkChanged = latestPushed > lastSuccessfulPushEpochMs
        if (watermarkChanged) {
            lastSuccessfulPushEpochMs = latestPushed
        }
        if (dirtyChanged || watermarkChanged) persist()
    }

    private fun acknowledgeCurrentProfilePush(entries: Collection<WatchProgressEntry>): Boolean =
        synchronized(entriesLock) {
            var changed = false
            entries.forEach { pushed ->
                val key = pushed.resolvedProgressKey()
                val current = entriesByProgressKey[key]
                if (
                    (current == null || current.lastUpdatedEpochMs <= pushed.lastUpdatedEpochMs) &&
                    dirtyProgressKeys.remove(key)
                ) {
                    changed = true
                }
            }
            changed
        }

    private fun acknowledgeStoredProfilePush(
        profileId: Int,
        pushedEntries: Collection<WatchProgressEntry>,
    ) {
        val payload = WatchProgressStorage.loadPayload(profileId).orEmpty().trim()
        if (payload.isEmpty()) return
        val storedPayload = WatchProgressCodec.decodePayload(payload)
        val storedByKey = storedPayload.entries.newestByProgressKey()
        val acknowledgedKeys = pushedEntries.mapNotNullTo(mutableSetOf()) { pushed ->
            val key = pushed.resolvedProgressKey()
            val current = storedByKey[key]
            key.takeIf { current == null || current.lastUpdatedEpochMs <= pushed.lastUpdatedEpochMs }
        }
        val remainingDirtyKeys = storedPayload.dirtyProgressKeys - acknowledgedKeys
        val latestPushed = pushedEntries.maxOfOrNull(WatchProgressEntry::lastUpdatedEpochMs) ?: 0L
        if (
            remainingDirtyKeys == storedPayload.dirtyProgressKeys &&
            latestPushed <= storedPayload.lastSuccessfulPushEpochMs
        ) {
            return
        }
        WatchProgressStorage.savePayload(
            profileId,
            WatchProgressCodec.encodePayload(
                entries = storedPayload.entries,
                lastSuccessfulPushEpochMs = maxOf(storedPayload.lastSuccessfulPushEpochMs, latestPushed),
                deltaCursorEventId = storedPayload.deltaCursorEventId,
                deltaInitialized = storedPayload.deltaInitialized,
                dirtyProgressKeys = remainingDirtyKeys,
            ),
        )
    }

    private fun accountScopeSnapshot(): CoroutineScope = synchronized(accountScopeLock) {
        accountScope
    }

    private fun updateActiveSource(source: WatchProgressSource) {
        activeSource = source
        _activeSourceState.value = source
    }

    private fun removeStoredLocalEntries(entries: Collection<WatchProgressEntry>): List<WatchProgressEntry> =
        synchronized(entriesLock) {
            val targetKeys = entries.mapTo(mutableSetOf()) { entry -> entry.resolvedProgressKey() }
            val keysToRemove = entriesByProgressKey
                .filterValues { localEntry ->
                    localEntry.resolvedProgressKey() in targetKeys || entries.any { target ->
                        localEntry.parentMetaId == target.parentMetaId &&
                            localEntry.seasonNumber == target.seasonNumber &&
                            localEntry.episodeNumber == target.episodeNumber
                    }
                }
                .keys
                .toList()
            dirtyProgressKeys.removeAll(keysToRemove.toSet())
            keysToRemove.mapNotNull(entriesByProgressKey::remove)
        }

    private fun currentEntries(): List<WatchProgressEntry> {
        val provider = activeProgressProvider()
        val projectedEntries = projectWatchProgressSourceEntries(
            source = activeSource,
            nuvioEntries = localEntriesSnapshot(),
            providerEntries = provider?.snapshot()?.entries.orEmpty(),
            canProviderRepresent = { contentId ->
                provider?.canRepresentContentId(contentId) ?: true
            },
        )
        return if (activeSource.providerId == null) {
            projectedEntries
        } else {
            providerMetadataOverlay.project(source = activeSource, entries = projectedEntries)
        }
    }

    /**
     * Recomputes [followedShows] from every REGISTERED provider, not just the active one:
     * Trakt-imported history lives in Trakt's snapshot and never in the local store, so a
     * Trakt→Simkl flip would otherwise drop it. `snapshot()` is a StateFlow read per provider —
     * no I/O.
     *
     * KNOWN RESIDUAL (Codex round 4, deliberately not fixed here): only providers whose snapshot
     * is already populated in THIS process contribute. On a cold start with Simkl active and Trakt
     * merely connected, Trakt's snapshot is never loaded, so a show the user has Trakt progress on
     * but never saved to their Library is missing from the sweep until Trakt is activated in the
     * same session. The row does not empty — the Library half still seeds it, and the Library
     * source is independent — so this is a narrower gap than the bug this fixes. Closing it needs
     * either eager loads of inactive connected providers at startup (network for a provider the
     * user is not using) or a small persisted followed-id set; both are their own decision.
     *
     * Called from [publish] AND from an inactive provider's change: on a profile switch,
     * `loadFromDisk()` publishes before the inactive providers clear their snapshots, so without
     * the second call this flow would keep serving the previous profile's titles to the Upcoming
     * row. `uiState` and metadata resolution stay correctly active-only.
     */
    private fun publishFollowedShows() {
        _followedShows.value = unionFollowedShowEntries(
            nuvioEntries = localEntriesSnapshot(),
            // CONNECTED providers only. Disconnecting Trakt clears its credentials but not
            // `TraktProgressRepository`, so an unfiltered union would keep serving that history to
            // the Upcoming row for the rest of the session.
            providerEntries = TrackingProviderRegistry.progressProviders()
                .filter { provider -> TrackingProviderRegistry.isAuthenticated(provider.providerId) }
                .flatMap { provider -> provider.snapshot().entries },
        )
    }

    private fun localEntriesSnapshot(): List<WatchProgressEntry> =
        synchronized(entriesLock) {
            entriesByProgressKey.values.toList()
        }

    private fun localEntry(progressKey: String): WatchProgressEntry? =
        synchronized(entriesLock) {
            entriesByProgressKey[progressKey]
        }

    private fun localEntryCount(): Int =
        synchronized(entriesLock) {
            entriesByProgressKey.size
        }

    private fun clearLocalEntries() {
        synchronized(entriesLock) {
            entriesByProgressKey.clear()
            dirtyProgressKeys.clear()
        }
    }

    private fun dirtyProgressKeysSnapshot(): Set<String> =
        synchronized(entriesLock) {
            dirtyProgressKeys.toSet()
        }

    private fun replaceDirtyProgressKeys(keys: Collection<String>) {
        synchronized(entriesLock) {
            dirtyProgressKeys = keys
                .filterTo(mutableSetOf()) { key -> key in entriesByProgressKey }
        }
    }

    private fun markProgressDirty(entry: WatchProgressEntry) {
        synchronized(entriesLock) {
            dirtyProgressKeys += entry.resolvedProgressKey()
        }
    }

    private fun clearProgressDirty(progressKey: String) {
        synchronized(entriesLock) {
            dirtyProgressKeys -= progressKey
        }
    }

    private fun migrateDirtyProgressKeys(migrations: Map<String, String>) {
        if (migrations.isEmpty()) return
        synchronized(entriesLock) {
            migrations.forEach { (oldKey, newKey) ->
                if (dirtyProgressKeys.remove(oldKey)) {
                    dirtyProgressKeys += newKey
                }
            }
        }
    }

    private fun acknowledgeDirtyProgressFromSnapshot(
        serverEntries: Collection<ProgressSyncRecord>,
        localEntriesBeforeApply: Collection<WatchProgressEntry>,
        dirtyKeysBeforeApply: Set<String>,
    ) {
        if (dirtyKeysBeforeApply.isEmpty()) return
        val localByKey = localEntriesBeforeApply.newestByProgressKey()
        val remoteByKey = linkedMapOf<String, WatchProgressEntry>()
        serverEntries.forEach { record ->
            val key = record.resolvedProgressKey()
            val candidate = record.toWatchProgressEntry(cached = localByKey[key])
            val existing = remoteByKey[key]
            if (existing == null || candidate.isFresherThan(existing)) {
                remoteByKey[key] = candidate
            }
        }
        synchronized(entriesLock) {
            dirtyKeysBeforeApply.forEach { key ->
                val local = localByKey[key]
                val remote = remoteByKey[key]
                if (remote != null && (local == null || !local.isFresherThan(remote))) {
                    dirtyProgressKeys -= key
                }
            }
        }
    }

    private fun replaceLocalEntries(entries: Collection<WatchProgressEntry>) {
        synchronized(entriesLock) {
            entriesByProgressKey = entries.newestByProgressKey().toMutableMap()
        }
    }

    /**
     * A snapshot pull's result: [entries] replace the local ones, without the rows of keys whose
     * removal here has not reached the account yet ([withoutPendingServerDeletes]), in one step with
     * the replacement — a removal can never land between the check and the write.
     */
    private fun replaceLocalEntriesFromServer(entries: Collection<WatchProgressEntry>, profileId: Int) {
        synchronized(entriesLock) {
            val pendingKeys = pendingServerDeleteKeysLocked(profileId)
            entriesByProgressKey = withoutPendingServerDeletes(
                entries = entries,
                pendingDeleteKeys = pendingKeys,
                dirtyProgressKeys = dirtyProgressKeys,
            ).newestByProgressKey().toMutableMap()
        }
    }

    private fun upsertLocalEntry(entry: WatchProgressEntry) {
        synchronized(entriesLock) {
            val resolvedEntry = entry.withResolvedProgressKey()
            entriesByProgressKey[resolvedEntry.resolvedProgressKey()] = resolvedEntry
        }
    }

    /**
     * A delta pull's upsert of [entry]: skipped (false) while its key's removal here has not reached
     * the account and nothing was written under it since — the same rule as the snapshot's
     * ([replaceLocalEntriesFromServer]).
     */
    private fun upsertLocalEntryFromServer(entry: WatchProgressEntry): Boolean =
        synchronized(entriesLock) {
            val resolvedEntry = entry.withResolvedProgressKey()
            val key = resolvedEntry.resolvedProgressKey()
            if (key !in entriesByProgressKey && key in pendingServerDeleteKeysLocked(currentProfileId)) {
                return@synchronized false
            }
            entriesByProgressKey[key] = resolvedEntry
            true
        }

    /** Call with [entriesLock] held. */
    private fun pendingServerDeleteKeysLocked(profileId: Int): Set<String> =
        if (pendingServerDeletes.isEmpty()) {
            emptySet()
        } else {
            pendingServerDeletes.mapNotNullTo(mutableSetOf()) { (pendingProfileId, key) ->
                key.takeIf { pendingProfileId == profileId }
            }
        }

    private fun removeLocalEntry(progressKey: String): WatchProgressEntry? =
        synchronized(entriesLock) {
            dirtyProgressKeys -= progressKey
            entriesByProgressKey.remove(progressKey)
        }

    /**
     * Removes [progressKeys] for a removal whose server delete follows ([pushDeleteToServer]): with
     * [pendingDeleteProfileId] (Nuvio Sync is the source), the keys are pending until it is done,
     * marked in the same step as they are removed.
     */
    private fun removeLocalEntriesForServerDelete(
        progressKeys: Collection<String>,
        pendingDeleteProfileId: Int?,
    ): List<WatchProgressEntry> =
        synchronized(entriesLock) {
            if (pendingDeleteProfileId != null) {
                progressKeys.forEach { key -> pendingServerDeletes += pendingDeleteProfileId to key }
            }
            progressKeys.mapNotNull { key ->
                dirtyProgressKeys -= key
                entriesByProgressKey.remove(key)
            }
        }

    private fun removeLocalEntriesForVideoIds(
        videoIds: Collection<String>,
        parentMetaId: String?,
        pendingDeleteProfileId: Int? = null,
    ): List<WatchProgressEntry> =
        synchronized(entriesLock) {
            if (videoIds.isEmpty()) return@synchronized emptyList()
            val ids = videoIds.toSet()
            val keysToRemove = entriesByProgressKey
                .filterValues { entry ->
                    entry.videoId in ids &&
                        (parentMetaId == null || entry.parentMetaId == parentMetaId)
                }
                .keys
                .toList()
            if (pendingDeleteProfileId != null) {
                keysToRemove.forEach { key -> pendingServerDeletes += pendingDeleteProfileId to key }
            }
            dirtyProgressKeys.removeAll(keysToRemove.toSet())
            keysToRemove.mapNotNull(entriesByProgressKey::remove)
        }

    fun isDroppedShow(contentId: String): Boolean =
        activeProgressProvider()?.isHiddenFromProgress(contentId) == true

    fun activeProviderOwnsCompletedHistoryProjection(): Boolean =
        activeProgressProvider()?.ownsCompletedHistoryProjection == true

    fun activeProviderContinueWatchingCutoffEpochMs(
        daysCap: Int,
        nowEpochMs: Long,
    ): Long? = activeProgressProvider()?.continueWatchingCutoffEpochMs(daysCap, nowEpochMs)

    fun shouldUseAsNextUpSeed(entry: WatchProgressEntry, nowEpochMs: Long): Boolean =
        activeProgressProvider()?.shouldUseAsNextUpSeed(entry, nowEpochMs)
            ?: entry.shouldUseAsCompletedSeedForContinueWatching()

    suspend fun prepareNextUpProgressEntries(
        entries: List<WatchProgressEntry>,
        contentId: String,
    ): List<WatchProgressEntry> = activeProgressProvider()
        ?.prepareNextUpProgressEntries(entries, contentId)
        ?: entries

    private fun AddonsUiState.metadataProviderReadiness(): MetadataProviderReadiness {
        val enabled = addons.enabledAddons()
        val providers = enabled
            .mapNotNull { addon -> addon.manifest }
            .filter { manifest -> manifest.hasMetaResource() }
        return MetadataProviderReadiness(
            providers = providers,
        )
    }

    private fun AddonManifest.hasMetaResource(): Boolean =
        resources.any { resource -> resource.name == "meta" }

}
