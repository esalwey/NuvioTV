package com.nuvio.app.features.watched

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.TrackingSettingsRepository
import com.nuvio.app.features.tracking.WatchProgressSource
import com.nuvio.app.features.tracking.effectiveWatchProgressSource
import com.nuvio.app.features.tracking.providerId
import com.nuvio.app.features.watching.sync.SupabaseWatchedSyncAdapter
import com.nuvio.app.features.watching.sync.WatchedDeltaEvent
import com.nuvio.app.features.watching.sync.WatchedSyncAdapter
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

enum class WatchedTrackerHistorySync {
    Mirror,
    Skip,
}

/** Fork shim: composeApp's WatchedRepositoryTest still refers to the Trakt-era enum name. */
typealias WatchedTraktHistorySync = WatchedTrackerHistorySync

data class WatchedPushOutcome(
    val nuvioSyncSucceeded: Boolean = false,
    val succeededTrackerProviderIds: Set<TrackingProviderId> = emptySet(),
)

fun shouldMirrorWatchedMarkToTrackers(
    sync: WatchedTrackerHistorySync,
    hasConnectedTracker: Boolean,
): Boolean = sync == WatchedTrackerHistorySync.Mirror && hasConnectedTracker

/** Fork shim over [shouldMirrorWatchedMarkToTrackers] — composeApp's WatchedRepositoryTest. */
fun shouldMirrorWatchedMarkToTraktHistory(
    sync: WatchedTraktHistorySync,
    isTraktAuthenticated: Boolean,
): Boolean = shouldMirrorWatchedMarkToTrackers(
    sync = sync,
    hasConnectedTracker = isTraktAuthenticated,
)

// Fork: public (upstream: internal) — composeApp tests consume these cross-module.
data class WatchedSourceOperation(
    val source: WatchProgressSource,
    val generation: Long,
)

fun isWatchedSourceOperationCurrent(
    operation: WatchedSourceOperation,
    activeSource: WatchProgressSource,
    activeGeneration: Long,
): Boolean = operation.source == activeSource && operation.generation == activeGeneration

fun watchedItemsForSource(
    source: WatchProgressSource,
    nuvioItems: Collection<WatchedItem>,
    providerItems: Map<TrackingProviderId, Collection<WatchedItem>>,
): Collection<WatchedItem> = source.providerId
    ?.let { providerId -> providerItems[providerId].orEmpty() }
    ?: nuvioItems

/** Fork shim over the provider-map overload — composeApp's WatchedRepositoryTest. */
fun watchedItemsForSource(
    source: WatchProgressSource,
    nuvioItems: Collection<WatchedItem>,
    traktItems: Collection<WatchedItem>,
): Collection<WatchedItem> = watchedItemsForSource(
    source = source,
    nuvioItems = nuvioItems,
    providerItems = mapOf(TrackingProviderId.TRAKT to traktItems),
)

/**
 * Fork shim: upstream deleted this in eb2d5d3a (all sources persist now), but composeApp's
 * WatchedRepositoryTest still calls it cross-module. No internal call sites remain.
 */
fun shouldPersistWatchedSource(source: WatchProgressSource): Boolean =
    source.providerId == null

fun shouldAcknowledgeNuvioWatchedPush(
    source: WatchProgressSource,
    outcome: WatchedPushOutcome,
): Boolean = source.providerId == null && outcome.nuvioSyncSucceeded

/**
 * Upstream names this `replaceWatchedItemsForSource`; the fork keeps that name for the Trakt-shaped
 * shim below (composeApp's WatchedRepositoryTest calls it), and the two would collide after JVM
 * erasure — both take three `Map`s. A distinct Kotlin name avoids relying on `@JvmName`.
 */
fun replaceWatchedItemsForProviderSource(
    source: WatchProgressSource,
    nuvioItems: MutableMap<String, WatchedItem>,
    providerItems: MutableMap<TrackingProviderId, MutableMap<String, WatchedItem>>,
    replacement: Map<String, WatchedItem>,
) {
    val target = source.providerId
        ?.let { providerId -> providerItems.getOrPut(providerId, ::mutableMapOf) }
        ?: nuvioItems
    target.clear()
    target.putAll(replacement)
}

/** Fork shim over [replaceWatchedItemsForProviderSource] — composeApp's WatchedRepositoryTest. */
fun replaceWatchedItemsForSource(
    source: WatchProgressSource,
    nuvioItems: MutableMap<String, WatchedItem>,
    traktItems: MutableMap<String, WatchedItem>,
    replacement: Map<String, WatchedItem>,
) = replaceWatchedItemsForProviderSource(
    source = source,
    nuvioItems = nuvioItems,
    providerItems = mutableMapOf(TrackingProviderId.TRAKT to traktItems),
    replacement = replacement,
)

internal suspend fun <T> watchedProviderRefreshOrNull(
    refresh: suspend () -> T,
    onFailure: (Throwable) -> Unit,
): T? = try {
    refresh()
} catch (error: CancellationException) {
    throw error
} catch (error: Throwable) {
    onFailure(error)
    null
}

internal fun extraWatchedKeysChanged(
    previous: Set<String>?,
    current: Set<String>,
): Boolean = previous.orEmpty() != current

internal const val WATCHED_BACKLOG_PUSH_LIMIT = 200

/**
 * CW sync (REMAINING_FIX #2): the watched marks the one-time post-pull backlog push sends — Nuvio
 * marks whose key is still dirty, most recently marked first, at most [limit]. Up to build 130 a
 * finished episode was marked with `syncRemote = false`, so its mark never reached the account;
 * right after a successful pull, a key that is still dirty is a mark the account lacks or holds
 * older (the pull merges acknowledge every key the server already matches).
 *
 * "The account lacks it" can also mean another device unmarked it. The deletes a delta pull brings
 * withdraw the marks they supersede ([dirtyWatchedKeysWithdrawnByServerDeletes]), so those are not
 * selected here. Two cases stay out of reach, a known effect on the other devices:
 * - a delete that builds 130/131 consumed before this pass existed;
 * - a snapshot pull, which carries no deletes: a mark is only missing.
 * Marks like these are still pushed, so an episode unmarked on another device can come back as
 * watched there.
 */
internal fun selectDirtyWatchedBacklog(
    items: Map<String, WatchedItem>,
    dirtyKeys: Set<String>,
    limit: Int = WATCHED_BACKLOG_PUSH_LIMIT,
): List<WatchedItem> {
    if (dirtyKeys.isEmpty() || limit <= 0) return emptyList()
    return dirtyKeys
        .mapNotNull { key ->
            items[key]
                ?.takeIf { item -> item.id.isNotBlank() }
                ?.let { item -> key to item.normalizedMarkedAt() }
        }
        .sortedWith(
            compareByDescending<Pair<String, WatchedItem>> { (_, item) -> item.markedAtEpochMs }
                .thenBy { (key, _) -> key },
        )
        .take(limit)
        .map { (_, item) -> item }
}

/**
 * CW sync #2 (review): the dirty Nuvio marks that the server deletes of one delta pull withdraw from
 * sync. [items] and [dirtyKeys] are the local state once the pull has applied those deletes.
 *
 * A dirty mark made before [markedBeforeEpochMs] (the start of that pull) is withdrawn when:
 * - its own key was deleted ([deletedKeys]): the merge keeps the mark, but another device
 *   unmarked that episode after it was made;
 * - or its title was deleted ([deletedContentIds]) and no synced mark of it is left on this
 *   device: the account no longer holds any mark of it, which is what "mark the show unwatched" on
 *   another device looks like. The account only held the episodes that device knew, so marks of
 *   other episodes are withdrawn too. While a synced mark of the title is left, the delete was
 *   about single episodes and the title's other marks are kept.
 *
 * A mark made during the pull is left alone: it is a local change the delete cannot know about.
 *
 * Only the backlog would push such a mark again and mark the episode watched again on the account.
 * The marks stay on this device and are only no longer dirty. No push re-sends them, and the next
 * snapshot pull (which only keeps the dirty marks the server lacks) lets them go, as the account
 * did.
 */
internal fun dirtyWatchedKeysWithdrawnByServerDeletes(
    items: Map<String, WatchedItem>,
    dirtyKeys: Set<String>,
    deletedKeys: Set<String>,
    deletedContentIds: Set<String>,
    markedBeforeEpochMs: Long,
): Set<String> {
    if (dirtyKeys.isEmpty() || (deletedKeys.isEmpty() && deletedContentIds.isEmpty())) return emptySet()
    val titlesGoneFromAccount = deletedContentIds.filterTo(mutableSetOf()) { contentId ->
        items.none { (key, item) -> key !in dirtyKeys && item.id.trim() == contentId }
    }
    return items
        .filter { (key, item) ->
            key in dirtyKeys &&
                item.normalizedMarkedAt().markedAtEpochMs < markedBeforeEpochMs &&
                (key in deletedKeys || item.id.trim() in titlesGoneFromAccount)
        }
        .keys
}

private const val maxRestorableWatchedPayloadChars = 4 * 1024 * 1024

internal fun shouldRestoreWatchedPayload(payloadLength: Int): Boolean =
    payloadLength <= maxRestorableWatchedPayloadChars

object WatchedRepository {
    private data class WatchedRefreshOperation(
        val profileId: Int,
        val profileGeneration: Long,
        val sourceOperation: WatchedSourceOperation,
    )

    private const val watchedItemsPageSize = 900
    private const val watchedItemsDeltaPageSize = 900
    private const val watchedDeltaOperationUpsert = "upsert"
    private const val watchedDeltaOperationDelete = "delete"

    private val accountScopeLock = SynchronizedObject()
    private var accountScopeJob: Job = SupervisorJob()
    private var accountScope = CoroutineScope(accountScopeJob + Dispatchers.Default + uncaughtCoroutineLogger("WatchedRepository"))
    private val log = Logger.withTag("WatchedRepository")
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    private val _uiState = MutableStateFlow(WatchedUiState())
    val uiState: StateFlow<WatchedUiState> = _uiState.asStateFlow()
    private val _fullyWatchedSeriesKeys = MutableStateFlow<Set<String>>(emptySet())
    val fullyWatchedSeriesKeys: StateFlow<Set<String>> = _fullyWatchedSeriesKeys.asStateFlow()

    private var hasLoaded = false
    private var currentProfileId: Int = 1
    private var profileGeneration: Long = 0L
    private var activeSource: WatchProgressSource = WatchProgressSource.NUVIO_SYNC
    private var sourceGeneration: Long = 0L
    private val itemsStore = WatchedItemsStore()
    private var nuvioFullyWatchedSeriesKeys: Set<String> = emptySet()
    private var providerFullyWatchedSeriesKeys: MutableMap<TrackingProviderId, Set<String>> = mutableMapOf()

    /** Alternate-id watched keys reported by the active provider; persisted compacted since eb2d5d3a/3acbe6f2. */
    private val providerExtraWatchedKeys = mutableMapOf<TrackingProviderId, Set<String>>()
    private var nuvioHasLoaded: Boolean = false
    private var loadedProviders: MutableSet<TrackingProviderId> = mutableSetOf()
    private var nuvioHasLoadedRemote: Boolean = false
    private var providersLoadedFromRemote: MutableSet<TrackingProviderId> = mutableSetOf()
    private var lastSuccessfulPushEpochMs: Long = 0L
    private var deltaCursorEventId: Long = 0L
    private var deltaInitialized: Boolean = false
    internal var syncAdapter: WatchedSyncAdapter = SupabaseWatchedSyncAdapter
    private var extraKeysObserverJob: Job? = null
    /** Profiles whose dirty-mark backlog was already pushed (or tried) by this process (#2). */
    private val backlogPushLock = SynchronizedObject()
    private val backlogPushedProfileIds = mutableSetOf<Int>()

    fun ensureLoaded() {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.ensureLoaded()
        TrackingSettingsRepository.ensureLoaded()
        if (!hasLoaded) {
            loadFromDisk(ProfileRepository.activeProfileId)
            activateEffectiveSource(
                effectiveWatchedSource(
                    requestedSource = TrackingSettingsRepository.uiState.value.watchProgressSource,
                    connectedProviderIds = connectedWatchedProviderIds(),
                ),
            )
        }
        startExtraKeysObserverIfNeeded()
    }

    fun onProfileChanged(profileId: Int) {
        if (profileId == currentProfileId && hasLoaded) return
        loadFromDisk(profileId)
    }

    fun clearLocalState() {
        val previousAccountJob = synchronized(accountScopeLock) {
            accountScopeJob.also {
                accountScopeJob = SupervisorJob()
                accountScope = CoroutineScope(accountScopeJob + Dispatchers.Default + uncaughtCoroutineLogger("WatchedRepository"))
            }
        }
        previousAccountJob.cancel()
        stopExtraKeysObserver()
        hasLoaded = false
        currentProfileId = 1
        profileGeneration += 1L
        activeSource = WatchProgressSource.NUVIO_SYNC
        sourceGeneration += 1L
        itemsStore.update { nuvioItems, providerItems, dirtyNuvioKeys, dirtyProviderKeys ->
            nuvioItems.clear()
            providerItems.clear()
            dirtyNuvioKeys.clear()
            dirtyProviderKeys.clear()
        }
        nuvioFullyWatchedSeriesKeys = emptySet()
        providerFullyWatchedSeriesKeys.clear()
        providerExtraWatchedKeys.clear()
        nuvioHasLoaded = false
        loadedProviders.clear()
        nuvioHasLoadedRemote = false
        providersLoadedFromRemote.clear()
        lastSuccessfulPushEpochMs = 0L
        deltaCursorEventId = 0L
        deltaInitialized = false
        // Another account's profiles reuse the same ids: they get their own backlog push.
        synchronized(backlogPushLock) { backlogPushedProfileIds.clear() }
        _fullyWatchedSeriesKeys.value = emptySet()
        _uiState.value = WatchedUiState()
    }

    private fun loadFromDisk(profileId: Int) {
        // Fork: a profile switch lands here without routing through activateEffectiveSource,
        // so stop the observer explicitly — otherwise it stays pinned to the previous
        // currentProfileId until some later source activation happens to cancel it.
        stopExtraKeysObserver()
        currentProfileId = profileId
        profileGeneration += 1L
        activeSource = WatchProgressSource.NUVIO_SYNC
        sourceGeneration += 1L
        hasLoaded = true
        itemsStore.update { nuvioItems, providerItems, dirtyNuvioKeys, dirtyProviderKeys ->
            nuvioItems.clear()
            providerItems.clear()
            dirtyNuvioKeys.clear()
            dirtyProviderKeys.clear()
        }
        nuvioFullyWatchedSeriesKeys = emptySet()
        providerFullyWatchedSeriesKeys.clear()
        providerExtraWatchedKeys.clear()
        nuvioHasLoaded = true
        loadedProviders.clear()
        nuvioHasLoadedRemote = false
        providersLoadedFromRemote.clear()

        val payload = WatchedStorage.loadPayload(profileId).orEmpty().trim()
        if (payload.isNotEmpty()) {
            val storedPayload = if (shouldRestoreWatchedPayload(payload.length)) {
                runCatching {
                    json.decodeFromString<StoredWatchedPayload>(payload)
                }.getOrDefault(StoredWatchedPayload())
            } else {
                WatchedStorage.savePayload(profileId, "")
                StoredWatchedPayload()
            }
            lastSuccessfulPushEpochMs = storedPayload.lastSuccessfulPushEpochMs
            deltaCursorEventId = storedPayload.deltaCursorEventId
            deltaInitialized = storedPayload.deltaInitialized
            val restoredItems = storedPayload.items
                .map(WatchedItem::normalizedMarkedAt)
                .associateBy { watchedItemKey(it.type, it.id, it.season, it.episode) }
            val restoredProviderPayloads = storedPayload.providerPayloads.mapNotNull { (storageId, providerPayload) ->
                TrackingProviderId.fromStorage(storageId)?.let { providerId -> providerId to providerPayload }
            }.toMap()
            itemsStore.update { nuvioItems, providerItems, dirtyNuvioKeys, dirtyProviderKeys ->
                nuvioItems.putAll(restoredItems)
                dirtyNuvioKeys += storedPayload.dirtyWatchedKeys.filter { key -> key in restoredItems }
                restoredProviderPayloads.forEach { (providerId, providerPayload) ->
                    val providerItemsByKey = (providerPayload.items + expandProviderWatchedItems(providerPayload.itemGroups))
                        .map(WatchedItem::normalizedMarkedAt)
                        .associateBy { watchedItemKey(it.type, it.id, it.season, it.episode) }
                    providerItems[providerId] = providerItemsByKey.toMutableMap()
                    dirtyProviderKeys[providerId] = providerPayload.dirtyWatchedKeys
                        .filterTo(mutableSetOf()) { key -> key in providerItemsByKey }
                }
            }
            nuvioFullyWatchedSeriesKeys = storedPayload.fullyWatchedSeriesKeys
            restoredProviderPayloads.forEach { (providerId, providerPayload) ->
                providerFullyWatchedSeriesKeys[providerId] = providerPayload.fullyWatchedSeriesKeys
                providerExtraWatchedKeys[providerId] =
                    providerPayload.extraWatchedKeys + expandExtraWatchedKeys(providerPayload.extraWatchedKeyGroups)
            }
            loadedProviders += restoredProviderPayloads.keys
        } else {
            lastSuccessfulPushEpochMs = 0L
            deltaCursorEventId = 0L
            deltaInitialized = false
            nuvioFullyWatchedSeriesKeys = emptySet()
        }

        publish()
    }

    internal fun activateSource(source: WatchProgressSource): WatchProgressSource {
        if (!hasLoaded) {
            loadFromDisk(ProfileRepository.activeProfileId)
        }
        return activateEffectiveSource(source)
    }

    private fun activateEffectiveSource(source: WatchProgressSource): WatchProgressSource {
        if (activeSource == source) return source
        stopExtraKeysObserver()
        activeSource = source
        sourceGeneration += 1L
        publish()
        startExtraKeysObserverIfNeeded()
        return source
    }

    private fun newRefreshOperation(profileId: Int): WatchedRefreshOperation? {
        if (ProfileRepository.activeProfileId != profileId) return null
        if (!hasLoaded || currentProfileId != profileId) return null
        return WatchedRefreshOperation(
            profileId = profileId,
            profileGeneration = profileGeneration,
            sourceOperation = WatchedSourceOperation(
                source = activeSource,
                generation = sourceGeneration,
            ),
        )
    }

    private fun isActiveOperation(operation: WatchedRefreshOperation): Boolean =
        currentProfileId == operation.profileId &&
            profileGeneration == operation.profileGeneration &&
            ProfileRepository.activeProfileId == operation.profileId &&
            isWatchedSourceOperationCurrent(
                operation = operation.sourceOperation,
                activeSource = activeSource,
                activeGeneration = sourceGeneration,
            )

    suspend fun pullFromServer(profileId: Int) {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.ensureLoaded(profileId)
        TrackingSettingsRepository.ensureLoaded()
        refreshForSource(
            profileId = profileId,
            source = effectiveWatchedSource(
                requestedSource = TrackingSettingsRepository.uiState.value.watchProgressSource,
                connectedProviderIds = connectedWatchedProviderIds(),
            ),
            forceSnapshot = false,
        )
    }

    suspend fun forceSnapshotRefreshFromServer(profileId: Int) {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.ensureLoaded(profileId)
        TrackingSettingsRepository.ensureLoaded()
        refreshForSource(
            profileId = profileId,
            source = effectiveWatchedSource(
                requestedSource = TrackingSettingsRepository.uiState.value.watchProgressSource,
                connectedProviderIds = connectedWatchedProviderIds(),
            ),
            forceSnapshot = true,
        )
    }

    internal suspend fun refreshForSource(
        profileId: Int,
        source: WatchProgressSource,
        forceSnapshot: Boolean = true,
    ): Boolean {
        ensureTrackingProvidersRegistered()
        TrackingProviderRegistry.ensureLoaded(profileId)
        TrackingSettingsRepository.ensureLoaded()
        if (ProfileRepository.activeProfileId != profileId) {
            log.d { "Skipping watched refresh for inactive profile $profileId" }
            return false
        }
        if (!hasLoaded || currentProfileId != profileId) {
            loadFromDisk(profileId)
        }

        val effectiveSource = activateEffectiveSource(source)
        val operation = newRefreshOperation(profileId) ?: return false
        if (effectiveSource.providerId == null) {
            val authState = AuthRepository.state.value
            if (authState !is AuthState.Authenticated || authState.isAnonymous) {
                // Local watched state is authoritative when this account has no Nuvio upstream.
                nuvioHasLoaded = true
                nuvioHasLoadedRemote = true
                publish()
                return true
            }
        }
        return try {
            effectiveSource.providerId?.let { providerId ->
                val provider = TrackingProviderRegistry.watchedProvider(providerId)
                    ?: run {
                        log.w { "Watched provider missing provider=${providerId.storageId} source=$effectiveSource" }
                        return false
                    }
                pullSnapshotFromAdapter(
                    adapter = provider,
                    operation = operation,
                    profileId = profileId,
                    resetDeltaState = true,
                )
            } ?: run {
                val pulled = if (forceSnapshot) {
                    refreshNuvioSnapshot(
                        operation = operation,
                        profileId = profileId,
                    )
                } else {
                    pullSupabaseDeltaFromServer(
                        operation = operation,
                        profileId = profileId,
                    )
                }
                if (pulled) pushDirtyWatchedBacklogOnce(operation)
                pulled
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Failed to refresh watched items from $effectiveSource" }
            false
        }
    }

    private suspend fun refreshNuvioSnapshot(
        operation: WatchedRefreshOperation,
        profileId: Int,
    ): Boolean {
        val cursorBeforeSnapshot = try {
            syncAdapter.getDeltaCursor(profileId)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            null
        }
        if (!isActiveOperation(operation)) return false

        val applied = pullSnapshotFromAdapter(
            adapter = syncAdapter,
            operation = operation,
            profileId = profileId,
            resetDeltaState = cursorBeforeSnapshot == null,
        )
        if (!applied || !isActiveOperation(operation)) return false
        if (cursorBeforeSnapshot != null) {
            deltaCursorEventId = cursorBeforeSnapshot
            deltaInitialized = true
            persist()
        }
        return true
    }

    private suspend fun pullSnapshotFromAdapter(
        adapter: WatchedSyncAdapter,
        operation: WatchedRefreshOperation,
        profileId: Int,
        resetDeltaState: Boolean,
    ): Boolean {
        val serverItems = adapter.pull(
            profileId = profileId,
            pageSize = watchedItemsPageSize,
        )
        val extraWatchedKeys = adapter.pullExtraWatchedKeys(profileId)
        val source = operation.sourceOperation.source
        if (!isActiveOperation(operation)) return false
        itemsStore.update { nuvioItems, providerItems, dirtyNuvioKeys, dirtyProviderKeys ->
            val items = source.providerId
                ?.let { providerId -> providerItems[providerId]?.values.orEmpty() }
                ?: nuvioItems.values
            val dirtyKeys = source.providerId
                ?.let { providerId -> dirtyProviderKeys.getOrPut(providerId, ::mutableSetOf) }
                ?: dirtyNuvioKeys
            val merged = mergeWatchedSnapshot(
                serverItems = serverItems,
                localItems = items.toList(),
                dirtyKeys = dirtyKeys,
                acknowledgeDirtyByPresence = source.providerId != null,
            )
            replaceWatchedItemsForProviderSource(
                source = source,
                nuvioItems = nuvioItems,
                providerItems = providerItems,
                replacement = merged.items,
            )
            dirtyKeys.clear()
            dirtyKeys += merged.dirtyKeys
        }
        adapter.pullFullyWatchedSeriesKeys(profileId)?.let { keys ->
            setFullyWatchedSeriesKeysForSource(source, keys)
        }
        source.providerId?.let { providerId ->
            providerExtraWatchedKeys[providerId] = extraWatchedKeys
            loadedProviders += providerId
            providersLoadedFromRemote += providerId
        } ?: run {
            nuvioHasLoaded = true
            nuvioHasLoadedRemote = true
            if (resetDeltaState) {
                deltaCursorEventId = 0L
                deltaInitialized = false
            }
        }
        publish()
        persist()
        return true
    }

    private suspend fun pullSupabaseDeltaFromServer(
        operation: WatchedRefreshOperation,
        profileId: Int,
    ): Boolean {
        if (!isActiveOperation(operation)) return false
        if (!deltaInitialized) {
            val cursorBeforeSnapshot = try {
                syncAdapter.getDeltaCursor(profileId)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                null
            }
            if (!isActiveOperation(operation)) return false
            if (cursorBeforeSnapshot == null) {
                return pullSnapshotFromAdapter(
                    adapter = syncAdapter,
                    operation = operation,
                    profileId = profileId,
                    resetDeltaState = true,
                )
            }
            val applied = pullSnapshotFromAdapter(
                adapter = syncAdapter,
                operation = operation,
                profileId = profileId,
                resetDeltaState = false,
            )
            if (!applied || !isActiveOperation(operation)) return false
            deltaCursorEventId = cursorBeforeSnapshot
            deltaInitialized = true
            persist()
            return true
        }

        var cursor = deltaCursorEventId
        var changed = false
        // A mark made from here on is a change this pull's deletes cannot know about.
        val pullStartedAtEpochMs = WatchedClock.nowEpochMs()

        while (true) {
            val events = syncAdapter.pullDelta(
                profileId = profileId,
                sinceEventId = cursor,
                limit = watchedItemsDeltaPageSize,
            )
            if (!isActiveOperation(operation)) return false
            if (events.isEmpty()) break

            itemsStore.update { nuvioItems, _, dirtyNuvioKeys, _ ->
                applyWatchedDeltaEvents(
                    targetItems = nuvioItems,
                    dirtyKeys = dirtyNuvioKeys,
                    events = events,
                    withdrawMarkedBeforeEpochMs = pullStartedAtEpochMs,
                )
            }
            cursor = maxOf(cursor, events.maxOf { it.eventId })
            deltaCursorEventId = cursor
            deltaInitialized = true
            changed = true

            if (events.size < watchedItemsDeltaPageSize) break
        }

        if (!isActiveOperation(operation)) return false
        nuvioHasLoaded = true
        val remoteReadinessChanged = !nuvioHasLoadedRemote
        nuvioHasLoadedRemote = true
        if (changed || remoteReadinessChanged) {
            publish()
        }
        if (changed) {
            persist()
        }
        return true
    }

    /**
     * [withdrawMarkedBeforeEpochMs]: the start of the pull. The dirty marks older than it that the
     * page's deletes supersede are withdrawn from sync ([dirtyWatchedKeysWithdrawnByServerDeletes]).
     */
    private fun applyWatchedDeltaEvents(
        targetItems: MutableMap<String, WatchedItem>,
        dirtyKeys: MutableSet<String>,
        events: Collection<WatchedDeltaEvent>,
        withdrawMarkedBeforeEpochMs: Long,
    ) {
        var upsertCount = 0
        var deleteCount = 0
        var removedCount = 0
        var removedByFallbackKeyCount = 0
        var preservedDirtyCount = 0
        var acknowledgedDirtyCount = 0
        var ignoredCount = 0
        val deletedKeys = mutableSetOf<String>()
        val deletedContentIds = mutableSetOf<String>()

        events.forEach { event ->
            val key = watchedItemKey(event.contentType, event.contentId, event.season, event.episode)
            when (event.operation.lowercase()) {
                watchedDeltaOperationUpsert -> {
                    upsertCount += 1
                    val remoteItem = WatchedItem(
                        id = event.contentId,
                        type = event.contentType,
                        name = event.title,
                        season = event.season,
                        episode = event.episode,
                        markedAtEpochMs = normalizeWatchedMarkedAtEpochMs(event.watchedAt),
                    )
                    val localItem = targetItems[key]?.normalizedMarkedAt()
                    if (
                        key in dirtyKeys &&
                        localItem != null &&
                        remoteItem.markedAtEpochMs < localItem.markedAtEpochMs
                    ) {
                        preservedDirtyCount += 1
                    } else {
                        targetItems[key] = remoteItem
                        if (dirtyKeys.remove(key)) {
                            acknowledgedDirtyCount += 1
                        }
                    }
                }
                watchedDeltaOperationDelete -> {
                    deleteCount += 1
                    event.contentId.trim().takeIf(String::isNotEmpty)?.let(deletedContentIds::add)
                    val matchingKey = if (key in targetItems) {
                        key
                    } else {
                        findWatchedItemStableDeleteKey(
                            targetItems = targetItems,
                            contentId = event.contentId,
                            contentType = event.contentType,
                            season = event.season,
                            episode = event.episode,
                        )
                    }
                    if (matchingKey == null) {
                        return@forEach
                    }
                    deletedKeys += matchingKey
                    if (matchingKey in dirtyKeys) {
                        preservedDirtyCount += 1
                        return@forEach
                    }
                    val removedItem = targetItems.remove(matchingKey)
                    if (removedItem != null) {
                        removedCount += 1
                        if (matchingKey != key) {
                            removedByFallbackKeyCount += 1
                        }
                    }
                }
                else -> {
                    ignoredCount += 1
                }
            }
        }

        val withdrawnKeys = dirtyWatchedKeysWithdrawnByServerDeletes(
            items = targetItems,
            dirtyKeys = dirtyKeys,
            deletedKeys = deletedKeys,
            deletedContentIds = deletedContentIds,
            markedBeforeEpochMs = withdrawMarkedBeforeEpochMs,
        )
        dirtyKeys -= withdrawnKeys

        log.i {
            "Applied watched delta events total=${events.size} upserts=$upsertCount deletes=$deleteCount " +
                "removed=$removedCount removedByFallbackKey=$removedByFallbackKeyCount " +
                "preservedDirty=$preservedDirtyCount acknowledgedDirty=$acknowledgedDirtyCount " +
                "withdrawnDirty=${withdrawnKeys.size} ignored=$ignoredCount"
        }
    }

    private fun findWatchedItemStableDeleteKey(
        targetItems: Map<String, WatchedItem>,
        contentId: String,
        contentType: String,
        season: Int?,
        episode: Int?,
    ): String? = targetItems.entries.firstOrNull { (_, item) ->
        item.id == contentId &&
            watchedDeleteTypesCompatible(remoteType = contentType, localType = item.type) &&
            item.season == season &&
            item.episode == episode
    }?.key

    private fun watchedDeleteTypesCompatible(remoteType: String, localType: String): Boolean {
        if (remoteType.equals(localType, ignoreCase = true)) return true
        return remoteType.isSeriesLikeWatchedType() && localType.isSeriesLikeWatchedType()
    }

    private fun itemsForSourceSnapshot(source: WatchProgressSource): List<WatchedItem> =
        itemsStore.read { nuvioItems, providerItems, _, _ ->
            val items = source.providerId
                ?.let { providerId -> providerItems[providerId]?.values.orEmpty() }
                ?: nuvioItems.values
            items.toList()
        }

    private fun fullyWatchedSeriesKeysForSource(source: WatchProgressSource): Set<String> =
        source.providerId
            ?.let { providerId -> providerFullyWatchedSeriesKeys[providerId].orEmpty() }
            ?: nuvioFullyWatchedSeriesKeys

    private fun setFullyWatchedSeriesKeysForSource(
        source: WatchProgressSource,
        keys: Set<String>,
    ) {
        source.providerId?.let { providerId ->
            providerFullyWatchedSeriesKeys[providerId] = keys
        } ?: run {
            nuvioFullyWatchedSeriesKeys = keys
        }
    }

    private fun hasLoadedSource(source: WatchProgressSource): Boolean =
        source.providerId?.let(loadedProviders::contains) ?: nuvioHasLoaded

    fun toggleWatched(item: WatchedItem) {
        ensureLoaded()
        // Takes the itemsStore lock itself; nothing is held here, so the call cannot nest locks.
        val isMarked = isWatched(
            id = item.id,
            type = item.type,
            season = item.season,
            episode = item.episode,
        )
        if (isMarked) {
            unmarkWatched(item)
        } else {
            markWatched(item)
        }
    }

    fun markWatched(item: WatchedItem) {
        markWatched(listOf(item))
    }

    fun markWatched(items: Collection<WatchedItem>) {
        markWatched(items = items, trackerHistorySync = WatchedTrackerHistorySync.Mirror)
    }

    fun markWatchedFromPlaybackCompletion(item: WatchedItem, syncRemote: Boolean = true) {
        markWatched(
            items = listOf(item),
            trackerHistorySync = WatchedTrackerHistorySync.Skip,
            syncRemote = syncRemote,
        )
    }

    private fun markWatched(
        items: Collection<WatchedItem>,
        trackerHistorySync: WatchedTrackerHistorySync,
        syncRemote: Boolean = true,
    ) {
        ensureLoaded()
        if (items.isEmpty()) return
        val source = activeSource
        val markedAt = WatchedClock.nowEpochMs()
        val timestampedItems = items.map { watchedItem ->
            watchedItem.copy(markedAtEpochMs = markedAt)
        }
        itemsStore.update { nuvioItems, providerItems, dirtyNuvioKeys, dirtyProviderKeys ->
            val targetItems = source.providerId
                ?.let { providerId -> providerItems.getOrPut(providerId, ::mutableMapOf) }
                ?: nuvioItems
            val dirtyKeys = source.providerId
                ?.let { providerId -> dirtyProviderKeys.getOrPut(providerId, ::mutableSetOf) }
                ?: dirtyNuvioKeys
            timestampedItems.forEach { watchedItem ->
                val key = watchedItemKey(watchedItem.type, watchedItem.id, watchedItem.season, watchedItem.episode)
                targetItems[key] = watchedItem
                dirtyKeys += key
            }
        }
        publish()
        persist()
        if (syncRemote) {
            pushMarksToServer(
                items = timestampedItems,
                trackerHistorySync = trackerHistorySync,
                source = source,
            )
        }
    }

    fun unmarkWatched(item: WatchedItem) {
        unmarkWatched(listOf(item))
    }

    fun unmarkWatched(
        id: String,
        type: String,
        season: Int? = null,
        episode: Int? = null,
    ) {
        unmarkWatched(
            listOf(
                WatchedItem(
                    id = id,
                    type = type,
                    name = "",
                    season = season,
                    episode = episode,
                    markedAtEpochMs = 0L,
                ),
            ),
        )
    }

    fun unmarkWatched(items: Collection<WatchedItem>) {
        ensureLoaded()
        if (items.isEmpty()) return
        val source = activeSource
        val (removedItems, removedExtraKeys) = itemsStore.update { nuvioItems, providerItems, dirtyNuvioKeys, dirtyProviderKeys ->
            val targetItems = source.providerId
                ?.let { providerId -> providerItems.getOrPut(providerId, ::mutableMapOf) }
                ?: nuvioItems
            val dirtyKeys = source.providerId
                ?.let { providerId -> dirtyProviderKeys.getOrPut(providerId, ::mutableSetOf) }
                ?: dirtyNuvioKeys
            var extraKeysChanged = false
            val removed = items.mapNotNull { watchedItem ->
                val keys = watchedItemKeys(
                    type = watchedItem.type,
                    id = watchedItem.id,
                    season = watchedItem.season,
                    episode = watchedItem.episode,
                )
                source.providerId?.let { providerId ->
                    providerExtraWatchedKeys[providerId]?.let { extraKeys ->
                        val updated = extraKeys - keys
                        if (updated != extraKeys) {
                            providerExtraWatchedKeys[providerId] = updated
                            extraKeysChanged = true
                        }
                    }
                }
                val matchingKey = keys.firstOrNull(targetItems::containsKey) ?: return@mapNotNull null
                targetItems.remove(matchingKey)?.also { dirtyKeys -= matchingKey }
            }
            removed to extraKeysChanged
        }
        if (removedItems.isNotEmpty()) {
            publish()
            persist()
            pushDeleteToServer(items = removedItems, source = source)
        } else if (source.providerId != null) {
            // Nothing matched locally, but the title can still be watched on the provider under an
            // alternate id (that is what `providerExtraWatchedKeys` records). Republish to drop the
            // stale keys, and push the delete so the unmark actually sticks — otherwise the next
            // provider pull re-reports the title as watched and the toggle silently reverts.
            if (removedExtraKeys) {
                publish()
                persist()
            }
            pushDeleteToServer(items = items.toList(), source = source)
        }
    }

    fun isWatched(
        id: String,
        type: String,
        season: Int? = null,
        episode: Int? = null,
    ): Boolean {
        ensureLoaded()
        val source = activeSource
        val keys = watchedItemKeys(type = type, id = id, season = season, episode = episode)
        val stored = itemsStore.read { nuvioItems, providerItems, _, _ ->
            source.providerId?.let { providerId ->
                providerItems[providerId]?.let { itemsByKey -> keys.any(itemsByKey::containsKey) } == true
            } ?: keys.any(nuvioItems::containsKey)
        }
        if (stored) return true
        val providerId = source.providerId ?: return false
        return providerExtraWatchedKeys[providerId]?.let { extraKeys -> keys.any(extraKeys::contains) } == true
    }

    fun isFullyWatchedSeries(id: String, type: String): Boolean {
        val keys = watchedItemKeys(type = type, id = id)
        return keys.any(_fullyWatchedSeriesKeys.value::contains)
    }

    fun reconcileSeriesWatchedState(
        meta: MetaDetails,
        todayIsoDate: String,
        isEpisodeCompleted: (com.nuvio.app.features.details.MetaVideo) -> Boolean = { false },
    ) {
        if (!meta.type.isSeriesLikeWatchedType()) return

        ensureLoaded()
        val shouldMarkSeriesWatched = reconcileFullyWatchedSeriesState(
            meta = meta,
            todayIsoDate = todayIsoDate,
            isEpisodeCompleted = isEpisodeCompleted,
        )
        val seriesWatchedItem = meta.toSeriesWatchedItem()
        val hasSeriesWatchedMarker = isWatched(id = meta.id, type = meta.type)
        if (shouldMarkSeriesWatched) {
            if (!hasSeriesWatchedMarker) {
                markWatched(seriesWatchedItem)
            }
        } else if (hasSeriesWatchedMarker) {
            unmarkWatched(seriesWatchedItem)
        }
    }

    fun reconcileFullyWatchedSeriesState(
        meta: MetaDetails,
        todayIsoDate: String,
        isEpisodeWatched: (MetaVideo) -> Boolean = { episode ->
            isWatched(
                id = meta.id,
                type = meta.type,
                season = episode.season,
                episode = episode.episode,
            )
        },
        isEpisodeCompleted: (MetaVideo) -> Boolean = { false },
    ): Boolean {
        if (!meta.type.isSeriesLikeWatchedType()) return false

        val shouldMarkSeriesWatched = calculateFullyWatchedSeriesState(
            meta = meta,
            todayIsoDate = todayIsoDate,
            isEpisodeWatched = isEpisodeWatched,
            isEpisodeCompleted = isEpisodeCompleted,
        )
        updateFullyWatchedSeriesStates(
            mapOf(watchedItemKey(meta.type, meta.id) to shouldMarkSeriesWatched),
        )
        return shouldMarkSeriesWatched
    }

    internal fun calculateFullyWatchedSeriesState(
        meta: MetaDetails,
        todayIsoDate: String,
        isEpisodeWatched: (MetaVideo) -> Boolean,
        isEpisodeCompleted: (MetaVideo) -> Boolean,
    ): Boolean {
        if (!meta.type.isSeriesLikeWatchedType()) return false

        ensureLoaded()
        return meta.hasWatchedAllMainSeasonEpisodes(todayIsoDate) { episode ->
            isEpisodeWatched(episode) || isEpisodeCompleted(episode)
        }
    }

    fun updateFullyWatchedSeries(
        id: String,
        type: String,
        isFullyWatched: Boolean,
    ) {
        if (!type.isSeriesLikeWatchedType()) return
        ensureLoaded()
        updateFullyWatchedSeriesKey(
            key = watchedItemKey(type, id),
            isFullyWatched = isFullyWatched,
        )
    }

    private fun updateFullyWatchedSeriesKey(
        key: String,
        isFullyWatched: Boolean,
    ) {
        updateFullyWatchedSeriesStates(mapOf(key to isFullyWatched))
    }

    internal fun updateFullyWatchedSeriesStates(states: Map<String, Boolean>) {
        if (states.isEmpty()) return
        ensureLoaded()
        val source = activeSource
        val current = fullyWatchedSeriesKeysForSource(source)
        val updated = current.toMutableSet().apply {
            states.forEach { (key, isFullyWatched) ->
                if (isFullyWatched) add(key) else remove(key)
            }
        }
        if (updated == current) return
        setFullyWatchedSeriesKeysForSource(source = source, keys = updated)
        publish()
        persist()
    }

    private fun pushMarksToServer(
        items: Collection<WatchedItem>,
        trackerHistorySync: WatchedTrackerHistorySync,
        source: WatchProgressSource,
    ) {
        val profileId = currentProfileId
        val operationGeneration = profileGeneration
        accountScopeSnapshot().launch {
            runCatching {
                if (items.isEmpty()) return@runCatching
                val outcome = pushToTargetsForSource(
                    profileId = profileId,
                    items = items,
                    trackerHistorySync = trackerHistorySync,
                    source = source,
                )
                if (shouldAcknowledgeNuvioWatchedPush(source = source, outcome = outcome)) {
                    recordSuccessfulPush(
                        profileId = profileId,
                        operationGeneration = operationGeneration,
                        items = items,
                    )
                }
            }.onFailure { e ->
                log.e(e) { "Failed to push watched items" }
            }
        }
    }

    /**
     * CW sync (REMAINING_FIX #2): once per profile per process, right after a successful Nuvio pull,
     * push the Nuvio marks that are still dirty ([selectDirtyWatchedBacklog]) to the account only —
     * never to a tracker: playback completions reach trackers through their scrobbles. A successful
     * push acknowledges them like any other ([recordSuccessfulPush]); a failed one is logged and
     * tried again on the next launch.
     */
    private fun pushDirtyWatchedBacklogOnce(operation: WatchedRefreshOperation) {
        if (operation.sourceOperation.source.providerId != null || !isActiveOperation(operation)) return
        val profileId = operation.profileId
        val (backlog, dirtyCount) = itemsStore.read { nuvioItems, _, dirtyNuvioKeys, _ ->
            selectDirtyWatchedBacklog(items = nuvioItems, dirtyKeys = dirtyNuvioKeys) to dirtyNuvioKeys.size
        }
        if (!synchronized(backlogPushLock) { backlogPushedProfileIds.add(profileId) }) return
        if (backlog.isEmpty()) return
        log.i {
            "Pushing the watched-mark backlog for profile $profileId: ${backlog.size} of $dirtyCount " +
                "unsynced marks, most recent first"
        }
        val operationGeneration = operation.profileGeneration
        accountScopeSnapshot().launch {
            try {
                syncAdapter.push(profileId = profileId, items = backlog)
                recordSuccessfulPush(
                    profileId = profileId,
                    operationGeneration = operationGeneration,
                    items = backlog,
                )
                log.i { "Pushed the watched-mark backlog for profile $profileId (${backlog.size} marks)" }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.e(error) {
                    "Failed to push the watched-mark backlog for profile $profileId (${backlog.size} marks); " +
                        "it is tried again on the next launch"
                }
            }
        }
    }

    private fun pushDeleteToServer(
        items: Collection<WatchedItem>,
        source: WatchProgressSource,
    ) {
        val profileId = currentProfileId
        accountScopeSnapshot().launch {
            runCatching {
                if (items.isEmpty()) return@runCatching
                deleteFromTargetsForSource(
                    profileId = profileId,
                    items = items,
                    source = source,
                )
            }.onFailure { e ->
                log.e(e) { "Failed to push watched item delete" }
            }
        }
    }

    private fun publish() {
        val (nuvioItems, providerItems) = itemsStore.read { storedNuvioItems, storedProviderItems, _, _ ->
            storedNuvioItems.values.toList() to storedProviderItems.mapValues { (_, itemsByKey) ->
                itemsByKey.values.toList()
            }
        }
        val items = watchedItemsForSource(
            source = activeSource,
            nuvioItems = nuvioItems,
            providerItems = providerItems,
        )
            .map(WatchedItem::normalizedMarkedAt)
            .sortedByDescending { it.markedAtEpochMs }
        val watchedKeys = items.mapTo(linkedSetOf()) {
            watchedItemKey(it.type, it.id, it.season, it.episode)
        }
        // Extra provider keys are alternate ids for items we already hold, so they join the key set
        // without adding items.
        activeSource.providerId?.let { providerId ->
            providerExtraWatchedKeys[providerId]?.let { extraKeys -> watchedKeys += extraKeys }
        }
        _fullyWatchedSeriesKeys.value = fullyWatchedSeriesKeysForSource(activeSource)
        _uiState.value = WatchedUiState(
            items = items,
            watchedKeys = watchedKeys,
            isLoaded = hasLoadedSource(activeSource),
            hasLoadedRemoteItems = activeSource.providerId
                ?.let(providersLoadedFromRemote::contains)
                ?: nuvioHasLoadedRemote,
        )
    }

    /**
     * Observes the active provider's extra watched keys (alternate ids for items we already hold).
     * When the provider's snapshot changes (after mutations, syncs), it re-pulls watched items and
     * re-publishes so `watchedKeys` and `items` stay reactive and current.
     *
     * Provider-neutral: the adapter is resolved through [TrackingProviderRegistry], never a
     * hardcoded provider. Adapters whose `observeExtraWatchedKeys` is still the default empty flow
     * simply never emit.
     */
    private fun startExtraKeysObserverIfNeeded() {
        if (extraKeysObserverJob != null) return
        val providerId = activeSource.providerId ?: return
        val adapter = TrackingProviderRegistry.connectedWatchedProviders()
            .firstOrNull { it.providerId == providerId } ?: return
        extraKeysObserverJob = accountScopeSnapshot().launch {
            adapter.observeExtraWatchedKeys(currentProfileId)
                .distinctUntilChanged()
                .collectLatest { extraKeys ->
                    val keysChanged = extraWatchedKeysChanged(
                        previous = providerExtraWatchedKeys[providerId],
                        current = extraKeys,
                    )
                    if (keysChanged) {
                        val freshItems = watchedProviderRefreshOrNull(
                            refresh = {
                                adapter.pull(
                                    profileId = currentProfileId,
                                    pageSize = watchedItemsPageSize,
                                )
                            },
                            onFailure = { error ->
                                log.w(error) { "Failed to refresh watched items from ${providerId.storageId}" }
                            },
                        ) ?: return@collectLatest
                        providerExtraWatchedKeys[providerId] = extraKeys
                        itemsStore.update { _, providerItems, _, dirtyProviderKeys ->
                            val dirtyKeys = dirtyProviderKeys.getOrPut(providerId, ::mutableSetOf)
                            val merged = mergeWatchedSnapshot(
                                serverItems = freshItems,
                                localItems = providerItems[providerId]?.values.orEmpty().toList(),
                                dirtyKeys = dirtyKeys,
                                acknowledgeDirtyByPresence = true,
                            )
                            providerItems[providerId] = merged.items.toMutableMap()
                            dirtyKeys.clear()
                            dirtyKeys += merged.dirtyKeys
                        }
                        loadedProviders += providerId
                        providersLoadedFromRemote += providerId
                        publish()
                        persist()
                    }
                }
        }
    }

    private fun stopExtraKeysObserver() {
        extraKeysObserverJob?.cancel()
        extraKeysObserverJob = null
    }

    private fun persist() {
        val storedPayload = itemsStore.read { nuvioItems, providerItems, dirtyNuvioKeys, dirtyProviderKeys ->
            val providerIds = buildSet {
                addAll(providerItems.keys)
                addAll(dirtyProviderKeys.keys)
                addAll(providerFullyWatchedSeriesKeys.keys)
                addAll(providerExtraWatchedKeys.keys)
                addAll(loadedProviders)
            }
            StoredWatchedPayload(
                items = nuvioItems.values
                    .map(WatchedItem::normalizedMarkedAt)
                    .sortedByDescending { it.markedAtEpochMs },
                fullyWatchedSeriesKeys = nuvioFullyWatchedSeriesKeys,
                lastSuccessfulPushEpochMs = lastSuccessfulPushEpochMs,
                deltaCursorEventId = deltaCursorEventId,
                deltaInitialized = deltaInitialized,
                dirtyWatchedKeys = dirtyNuvioKeys.toSet(),
                providerPayloads = providerIds.associate { providerId ->
                    val items = providerItems[providerId]
                        .orEmpty()
                        .values
                        .map(WatchedItem::normalizedMarkedAt)
                    providerId.storageId to StoredProviderWatchedPayload(
                        itemGroups = compactProviderWatchedItems(items),
                        fullyWatchedSeriesKeys = providerFullyWatchedSeriesKeys[providerId].orEmpty(),
                        extraWatchedKeyGroups = compactExtraWatchedKeys(
                            providerExtraWatchedKeys[providerId].orEmpty(),
                        ),
                        dirtyWatchedKeys = dirtyProviderKeys[providerId].orEmpty(),
                    )
                },
            )
        }
        WatchedStorage.savePayload(
            currentProfileId,
            json.encodeToString(storedPayload),
        )
    }

    private fun recordSuccessfulPush(
        profileId: Int,
        operationGeneration: Long,
        items: Collection<WatchedItem>,
    ) {
        if (profileId != currentProfileId || operationGeneration != profileGeneration) return
        val latestPushed = items
            .asSequence()
            .map { item -> normalizeWatchedMarkedAtEpochMs(item.markedAtEpochMs) }
            .maxOrNull()
            ?: return
        val changed = itemsStore.update { nuvioItems, _, dirtyNuvioKeys, _ ->
            val acknowledgedDirtyKeys = acknowledgeSuccessfulWatchedPush(
                currentItems = nuvioItems,
                dirtyKeys = dirtyNuvioKeys,
                pushedItems = items,
            )
            val updatedLastSuccessfulPushEpochMs = maxOf(lastSuccessfulPushEpochMs, latestPushed)
            if (
                acknowledgedDirtyKeys == dirtyNuvioKeys &&
                updatedLastSuccessfulPushEpochMs == lastSuccessfulPushEpochMs
            ) {
                false
            } else {
                dirtyNuvioKeys.clear()
                dirtyNuvioKeys += acknowledgedDirtyKeys
                lastSuccessfulPushEpochMs = updatedLastSuccessfulPushEpochMs
                true
            }
        }
        if (changed) persist()
    }

    private suspend fun pushToTargetsForSource(
        profileId: Int,
        items: Collection<WatchedItem>,
        trackerHistorySync: WatchedTrackerHistorySync,
        source: WatchProgressSource,
    ): WatchedPushOutcome {
        var nuvioSyncSucceeded = false
        val succeededTrackerProviderIds = linkedSetOf<TrackingProviderId>()
        if (source.providerId == null) {
            try {
                syncAdapter.push(profileId = profileId, items = items)
                nuvioSyncSucceeded = true
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.e(error) { "Failed to push watched items to Nuvio Sync" }
            }
        }

        if (trackerHistorySync == WatchedTrackerHistorySync.Mirror) {
            TrackingProviderRegistry.connectedWatchedProviders().forEach { provider ->
                try {
                    provider.push(profileId = profileId, items = items)
                    succeededTrackerProviderIds += provider.providerId
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    log.e(error) { "Failed to push watched items to ${provider.providerId.storageId}" }
                }
            }
        }
        return WatchedPushOutcome(
            nuvioSyncSucceeded = nuvioSyncSucceeded,
            succeededTrackerProviderIds = succeededTrackerProviderIds,
        )
    }

    private suspend fun deleteFromTargetsForSource(
        profileId: Int,
        items: Collection<WatchedItem>,
        source: WatchProgressSource,
    ) {
        if (source.providerId == null) {
            try {
                syncAdapter.delete(profileId = profileId, items = items)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.e(error) { "Failed to delete watched items from Nuvio Sync" }
            }
        }

        TrackingProviderRegistry.connectedWatchedProviders().forEach { provider ->
            try {
                provider.delete(profileId = profileId, items = items)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.e(error) { "Failed to delete watched items from ${provider.providerId.storageId}" }
            }
        }
    }

    private fun accountScopeSnapshot(): CoroutineScope =
        synchronized(accountScopeLock) {
            accountScope
        }

    private fun connectedWatchedProviderIds(): Set<TrackingProviderId> =
        TrackingProviderRegistry.connectedWatchedProviders()
            .mapTo(linkedSetOf()) { provider -> provider.providerId }
}

// Fork: public (upstream: internal) — composeApp WatchedRepositoryTest consumes these cross-module.
data class WatchedSnapshotMerge(
    val items: Map<String, WatchedItem>,
    val dirtyKeys: Set<String>,
)

fun mergeWatchedSnapshot(
    serverItems: Collection<WatchedItem>,
    localItems: Collection<WatchedItem>,
    dirtyKeys: Set<String>,
    acknowledgeDirtyByPresence: Boolean = false,
): WatchedSnapshotMerge {
    val remoteByKey = serverItems
        .map(WatchedItem::normalizedMarkedAt)
        .associateBy { watchedItemKey(it.type, it.id, it.season, it.episode) }
        .toMutableMap()
    val localByKey = localItems
        .map(WatchedItem::normalizedMarkedAt)
        .associateBy { watchedItemKey(it.type, it.id, it.season, it.episode) }
    val remainingDirtyKeys = dirtyKeys
        .filterTo(mutableSetOf()) { key -> key in localByKey }

    remainingDirtyKeys.toList().forEach { key ->
        val localItem = localByKey.getValue(key)
        val remoteItem = remoteByKey[key]
        if (remoteItem == null) {
            remoteByKey[key] = localItem
        } else if (acknowledgeDirtyByPresence || remoteItem.markedAtEpochMs >= localItem.markedAtEpochMs) {
            remainingDirtyKeys -= key
        } else {
            remoteByKey[key] = localItem
        }
    }

    return WatchedSnapshotMerge(
        items = remoteByKey,
        dirtyKeys = remainingDirtyKeys,
    )
}

// Fork: public (upstream: internal) — composeApp WatchedRepositoryTest consumes this cross-module.
fun acknowledgeSuccessfulWatchedPush(
    currentItems: Map<String, WatchedItem>,
    dirtyKeys: Set<String>,
    pushedItems: Collection<WatchedItem>,
): Set<String> {
    val remainingDirtyKeys = dirtyKeys.toMutableSet()
    pushedItems
        .map(WatchedItem::normalizedMarkedAt)
        .forEach { pushedItem ->
            val key = watchedItemKey(
                type = pushedItem.type,
                id = pushedItem.id,
                season = pushedItem.season,
                episode = pushedItem.episode,
            )
            val currentItem = currentItems[key]?.normalizedMarkedAt()
            if (currentItem == null || currentItem.markedAtEpochMs <= pushedItem.markedAtEpochMs) {
                remainingDirtyKeys -= key
            }
        }
    return remainingDirtyKeys
}

fun effectiveWatchedSource(
    requestedSource: WatchProgressSource,
    connectedProviderIds: Set<TrackingProviderId>,
): WatchProgressSource = effectiveWatchProgressSource(
    requestedSource = requestedSource,
    isProviderAuthenticated = { providerId -> providerId in connectedProviderIds },
)

/** Fork shim over the provider-set overload — composeApp's WatchedRepositoryTest. */
fun effectiveWatchedSource(
    requestedSource: WatchProgressSource,
    isTraktAuthenticated: Boolean,
): WatchProgressSource = effectiveWatchedSource(
    requestedSource = requestedSource,
    connectedProviderIds = if (isTraktAuthenticated) setOf(TrackingProviderId.TRAKT) else emptySet(),
)

/** Fork shim — composeApp's WatchedModelsTest. */
fun shouldUseTraktWatchedSync(
    isAuthenticated: Boolean,
    source: WatchProgressSource,
): Boolean = effectiveWatchedSource(
    requestedSource = source,
    isTraktAuthenticated = isAuthenticated,
) == WatchProgressSource.TRAKT

private fun String.isSeriesLikeWatchedType(): Boolean =
    trim().lowercase() in setOf("series", "show", "tv", "tvshow")
