package com.nuvio.app.features.upcoming

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.time.daysUntilEpisodeRelease
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.AddonsUiState
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.tmdb.TmdbSettings
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import com.nuvio.app.features.watchprogress.WatchProgressClock
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.concurrent.Volatile
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

// Fork: tvOS-first Home "Upcoming" row (no upstream twin).
//
// Resolves, for every show the user follows (watch progress + Library), the next episode airing
// within [UpcomingEpisodesHorizonDays] and publishes them as one sorted list for the Home row.
//
// Shape mirrors EpisodeReleaseNotificationsRepository's sweep (bounded fan-out over
// MetaDetailsRepository.fetch after the addon manifests are ready) — that repository is the
// notification-emitting twin of this one; keep the two in step if the sweep rules change.
//
// State is IN-MEMORY ONLY (a 6h per-show cache); nothing is persisted, so there is deliberately no
// AccountDataStores entry — the account wipe and profile switch reset it via clearLocalState() /
// onProfileChanged() from TvOsProviderInstaller.
object UpcomingEpisodesRepository {
    private const val METADATA_FETCH_CONCURRENCY = 4
    private const val MANIFEST_WAIT_TIMEOUT_MS = 10_000L
    private const val SHOW_SET_DEBOUNCE_MS = 1_500L
    private const val PER_SHOW_CACHE_TTL_MS = 6L * 60L * 60L * 1_000L
    private const val DAY_ROLLOVER_MIN_DELAY_MS = 60_000L
    private const val DAY_ROLLOVER_MAX_DELAY_MS = 30L * 60L * 1_000L
    private const val MS_PER_DAY = 24L * 60L * 60L * 1_000L

    private val log = Logger.withTag("UpcomingEpisodes")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("UpcomingEpisodes"))
    private val refreshMutex = Mutex()
    /** Synchronous (not a suspend Mutex): profile-change/wipe must clear the cache BEFORE returning
     *  so a following ensureStarted() can never read the previous scope's entries. */
    private val cacheLock = SynchronizedObject()

    private val _uiState = MutableStateFlow(UpcomingEpisodesUiState())
    val uiState: StateFlow<UpcomingEpisodesUiState> = _uiState.asStateFlow()

    private class CachedShow(
        val item: UpcomingEpisodeItem?,
        val fetchedAtEpochMs: Long,
        /** Local day the entry was resolved for. A MISS is only trustworthy on that day — an
         *  episode 15 days out enters the horizon overnight, so misses go stale at rollover. */
        val computedForIsoDate: String,
    )

    @Volatile
    private var observerJob: Job? = null
    @Volatile
    private var dayRolloverJob: Job? = null
    /** The latest refresh() pass — tracked so stop() can cancel it (off means no sweeps). */
    @Volatile
    private var refreshJob: Job? = null
    @Volatile
    private var lastRefs: List<UpcomingShowRef> = emptyList()
    /** Local calendar day the last published pass was computed for (rollover detection). */
    @Volatile
    private var lastComputedTodayIsoDate: String? = null
    /** Ready-provider signature (ordered) the cache's entries were resolved under (guarded by [cacheLock]). */
    private var cacheProviderSignature: List<String>? = null
    /** Bumped by clear/profile-change so an in-flight pass never publishes into the new scope. */
    @Volatile
    private var generation = 0
    private val cacheByShowKey = HashMap<String, CachedShow>()

    /** Idempotent. Loads the two source repositories and starts following their show sets. */
    fun ensureStarted() {
        if (observerJob?.isActive == true) return
        LibraryRepository.ensureLoaded()
        WatchProgressRepository.ensureLoaded()
        observerJob = scope.launch { observeShowSet() }
        if (dayRolloverJob?.isActive != true) {
            dayRolloverJob = scope.launch { watchDayRollover() }
        }
    }

    /**
     * Re-run the sweep against the last known show set. `force = false` honours the per-show
     * cache (cheap — re-derives day counts after a calendar rollover without refetching);
     * `force = true` refetches every show.
     */
    fun refresh(force: Boolean) {
        val refs = lastRefs
        refreshJob?.cancel()
        refreshJob = scope.launch {
            recompute(
                refs = refs,
                force = force,
                generation = generation,
                providerSignature = providerSignature(AddonRepository.uiState.value, TmdbSettingsRepository.uiState.value),
            )
        }
    }

    /**
     * Enabled add-ons whose manifest has loaded, IN CONFIGURED ORDER — `MetaDetailsRepository.fetch`
     * tries providers in that order, so a reorder changes which provider answers and must count as
     * a provider change (Codex round 6).
     */
    private fun readyAddonSignature(state: AddonsUiState): List<String> =
        state.addons
            .filter { it.enabled && it.manifest != null }
            .map { it.manifestUrl }

    /**
     * TMDB enrichment shapes what `MetaDetailsRepository.fetch` returns (fallback metas, language
     * for titles/artwork), so its settings are part of the provider signature:
     * any change is a non-growth change → full cache clear + re-sweep.
     */
    private fun tmdbSignature(settings: TmdbSettings): String =
        "tmdb:" + listOf(
            settings.enabled,
            // Key identity, not the key: a replaced (e.g. revoked→valid) key must re-sweep, but
            // the secret itself never sits in a signature that could end up in a log.
            settings.apiKey.trim().hashCode(),
            settings.language,
            settings.useEpisodes,
            settings.useArtwork,
            settings.useBasicInfo,
        ).joinToString(",")

    /** Ordered provider signature: TMDB fingerprint first, then the ready add-ons in priority order. */
    private fun providerSignature(addons: AddonsUiState, tmdb: TmdbSettings): List<String> =
        listOf(tmdbSignature(tmdb)) + readyAddonSignature(addons)

    /**
     * Stops observing the source repositories (the Home row was disabled, or Home went away).
     * The per-show cache and last published state are kept so re-enabling is instant and cheap;
     * an in-flight pass is cancelled with the observer.
     */
    fun stop() {
        observerJob?.cancel()
        observerJob = null
        dayRolloverJob?.cancel()
        dayRolloverJob = null
        refreshJob?.cancel()
        refreshJob = null
    }

    fun onProfileChanged() {
        resetState()
        val wasObserving = observerJob?.isActive == true
        observerJob?.cancel()
        // A standalone refresh (midnight ticker, Home re-entry) mid-flight for the OLD profile
        // holds refreshMutex; cancel it or the new profile's first pass queues behind it.
        refreshJob?.cancel()
        refreshJob = null
        // Restart (rather than keep) the observer so its distinct-key comparison starts empty and
        // the new profile's first emission always runs a pass.
        observerJob = if (wasObserving) scope.launch { observeShowSet() } else null
    }

    fun clearLocalState() {
        stop()
        resetState()
    }

    /** Synchronous end to end — by the time this returns, no old-scope entry is readable. */
    private fun resetState() {
        generation++
        lastRefs = emptyList()
        lastComputedTodayIsoDate = null
        synchronized(cacheLock) {
            cacheByShowKey.clear()
            cacheProviderSignature = null
        }
        _uiState.value = UpcomingEpisodesUiState()
    }

    /**
     * Home can stay mounted across midnight with none of the observed flows emitting, so the
     * countdown labels (TOMORROW → TODAY) and the "episode has now aired, show its successor"
     * transition need their own trigger. Wakes at (roughly) the next local midnight — clamped so
     * a DST shift costs at most a 30-minute-late relabel — and refreshes only if the local day
     * actually changed since the last pass; the per-show cache makes that refresh cheap.
     */
    private suspend fun watchDayRollover() {
        while (true) {
            val today = CurrentDateProvider.todayIsoDate()
            val nowEpochMs = WatchProgressClock.nowEpochMs()
            val nextMidnightEpochMs = CurrentDateProvider.localStartOfDayEpochMs(today)?.plus(MS_PER_DAY)
            val untilMidnightMs = nextMidnightEpochMs?.minus(nowEpochMs) ?: DAY_ROLLOVER_MAX_DELAY_MS
            delay((untilMidnightMs + 2_000L).coerceIn(DAY_ROLLOVER_MIN_DELAY_MS, DAY_ROLLOVER_MAX_DELAY_MS))
            val computedFor = lastComputedTodayIsoDate
            if (computedFor != null && CurrentDateProvider.todayIsoDate() != computedFor) {
                refresh(force = false)
            }
        }
    }

    private class SweepTrigger(
        val refs: List<UpcomingShowRef>,
        /** See [providerSignature] — the meta providers/settings a pass resolves under. */
        val providerSignature: List<String>,
    ) {
        val key: Pair<Set<String>, List<String>> get() = refs.map { it.key }.toSet() to providerSignature
    }

    @OptIn(FlowPreview::class)
    private suspend fun observeShowSet() {
        combine(
            // BUG-76: `followedShows`, NOT `uiState.entries` — the latter is scoped to the active
            // watch-progress source, so flipping that source to a provider with no history emptied
            // half this seed and hid a row that only depends on the Library.
            WatchProgressRepository.followedShows,
            LibraryRepository.uiState,
            AddonRepository.uiState,
            TmdbSettingsRepository.uiState,
        ) { progress, library, addons, tmdb ->
            SweepTrigger(
                refs = collectUpcomingShowRefs(progress, library.items),
                providerSignature = providerSignature(addons, tmdb),
            )
        }
            .debounce(SHOW_SET_DEBOUNCE_MS)
            // Playback publishes progress every few seconds; the SHOW set almost never changes on
            // those emissions, so key on it — the sweep must not re-run per progress tick. Add-on
            // readiness and TMDB settings ARE part of the key: a manifest that loads after a pass
            // ran (or after the bounded manifest wait timed out), or a TMDB key/language change,
            // re-runs the sweep so late/changed providers still fill the row (Codex rounds 2/7).
            .distinctUntilChangedBy { trigger -> trigger.key }
            .collectLatest { trigger ->
                lastRefs = trigger.refs
                recompute(
                    refs = trigger.refs,
                    force = false,
                    generation = generation,
                    providerSignature = trigger.providerSignature,
                )
            }
    }

    private suspend fun recompute(
        refs: List<UpcomingShowRef>,
        force: Boolean,
        generation: Int,
        providerSignature: List<String>,
    ) {
        refreshMutex.withLock {
            if (generation != this.generation) return
            val todayIsoDate = CurrentDateProvider.todayIsoDate()
            if (refs.isEmpty()) {
                lastComputedTodayIsoDate = todayIsoDate
                _uiState.value = UpcomingEpisodesUiState(items = emptyList(), isLoading = false, hasLoaded = true)
                return
            }
            _uiState.value = _uiState.value.copy(isLoading = true)

            // Provider signature changed. Pure growth (add-on installed/enabled, or a manifest
            // finished loading — existing providers keep their relative order): cached MISSES
            // were resolved without the new provider, so drop them; HITS are real provider data
            // and stay (a full clear would refetch every show on each manifest that lands during
            // cold start). Anything else (add-on removed/disabled, or priority reordered): hits
            // may have come from a vanished or now-lower-priority provider — clear everything.
            synchronized(cacheLock) {
                val previous = cacheProviderSignature
                if (previous != providerSignature) {
                    if (previous != null) {
                        // Only additions strictly AFTER the previous providers keep hits — an
                        // insertion ahead of them changes who answers first (Codex round 7).
                        val pureGrowth = providerSignature.size > previous.size &&
                            providerSignature.take(previous.size) == previous
                        if (pureGrowth) {
                            cacheByShowKey.entries.removeAll { (_, cached) -> cached.item == null }
                        } else {
                            cacheByShowKey.clear()
                        }
                    }
                    cacheProviderSignature = providerSignature
                }
            }

            AddonRepository.initialize()
            // A pass that starts before the manifests are in can only see fallback providers;
            // its results are published (something beats nothing) but NOT cached, so the re-run
            // triggered by add-on readiness (observeShowSet) fetches for real.
            val manifestsReady = withTimeoutOrNull(MANIFEST_WAIT_TIMEOUT_MS) {
                AddonRepository.awaitManifestsLoaded()
            } != null

            val semaphore = Semaphore(METADATA_FETCH_CONCURRENCY)
            // Structured (children of THIS call, not of the repository scope) so cancelling the
            // observer — stop()/onProfileChanged() — also cancels the in-flight fetches.
            val items = coroutineScope {
                refs.map { ref ->
                    async {
                        semaphore.withPermit {
                            resolveShow(ref, todayIsoDate, force, generation, cacheResults = manifestsReady)
                        }
                    }
                }.awaitAll()
            }.filterNotNull()

            if (generation != this.generation) return
            lastComputedTodayIsoDate = todayIsoDate
            // Single publish per pass — partial publishes would reflow the row under focus.
            _uiState.value = UpcomingEpisodesUiState(
                items = publishableUpcomingItems(items),
                isLoading = false,
                hasLoaded = true,
            )
        }
    }

    private suspend fun resolveShow(
        ref: UpcomingShowRef,
        todayIsoDate: String,
        force: Boolean,
        generation: Int,
        cacheResults: Boolean,
    ): UpcomingEpisodeItem? {
        val nowEpochMs = WatchProgressClock.nowEpochMs()
        if (!force) {
            val cached = synchronized(cacheLock) { cacheByShowKey[ref.key] }
            if (cached != null && nowEpochMs - cached.fetchedAtEpochMs < PER_SHOW_CACHE_TTL_MS) {
                val item = cached.item
                if (item == null) {
                    // A miss holds for the day it was computed; the next day the horizon has
                    // moved and the show must be asked again.
                    if (cached.computedForIsoDate == todayIsoDate) return null
                } else {
                    // Calendar rollover: re-derive the day count from the cached air date rather
                    // than refetching; only refetch once the cached episode has fallen into the
                    // past (its successor may now be the upcoming one).
                    val daysUntil = daysUntilEpisodeRelease(todayIsoDate, item.airDateIso)
                    if (daysUntil != null && daysUntil >= 0) {
                        return if (daysUntil > UpcomingEpisodesHorizonDays) null else item.copy(daysUntilAir = daysUntil)
                    }
                }
            }
        }

        // `cacheResult = false`: this sweep must not pin 60 metas into the shared cache. It DOES
        // still read an entry Detail already cached for the same show — deliberately: the row then
        // agrees with what Detail shows, and re-fetching every just-opened show would double meta
        // traffic. That shared cache is wiped with the account (TvOsAccountDataCleaner) and is the
        // same path EpisodeReleaseNotificationsRepository sweeps through; staleness there is a
        // MetaDetailsRepository property, not this row's.
        val meta = try {
            MetaDetailsRepository.fetch(type = ref.type, id = ref.id, cacheResult = false)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w { "Failed to resolve metadata for ${ref.type}:${ref.id}: ${error.message}" }
            null
        }
        // Keep whatever we had (within TTL) rather than dropping the card on a transient failure.
        if (meta == null) {
            val cached = synchronized(cacheLock) { cacheByShowKey[ref.key] }
            return cached?.item?.let { item ->
                val daysUntil = daysUntilEpisodeRelease(todayIsoDate, item.airDateIso) ?: return null
                if (daysUntil in 0..UpcomingEpisodesHorizonDays) item.copy(daysUntilAir = daysUntil) else null
            }
        }

        val item = selectUpcomingEpisode(meta = meta, todayIsoDate = todayIsoDate)
        if (cacheResults) {
            synchronized(cacheLock) {
                // A wipe/profile switch mid-pass must not leak this show into the next scope's cache.
                if (generation == this.generation) {
                    cacheByShowKey[ref.key] = CachedShow(
                        item = item,
                        fetchedAtEpochMs = nowEpochMs,
                        computedForIsoDate = todayIsoDate,
                    )
                }
            }
        }
        return item
    }
}
