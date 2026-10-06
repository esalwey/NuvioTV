package com.nuvio.app.features.home

import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.sync.LaunchSyncSignal
import com.nuvio.app.core.sync.LaunchSyncSignal.LaunchSyncState
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.catalog.CatalogTarget
import com.nuvio.app.features.catalog.fetchCatalogPage
import com.nuvio.app.features.collection.Collection
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.collection.CollectionSource
import com.nuvio.app.features.collection.TmdbCollectionSourceResolver
import com.nuvio.app.features.collection.catalogRouteKey
import com.nuvio.app.features.collection.findCollectionCatalog
import com.nuvio.app.features.tmdb.TmdbMetadataService
import com.nuvio.app.features.tmdb.TmdbPreviewEnrichment
import com.nuvio.app.features.tmdb.TmdbSettings
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.trakt.TraktPublicListSourceResolver
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlin.math.absoluteValue
import kotlin.random.Random
import kotlin.time.TimeSource
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

object HomeRepository {
    private val log = Logger.withTag("HomeRepository")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("HomeRepository"))
    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    /**
     * Swift-facing snapshot accessors (beta.18, Codex r2 bootstrap fix): `StateFlow.value` is not
     * reachable through the ObjC export, so the no-sources add-on bootstrap route reads the current
     * publish and the launch-sync state here instead of guessing at interop names.
     */
    val currentUiState: HomeUiState get() = _uiState.value
    val launchSyncRunning: Boolean
        get() = LaunchSyncSignal.state.value == LaunchSyncSignal.LaunchSyncState.Running

    /**
     * Codex beta.18 r4 (P1): the gate's OWN settled semantics — `Idle` while a launch sync is still
     * expected is NOT settled (the burst has not started yet), exactly as [syncSettled] reads it.
     * The Swift no-sources bootstrap route holds on this, never on `launchSyncRunning` alone.
     */
    val launchSyncSettled: Boolean
        get() = syncSettled(LaunchSyncSignal.state.value, launchSyncExpected())

    private var activeJob: Job? = null
    private var activeRequestKey: String? = null
    private var currentRequestKey: String? = null

    /**
     * BUG-86 (Codex branch review round 7): whether a catalog fan-out is actually running, i.e.
     * the REAL load state, as opposed to the [HomeUiState.isLoading] that gets published.
     *
     * The two are not the same while the hero commit gate holds. A held publish reports
     * `isLoading = true` whatever the load is doing (see [publishedIsLoading]), because the rows it
     * republishes are the previous, empty ones and reporting "done, nothing here" would paint the
     * empty state (or, after a partial failure, the error state and its Retry) for the second or
     * two before the gate releases. Every publish that is not the fan-out's own used to re-derive
     * its load state from `_uiState.value.isLoading`, so it read that forced value back: once the
     * fan-out finished under an armed gate, `true` was the only value any later publish could
     * carry, the release included. A profile whose catalogs failed or came back empty then sat on
     * the loading placeholder for the rest of the session, because nothing republishes with a
     * literal `false` after the fan-out that set it.
     *
     * Written only by [refresh] (true when it starts a fan-out, false when that fan-out ends or
     * there is nothing to fetch) and [clear]; read under [heroSelectionLock] by every publish, and
     * written under it too so the value a publish reads is the one the load path last wrote.
     */
    private var catalogLoadInProgress: Boolean = false
    private var currentDefinitions: List<HomeCatalogDefinition> = emptyList()
    private var cachedSections: Map<String, HomeCatalogSection> = emptyMap()
    private var cachedCollectionHeroItems: List<MetaPreview> = emptyList()
    /** BUG-42: the catalog hero RANKING last computed (the carousel is its first
     *  HOME_HERO_ITEM_LIMIT entries — see [stableHeroSelection]). Kept across
     *  request keys AND forced refreshes on purpose: at launch the addon set arrives progressively
     *  and tvOS's HomeViewModel calls `refresh(force = true)` on every step (as do the Settings
     *  panes and the back-online path) — none of those means "give me a new hero", and every one
     *  of them is exactly when the head must NOT move. Reset only by [clear] (profile switch /
     *  sign-out); a new process reshuffles by itself. Items that leave the pool still drop out. */
    private var lastCatalogHeroSelection: List<MetaPreview> = emptyList()
    /** Guards [lastCatalogHeroSelection]/[heroResetRequested] AND serializes every publish (see
     *  [publishCurrentState]): publishes run on the repo's Default scope while an explicit reset or
     *  [clear] arrives from the main thread (Codex gate 8). */
    private val heroSelectionLock = SynchronizedObject()
    /** BUG-42 probe support (read by tvOS's `[HomeHero] publish` line): how many times the ranking
     *  was reset (clear/explicit reset) and its current size — tells "reshuffled from empty" apart
     *  from "items dropped out of the pool" in a log pull. */
    private var heroRankingResets = 0
    /** BUG-42: true until the first [refresh] of this session (or after [clear]). Before it, no
     *  catalog load exists yet — `isLoading` is false only because the addon manifests haven't
     *  arrived — and the collection fallback must not fill the hero just to be replaced by the
     *  catalog hero a second later (sim run 2026-08-18: `rank=0` heroes on the first publishes). */
    private var awaitingFirstRefresh = true
    /** Bounds [awaitingFirstRefresh]: a collection-only profile (no add-on with a loaded manifest)
     *  never gets a [refresh], so the gate lifts itself after this grace and the collection hero
     *  publishes (Codex gate 8). Catalog-bearing profiles refresh well inside it. */
    private var firstRefreshGraceJob: Job? = null
    /** Generation for [firstRefreshGraceJob]: bumped by [clear] so a grace that already passed its
     *  cancellation check can't lift the NEXT profile's gate (Codex gate 8). */
    private var firstRefreshGraceGeneration = 0
    /**
     * The live probe string. Prefer [HomeUiState.heroRankingDebugSnapshot] when describing a
     * PUBLISHED state: this getter answers for the repository as it is right now, which on the
     * frontend is one main-thread hop later than the state being logged.
     */
    val heroRankingDebug: String
        get() = synchronized(heroSelectionLock) { heroRankingDebugLocked() }

    /** [heroRankingDebug] without taking the lock, for callers that already hold it. */
    private fun heroRankingDebugLocked(): String {
        val gate = when (heroGateState) {
            HeroGateState.Idle -> "idle"
            HeroGateState.Armed -> "held"
            HeroGateState.Released -> "released:${heroGateReleaseReason ?: "?"}"
        }
        val hold = when {
            heroEnrichmentHoldExpired -> "expired"
            heroEnrichmentHoldJob?.isActive == true -> "held"
            else -> "clear"
        }
        val sync = when (LaunchSyncSignal.state.value) {
            LaunchSyncState.Idle -> "idle"
            LaunchSyncState.NotApplicable -> "na"
            LaunchSyncState.Running -> "running"
            LaunchSyncState.Settled -> "settled"
        }
        return "resets=$heroRankingResets rank=${lastCatalogHeroSelection.size} " +
            "resetReq=$heroResetRequested awaitingFirst=$awaitingFirstRefresh " +
            "gate=$gate hold=$hold sync=$sync " +
            "sources=$heroGateSourcesSettled/$heroGateSourcesTracked " +
            "gateWait=$heroGateWaiting " +
            "head=${committedHeadKey ?: "-"} prune=$lastPruneCount " +
            "rearm=$heroGateRearms " +
            // BUG-86 hero-off rows (beta.18), append-only: on a "Show Hero" OFF launch the whole
            // `gate=` field reads `released:heroOff` from the first evaluation onwards, so it can
            // no longer say anything about what Home is actually still waiting for. These two do:
            // `rowsWait=sync` is the hold working, `settled`/`timeout` are the two ways it ends,
            // and `n/a` means the rows were never independently gated on this launch.
            "rowsWait=${rowsGateReason ?: HeroGateRowsWait.NONE} rowsWaitMs=$rowsGateElapsedMs"
    }

    private var collectionHeroJob: Job? = null
    private var collectionHeroRequestKey: String? = null
    private var lastPublishedCatalogHeroEmpty: Boolean = true
    private var lastErrorMessage: String? = null
    private var heroEnrichmentOverlay: Map<String, TmdbPreviewEnrichment> = emptyMap()
    private var heroEnrichmentAttempted: Set<String> = emptySet()
    /**
     * Items whose enrichment fetch is running right now. Dedup is PER ITEM, not per batch: the hero
     * set changes between catalog batches, and a batch-keyed dedup that cancels the running fetch on
     * every set change never resolves a held publish (BUG-42 deadlock) — it just restarts the work.
     */
    private var heroEnrichmentInFlight: Set<String> = emptySet()
    /**
     * Serializes every read-modify-write of the three sets above (Codex review): concurrent
     * per-batch fetch jobs on Dispatchers.Default would otherwise interleave their completions and
     * silently drop another job's overlay additions — leaving keys stuck in [heroEnrichmentInFlight],
     * which the dedup then excludes from refetching forever (hero pinned raw past the timeout).
     */
    private val heroEnrichmentMutex = Mutex()
    /** Parent of every in-flight enrichment fetch, so invalidation cancels them all in one call. */
    private var heroEnrichmentFetchParent: Job = SupervisorJob()
    private var heroEnrichmentHoldJob: Job? = null
    /** Bumped by every [releaseHeroEnrichmentHold]; a hold timer only acts if its era is current. */
    private var heroEnrichmentHoldGeneration: Long = 0
    /**
     * True once a held hero publish hit [HERO_ENRICHMENT_HOLD_TIMEOUT_MS]. Sticky until the hold
     * resolves cleanly (or settings/refresh invalidate it) so a stalled TMDB can never re-arm the
     * hold publish after publish and keep the hero region empty.
     */
    private var heroEnrichmentHoldExpired: Boolean = false

    // ---------------------------------------------------------------------------------------
    // BUG-86 (Wave H): the hero commit gate. See HeroCommitGate.kt for the decision table and
    // publishCurrentStateLocked for how a held publish differs from a committed one.
    // ---------------------------------------------------------------------------------------

    /** Idle until the first catalog-bearing [refresh], Armed until the gate releases, then Released
     *  for the rest of the session (only [clear] returns it to Idle). Guarded by [heroSelectionLock]. */
    private var heroGateState: HeroGateState = HeroGateState.Idle

    /**
     * When the gate armed. A MONOTONIC mark rather than a wall-clock stamp: the gate's whole job is
     * to bound a launch window, and a clock correction landing mid-launch (NTP on a TV that just
     * woke up) would otherwise either expire the gate instantly or hang it past its timeout.
     */
    private var heroGateArmedAt: TimeSource.Monotonic.ValueTimeMark? = null

    /**
     * When the FIRST publish of this [HeroGateState.Idle] era was evaluated, i.e. the start of the
     * pre-first-refresh hold. Monotonic for the same reason as [heroGateArmedAt], and it is what
     * [decideIdleHeroGate] measures its budget from: a profile whose enabled add-ons declare no
     * catalogs never reaches [armHeroCommitGateLocked], so it has no [heroGateArmedAt] to bound the
     * hold with. Stamped lazily on first use rather than at construction so it tracks the launch
     * the user is actually watching; cleared by [clear], which is the only way back to Idle.
     */
    private var heroGateIdleSince: TimeSource.Monotonic.ValueTimeMark? = null

    /** [HeroGateReason] value the gate released with, surfaced in [heroRankingDebug]. */
    private var heroGateReleaseReason: String? = null

    /** Per definition key, whether this load's fetch of it Loaded or Failed. Both settle the key. */
    private var catalogOutcomes: Map<String, CatalogOutcome> = emptyMap()

    /** The committed head's [MetaPreview.stableKey]. Pinned to index 0 by [pinCommittedHead]. */
    private var committedHeadKey: String? = null

    /**
     * The frozen hero payloads, keyed by [MetaPreview.stableKey]. After the gate releases, every
     * committed item is served from HERE, as the SAME instance, so a later enrichment or re-fetch
     * cannot repaint the hero's name/logo/banner. The only mutation allowed is the one-time silent
     * gap-fill of an EMPTY description or genres (see [withCommittedGapFill]).
     */
    private var committedHeroPayloads: Map<String, MetaPreview> = emptyMap()

    /**
     * Item [MetaPreview.stableKey] to the definition key of the catalog it came from. Hole A: a
     * previously selected hero item is retained while its ORIGIN catalog is still in
     * [currentDefinitions], instead of only while a load happens to be in flight.
     */
    private var heroItemOrigins: Map<String, String> = emptyMap()

    /** Collector on the two gate inputs that live outside this repository (launch sync state and
     *  pending addon manifests). Cancelled when the gate releases and by [clear]. */
    private var gateInputsJob: Job? = null

    /** One-shot [HERO_COMMIT_GATE_TIMEOUT_MS] timer, generation guarded like the enrichment hold. */
    private var heroGateTimeoutJob: Job? = null
    private var heroGateGeneration: Long = 0

    /** Set only by [resetHeroSelection]/[resetHeroSelectionAround]. Deliberately NOT the shared
     *  [heroResetRequested] flag, which the collection-hero invalidation also sets: a collection
     *  re-key during the launch burst must not release the gate. */
    private var heroGateResetRequested: Boolean = false

    /** Probe counters for [heroRankingDebug] (`sources=settled/tracked`). */
    private var heroGateSourcesSettled: Int = 0
    private var heroGateSourcesTracked: Int = 0

    /**
     * The [HeroGateWait] value from the LAST gate evaluation, surfaced as `gateWait=` in
     * [heroRankingDebug]. Deliberately not cleared on release: on a `released:timeout` line it is
     * the whole diagnosis, naming the input that was still outstanding when the budget ran out.
     * `sources=n/n gateWait=sources` in particular is the shape the settled-count probe alone
     * cannot show: every TRACKED key settled while an unresolved persisted key kept the gate
     * waiting on a manifest.
     */
    private var heroGateWaiting: String = HeroGateWait.NONE

    /** How many cached sections the last [refresh] pruned (`prune=` in [heroRankingDebug]). */
    private var lastPruneCount: Int = 0

    /**
     * How many times the gate re-armed after a [HeroGateReason.NO_SOURCES] release
     * (`rearm=` in [heroRankingDebug]). Normally 0; 1 on a slow-addon profile whose manifests
     * landed after the first-refresh grace lifted. Anything above 1 in a photo means catalogs are
     * appearing and disappearing under Home, which is a different bug from this one.
     */
    private var heroGateRearms: Int = 0

    // ---------------------------------------------------------------------------------------
    // BUG-86 hero-off rows (beta.18): the ROWS half of the gate, for the two hero reasons that
    // release without consulting an input. See HeroCommitGate.kt's `decideHeroGate` KDoc for why
    // `heroOff`/`noSources` must not open the rows with the hero, and `publishCurrentStateLocked`
    // for how a rows-held publish differs from a fully released one.
    // ---------------------------------------------------------------------------------------

    /** False while the rows are held AFTER the hero decision released. Guarded by [heroSelectionLock]. */
    private var rowsGateReleased: Boolean = true

    /** [HeroGateRowsWait] value from the last rows evaluation, surfaced as `rowsWait=`. */
    private var rowsGateReason: String? = null

    /**
     * Milliseconds since the first evaluation of this gate era, as of the last evaluation
     * (`rowsWaitMs=`). Also what [armRowsGateTimeoutLocked] subtracts from the budget, so the rows
     * hold is bounded by [HERO_COMMIT_GATE_TIMEOUT_MS] from the FIRST evaluation rather than from
     * whichever publish happened to release the hero.
     */
    private var rowsGateElapsedMs: Long = 0

    /**
     * The `heroEnabled` value in force when the rows were last held. A runtime "Show Hero" toggle
     * moves it, and that is a user action taken while looking at Home: the rows open immediately
     * rather than making the user watch out the rest of the burst budget after their own tap.
     */
    private var rowsHeldUnderHeroEnabled: Boolean = true
    /**
     * Codex beta.18 r3 (P2): `heroEnabled` as it read when the gate was armed (or first evaluated).
     * A `heroOff` decision whose baseline was `true` is a RUNTIME toggle by the user, not a hero-off
     * launch, and must not inherit the launch-sync rows hold — `applyRowsGateDecisionLocked`
     * releases it with [HeroGateRowsWait.TOGGLE].
     */
    private var rowsHoldBaselineHeroEnabled: Boolean? = null

    /** The rows' own [HERO_COMMIT_GATE_TIMEOUT_MS] backstop, generation-guarded like the hero's. */
    private var rowsGateTimeoutJob: Job? = null

    /** Idempotency key for [applyCurrentSettings]: settings + tmdb + gate state + cached keys. */
    private var lastAppliedSettingsSignature: String? = null

    fun refresh(addons: List<ManagedAddon>, force: Boolean = false) {
        val activeAddons = addons.enabledAddons()
        val requests = buildHomeCatalogDefinitions(activeAddons)
        // Hole E: the cache is keyed by the STABLE definition key now. `requestKey` keeps the
        // cacheKey join, so a real manifest change is still a new request identity (new hero seed,
        // fresh fetch) while a cosmetic addon-state flip no longer prunes fetched content.
        val requestKey = requests.joinToString(separator = "|", transform = HomeCatalogDefinition::cacheKey)

        // Hole B: the prune, the launch gate, the gate arm and the isLoading flip are ONE atomic
        // step under the publish lock. They used to run unsynchronized ahead of `isLoading = true`,
        // so a publish from the load scope could evaluate against a pruned cache with isLoading
        // still false and drop the hero head, then reseed `heroRandom` from the new requestKey.
        val proceed = synchronized(heroSelectionLock) {
            val previousDefinitions = currentDefinitions
            currentDefinitions = requests
            val requestKeys = requests.mapTo(mutableSetOf(), HomeCatalogDefinition::key)
            val cachedBefore = cachedSections.size
            cachedSections = cachedSections.filterKeys(requestKeys::contains)
            lastPruneCount = cachedBefore - cachedSections.size
            catalogOutcomes = catalogOutcomes.filterKeys(requestKeys::contains)
            currentRequestKey = requestKey

            // The REAL load state, not the published one: a duplicate refresh is only a no-op
            // while this request's fan-out is genuinely still running.
            if (!force && activeRequestKey == requestKey && catalogLoadInProgress) {
                false
            } else if (!force && isMetadataOnlyDefinitionChange(previousDefinitions, requests)) {
                // Hole E follow-on (Codex branch review round 6): an add-on RENAME reaches this
                // point. It moves the trigger signature but not a single cache key, so every
                // section above is still valid content under a new caption. Adopting the new
                // definitions and republishing is the whole fix: the fan-out below would re-fetch
                // every catalog, flip `isLoading` and re-arm the commit gate to change one string.
                // Nothing here prunes, so no row is rebuilt; `requestKey` is unchanged, so the hero
                // seed, the ranking and the pinned head come out of the publish identical.
                log.i { "refresh() metadata-only definition change; republishing ${requests.size} catalogs without a re-fetch" }
                publishCurrentStateLocked(requestKey = requestKey)
                false
            } else {
                activeRequestKey = requestKey
                // A new load is a new hero, so it gets a fresh hold budget: a timeout burnt on the
                // previous request must not force this one's first hero commit to publish raw
                // metadata.
                releaseHeroEnrichmentHold()

                // BUG-42: the launch gate lifts only on a CATALOG-BEARING refresh. A manifest-less
                // or catalog-less add-on becoming ready first must not let the collection fallback
                // in ahead of the catalog hero (Codex gate 8). Collection-only profiles are covered
                // by the grace.
                if (requests.isNotEmpty()) {
                    awaitingFirstRefresh = false
                    firstRefreshGraceJob?.cancel()
                    firstRefreshGraceJob = null
                    catalogLoadInProgress = true
                    armHeroCommitGateLocked()
                    // copy() drops the body-property probe snapshot (see
                    // [HomeUiState.heroRankingDebugSnapshot]); re-stamp it so this isLoading flip
                    // does not publish a state whose probe line reads as absent.
                    _uiState.update { previous ->
                        previous.copy(isLoading = true, errorMessage = null).also { next ->
                            next.heroRankingDebugSnapshot = heroRankingDebugLocked()
                        }
                    }
                }
                true
            }
        }
        if (!proceed) return

        if (requests.isEmpty()) {
            armFirstRefreshGrace()
            activeJob?.cancel()
            activeJob = null
            activeRequestKey = null
            cachedSections = emptyMap()
            catalogOutcomes = emptyMap()
            lastErrorMessage = null
            // The flag and the publish that reads it go under one lock acquisition: a publish from
            // the load scope must never see the pair half-updated.
            synchronized(heroSelectionLock) {
                catalogLoadInProgress = false
                publishCurrentStateLocked(requestKey = requestKey)
            }
            ensureCollectionHeroFallback(
                addons = activeAddons,
                forceRefresh = force,
                refreshSources = true,
                requestKey = requestKey,
            )
            return
        }

        activeJob?.cancel()
        activeJob = scope.launch {
            val prioritizedRequests = prioritizeDefinitions(
                definitions = requests,
                snapshot = HomeCatalogSettingsRepository.snapshot(),
            )
            val loadedSections = linkedMapOf<String, HomeCatalogSection>().apply {
                putAll(cachedSections)
            }
            var firstErrorMessage: String? = null
            var batchIndex = 0

            prioritizedRequests.chunked(HOME_CATALOG_FETCH_BATCH_SIZE).forEach { batch ->
                if (activeRequestKey != requestKey) return@launch
                val results = batch.map { request ->
                    async {
                        request to runCatching {
                            request.toSection(forceRefresh = force)
                        }
                    }
                }.awaitAll()

                if (activeRequestKey != requestKey) return@launch

                results.mapNotNull { (request, result) ->
                    result.getOrNull()?.let { section -> request.key to section }
                }.forEach { (definitionKey, section) ->
                    loadedSections[definitionKey] = section
                }
                // Gate input: every hero-source catalog must reach a TERMINAL outcome before the
                // hero may commit. A failed fetch settles the key just like a loaded one, otherwise
                // one dead add-on would pin every launch on the gate timeout.
                val gateArmed = synchronized(heroSelectionLock) {
                    catalogOutcomes = catalogOutcomes + results.associate { (request, result) ->
                        request.key to if (result.isSuccess) CatalogOutcome.Loaded else CatalogOutcome.Failed
                    }
                    heroGateState == HeroGateState.Armed
                }
                if (firstErrorMessage == null) {
                    firstErrorMessage = results.firstNotNullOfOrNull { (_, result) ->
                        result.exceptionOrNull()?.message
                    }
                }
                cachedSections = loadedSections.toMap()
                lastErrorMessage = firstErrorMessage
                if (shouldPublishAfterBatch(batchIndex = batchIndex, gateArmed = gateArmed)) {
                    publishCurrentState(requestKey = requestKey)
                }
                batchIndex++
            }

            if (activeRequestKey != requestKey) return@launch

            cachedSections = loadedSections.toMap()
            lastErrorMessage = firstErrorMessage
            activeRequestKey = null
            // The fan-out is over even when the gate still holds: the flag records THAT, and
            // [publishedIsLoading] decides what the held publish reports. Under one lock
            // acquisition with the publish for the same reason as the empty-request path above.
            synchronized(heroSelectionLock) {
                catalogLoadInProgress = false
                publishCurrentStateLocked(requestKey = requestKey)
            }
            ensureCollectionHeroFallback(
                addons = activeAddons,
                forceRefresh = force,
                refreshSources = true,
                requestKey = requestKey,
            )
        }
    }

    /**
     * BUG-42: an EXPLICIT Hero Sources change (Settings) is the one thing that should redraw the
     * hero from scratch; background settings sync and addon-set growth go through
     * [applyCurrentSettings]/[refresh] and keep the head (see [lastCatalogHeroSelection]).
     */
    fun resetHeroSelection() {
        synchronized(heroSelectionLock) {
            lastCatalogHeroSelection = emptyList()
            heroResetRequested = true
            heroRankingResets++
            clearHeroCommitLocked()
        }
    }

    /**
     * BUG-42: reset + a settings mutation + its republish as ONE unit — no publish from the load
     * scope can slip between the preference write and the reset (Codex gate 8). [block] runs with
     * the reset already applied and may itself publish (the lock is reentrant).
     */
    fun resetHeroSelectionAround(block: () -> Unit) {
        synchronized(heroSelectionLock) {
            lastCatalogHeroSelection = emptyList()
            heroResetRequested = true
            heroRankingResets++
            clearHeroCommitLocked()
            block()
        }
    }

    /**
     * BUG-86 (Wave H): an explicit Hero Sources change is one of the four things allowed to move a
     * committed head (the others: hero switched off, the head's origin catalog leaving the
     * definition set, and [clear]). The pin and the frozen payloads go with it, and the gate is
     * told so that a reset arriving mid-launch releases it immediately instead of making the user
     * watch a spinner after their own tap.
     */
    private fun clearHeroCommitLocked() {
        committedHeadKey = null
        committedHeroPayloads = emptyMap()
        heroGateResetRequested = true
    }

    /**
     * Idle to Armed on the FIRST catalog-bearing refresh, plus the ONE re-arm below. A later
     * refresh (addon fan-in, Settings, back-online) never re-arms otherwise: post-commit the head
     * is immutable, so re-arming could only hold the rows again for no benefit.
     *
     * The exception is a [HeroGateReason.NO_SOURCES] release. That release is a claim about the
     * profile ("no catalog can ever supply a hero here"), not a hero commit, and a catalog-bearing
     * refresh arriving afterwards is proof the claim was wrong. It is the shape of a slow-addon
     * profile: the Idle budget runs out (or [FIRST_REFRESH_GRACE_MS] lifts) while every add-on
     * manifest is still in flight, the gate releases `noSources`, and the manifests land a second
     * later. Without the re-arm the catalog hero that arrives afterwards is never committed at
     * all: the gate stayed Released, and if a collection hero happened to be cached at the release
     * instant then
     * [committedHeroPayloads] is non-empty, so the re-freeze in [serveCommittedHeroItemsLocked]
     * does not fire either. The head is left unpinned and free to move on every later publish,
     * which is exactly the doubled hero this gate exists to prevent.
     *
     * Re-arming DISCARDS the provisional commit (the frozen collection payloads and the pin) so
     * the catalog hero can commit and pin as if it were the first: keeping a pin that was chosen
     * under "there are no catalogs" would pin the wrong item forever. The rows hold applies again
     * with it, which costs nothing here: a `noSources` release means there were no definitions, so
     * there were no rows on screen to flash away, and holding keeps the partially fetched catalog
     * order from publishing ahead of the commit.
     */
    private fun armHeroCommitGateLocked() {
        val rearmingAfterNoSources = heroGateShouldRearm(heroGateState, heroGateReleaseReason)
        if (heroGateState != HeroGateState.Idle && !rearmingAfterNoSources) return
        if (rearmingAfterNoSources) {
            heroGateRearms += 1
            committedHeadKey = null
            committedHeroPayloads = emptyMap()
            log.i { "heroGateRearmed reason=${HeroGateReason.NO_SOURCES} rearm=$heroGateRearms" }
        }
        heroGateState = HeroGateState.Armed
        heroGateArmedAt = TimeSource.Monotonic.markNow()
        heroGateReleaseReason = null
        heroGateWaiting = HeroGateWait.SOURCES
        // BUG-86 hero-off rows (beta.18), the `noSources` re-arm: this era's rows answer goes with
        // the release it was taken under. While Armed the rows are held by the HERO hold anyway
        // (branch 2 of publishCurrentStateLocked), and the release that ends this era decides them
        // afresh — against a budget that now runs from the re-arm, not from the discarded claim.
        rowsGateReleased = true
        rowsGateReason = null
        rowsGateElapsedMs = 0
        rowsHeldUnderHeroEnabled = true
        catalogOutcomes = emptyMap()
        heroGateGeneration += 1
        val generation = heroGateGeneration
        rowsGateTimeoutJob?.cancel()
        rowsGateTimeoutJob = null
        heroGateTimeoutJob?.cancel()
        heroGateTimeoutJob = scope.launch {
            delay(HERO_COMMIT_GATE_TIMEOUT_MS)
            // Generation token, same pattern as armHeroEnrichmentHold: a timer whose cancellation
            // raced its own completion must not expire a LATER gate era.
            if (generation != heroGateGeneration) return@launch
            publishCurrentState(requestKey = currentRequestKey)
        }
        startGateInputsObserverLocked()
    }

    /**
     * The two gate inputs that live outside this repository: the launch sync burst's state and
     * whether an enabled addon manifest can still produce a catalog definition. Neither of them
     * publishes anything by itself, so without this collector a gate waiting on them would only be
     * re-evaluated by an unrelated publish, or at the timeout.
     *
     * Both collectors deliberately take the CURRENT value too (no `drop(1)`). The dropped-first
     * design assumed the value at collection start had already been folded into an arming publish,
     * and it had not: [armHeroCommitGateLocked] only flips `isLoading`, and these collectors are
     * launched onto a `Dispatchers.Default` that the catalog fan-out and the enrichment fetches are
     * saturating at exactly that moment. Under load (a busy simulator host, a cold TV) the
     * collector can first run SECONDS after it was launched, by which time the transition it exists
     * to observe has already happened, and `drop(1)` then discarded the launch-sync settle, or the
     * manifest flip, that was the gate's last outstanding input, and the launch could only end at
     * the timeout. Taking the current value costs one extra held publish (an equal [HomeUiState],
     * which the StateFlow suppresses) and makes the race impossible.
     */
    private fun startGateInputsObserverLocked() {
        if (gateInputsJob?.isActive == true) return
        gateInputsJob = scope.launch {
            launch {
                // A StateFlow already suppresses equal consecutive values.
                LaunchSyncSignal.state.collect { republishForGate() }
            }
            launch {
                AddonRepository.uiState
                    .map { state -> state.addons.hasUnresolvedEnabledManifests() }
                    .distinctUntilChanged()
                    .collect { republishForGate() }
            }
            launch {
                // The THIRD outside input, and the one the original pair missed: the sync term of
                // the readiness conjunction is not `syncState` alone, it is
                // `syncState x launchSyncExpected()` (see [launchSyncExpected]), and the second
                // factor is auth. On a signed-out cold launch whose session restore resolves after
                // the catalog fan-out has already finished, the sync state never moves (it stays
                // Idle: no burst is coming) and no manifest flips, so neither collector above
                // fires; AuthState.Loading -> Unauthenticated is the ONLY event that makes Idle
                // readable as "settled", and without a collector on it nothing re-evaluated the
                // gate and the launch could only end at the timeout.
                //
                // Mapped to the boolean rather than collected raw: an Authenticated state carries
                // tokens and a user object that can be rewritten by a refresh without changing
                // whether a burst is expected, and each of those would otherwise cost a publish.
                AuthRepository.state
                    .map { state -> state.launchSyncExpected() }
                    .distinctUntilChanged()
                    .collect { republishForGate() }
            }
        }
    }

    /**
     * BUG-86 hero-off rows (beta.18): widened past `state == Armed`. On a "Show Hero" OFF launch
     * the hero decision releases on the FIRST evaluation, so the gate is never Armed and the old
     * guard turned every one of these callbacks into a no-op — including the launch-sync collector
     * that is the only thing which can tell the rows the burst has landed. The rows hold would then
     * have had exactly one exit, its own timeout, which is a 4 s "Setting up your catalogs…" on
     * every hero-off launch instead of the ~1 s the burst actually takes.
     */
    private fun republishForGate() {
        val shouldPublish = synchronized(heroSelectionLock) {
            heroGateState == HeroGateState.Armed || !rowsGateReleased
        }
        if (!shouldPublish) return
        publishCurrentState(requestKey = currentRequestKey)
    }

    /**
     * BUG-86 hero-off rows (beta.18): the rows' own [HERO_COMMIT_GATE_TIMEOUT_MS] backstop, armed
     * on the publish that releases the hero with the rows still held.
     *
     * [delayMs] is the budget MINUS what the era has already spent ([rowsGateElapsedMs]), so the
     * bound is 4 s from the first evaluation and not 4 s from whichever publish happened to take
     * the hero decision. Generation-token guarded on [heroGateGeneration], the same era token the
     * hero timeout uses, so a re-arm or a [clear] whose cancellation raced this job's own
     * completion can never expire a later era's rows.
     */
    private fun armRowsGateTimeoutLocked(delayMs: Long) {
        val generation = heroGateGeneration
        rowsGateTimeoutJob?.cancel()
        rowsGateTimeoutJob = scope.launch {
            if (delayMs > 0) delay(delayMs)
            if (generation != heroGateGeneration) return@launch
            republishForGate()
        }
    }

    private fun cancelGateWatchersLocked() {
        heroGateGeneration += 1
        heroGateTimeoutJob?.cancel()
        heroGateTimeoutJob = null
        rowsGateTimeoutJob?.cancel()
        rowsGateTimeoutJob = null
        gateInputsJob?.cancel()
        gateInputsJob = null
    }

    /** Gathers the live inputs and asks [decideHeroGate]. Must run under [heroSelectionLock]. */
    private fun evaluateHeroGateLocked(
        snapshot: HomeCatalogSettingsSnapshot,
        candidateEmpty: Boolean,
        enrichmentPending: Int,
    ): HeroGateDecision {
        // Before the first catalog-bearing refresh there is nothing to decide: the collection
        // fallback is still held by awaitingFirstRefresh, and releasing "noSources" here would
        // commit an empty hero on every launch, before the add-on manifests have even arrived.
        // BOUNDED by the gate's own budget, measured from the first publish of this Idle era (see
        // [decideIdleHeroGate]): a profile whose enabled add-ons declare no catalogs never arms the
        // gate's timer, so without this the hold could only end at the first-refresh grace.
        // BUG-86 hero-off rows (beta.18): the rows clock. Stamped on the FIRST evaluation of this
        // era whatever the gate state is, not only while Idle, because the rows hold has to be
        // bounded on a "Show Hero" OFF profile that arms the gate normally AND on a collection-only
        // one that never arms it at all. `heroGateArmedAt` wins when it exists (it restarts the
        // budget on the `noSources` re-arm, which is the whole point of that re-arm); `idleSince`
        // is the fallback for the era that never gets one. Both monotonic, same reason as the hero
        // clock: a mid-launch NTP correction must not expire or hang the hold.
        val idleSince = heroGateIdleSince ?: TimeSource.Monotonic.markNow().also {
            heroGateIdleSince = it
        }
        val rowsElapsedMs = (heroGateArmedAt ?: idleSince).elapsedNow().inWholeMilliseconds
        rowsGateElapsedMs = rowsElapsedMs
        // The baseline is stamped HERE, on the first evaluation after arming (or in the Idle era),
        // from the snapshot the caller already holds — never by calling `snapshot()` under
        // `heroSelectionLock`, which no other path in this file does.
        if (rowsHoldBaselineHeroEnabled == null) rowsHoldBaselineHeroEnabled = snapshot.heroEnabled

        if (heroGateState == HeroGateState.Idle) {
            val idleHold = decideIdleHeroGate(
                awaitingFirstRefresh = awaitingFirstRefresh,
                idleElapsedMs = idleSince.elapsedNow().inWholeMilliseconds,
                timeoutMs = HERO_COMMIT_GATE_TIMEOUT_MS,
            )
            if (idleHold != null) {
                heroGateWaiting = idleHold.waiting
                return idleHold
            }
        }
        // Still Idle past the Idle hold above means no catalog-bearing refresh ever happened, which
        // is precisely the decision the first-refresh grace (and now the Idle budget escape) exists
        // to make. Report it to the gate as "no definitions, no manifests coming" so it releases
        // `noSources` instead of holding a collection-only Home behind a timer it has no way to
        // start (the gate's timeout is armed by the first catalog-bearing refresh, which by
        // definition never came).
        val idleAfterGrace = heroGateState == HeroGateState.Idle
        val knownDefinitionKeys = if (idleAfterGrace) {
            emptySet()
        } else {
            currentDefinitions.mapTo(LinkedHashSet(), HomeCatalogDefinition::key)
        }
        val heroSourceKeys = HomeCatalogSettingsRepository.heroSourceKeys()
        val trackedKeys = heroSourceKeys.intersect(knownDefinitionKeys)
        heroGateSourcesTracked = trackedKeys.size
        heroGateSourcesSettled = trackedKeys.count { key -> key in catalogOutcomes }
        val elapsedMs = if (heroGateState == HeroGateState.Armed) {
            heroGateArmedAt?.elapsedNow()?.inWholeMilliseconds ?: 0L
        } else {
            0L
        }
        val decision = decideHeroGate(
            HeroGateInputs(
                heroEnabled = snapshot.heroEnabled,
                heroSourceKeys = heroSourceKeys,
                knownDefinitionKeys = knownDefinitionKeys,
                outcomes = catalogOutcomes,
                manifestsPending = !idleAfterGrace &&
                    AddonRepository.uiState.value.addons.hasUnresolvedEnabledManifests(),
                syncState = LaunchSyncSignal.state.value,
                launchSyncExpected = launchSyncExpected(),
                enrichmentPending = enrichmentPending,
                candidateEmpty = candidateEmpty,
                heroSourcesAllOff = HomeCatalogSettingsRepository.heroSourceSelectionIsAllOff(),
                resetRequested = heroGateResetRequested,
                elapsedMs = elapsedMs,
                rowsElapsedMs = rowsElapsedMs,
                timeoutMs = HERO_COMMIT_GATE_TIMEOUT_MS,
            )
        )
        heroGateWaiting = decision.waiting
        return decision
    }

    /**
     * BUG-86 hero-off rows (beta.18): the rows gate on every publish AFTER the hero decision.
     *
     * The hero decision is taken exactly once, so there is no second [HeroGateDecision] to read the
     * rows answer off; the same two terms are applied here instead (via the shared [decideRowsGate],
     * so the two call sites cannot drift). Must run under [heroSelectionLock].
     */
    private fun refreshRowsGateLocked(snapshot: HomeCatalogSettingsSnapshot) {
        if (rowsGateReleased) return
        val elapsedMs = (heroGateArmedAt ?: heroGateIdleSince)?.elapsedNow()?.inWholeMilliseconds ?: 0L
        rowsGateElapsedMs = elapsedMs

        // A user action outranks the wait, exactly as HeroGateReason.RESET does for the hero: an
        // explicit Hero Sources change, or the "Show Hero" toggle moving under a hold that was
        // taken while it was off. In both cases the user is looking at Home right now and must not
        // be made to watch out the rest of the burst budget after their own tap.
        if (heroGateResetRequested || snapshot.heroEnabled != rowsHeldUnderHeroEnabled) {
            rowsGateReleased = true
            rowsGateReason = HeroGateRowsWait.NONE
            cancelGateWatchersLocked()
            return
        }

        val rows = decideRowsGate(
            syncSettled = syncSettled(LaunchSyncSignal.state.value, launchSyncExpected()),
            rowsElapsedMs = elapsedMs,
            timeoutMs = HERO_COMMIT_GATE_TIMEOUT_MS,
        )
        rowsGateReleased = rows.released
        rowsGateReason = rows.waiting
        if (rows.released) {
            log.i { "rowsGateReleased reason=${rows.waiting} elapsedMs=$elapsedMs" }
            cancelGateWatchersLocked()
        }
    }

    /**
     * BUG-86 hero-off rows (beta.18): applies the rows half of the publish that RELEASES the hero.
     * Must run under [heroSelectionLock].
     */
    private fun applyRowsGateDecisionLocked(decision: HeroGateDecision, heroEnabled: Boolean) {
        if (!decision.rowsReleased && !heroEnabled && rowsHoldBaselineHeroEnabled == true) {
            // Codex beta.18 r3 (P2): Show Hero was ON when this gate armed and is OFF now — the user
            // toggled it mid-launch. Apply immediately; the launch-sync hold is for launches.
            log.i { "rowsGateReleased reason=${HeroGateRowsWait.TOGGLE} (Show Hero toggled off while armed)" }
            rowsGateReleased = true
            rowsGateReason = HeroGateRowsWait.TOGGLE
            cancelGateWatchersLocked()
            return
        }
        rowsGateReleased = decision.rowsReleased
        rowsGateReason = decision.rowsWaiting
        if (decision.rowsReleased) {
            cancelGateWatchersLocked()
        } else {
            rowsHeldUnderHeroEnabled = heroEnabled
            // The watchers stay ALIVE: the launch-sync collector started by
            // [startGateInputsObserverLocked] is what ends this hold early, and cancelling it here
            // (as an unconditional release used to) would leave the timeout as the only exit. It is
            // started rather than merely kept, because the collection-only Idle escape reaches a
            // rows hold without ever having armed the gate; the call is idempotent.
            startGateInputsObserverLocked()
            armRowsGateTimeoutLocked(HERO_COMMIT_GATE_TIMEOUT_MS - rowsGateElapsedMs)
        }
    }

    /**
     * Whether a launch sync burst can still land for this account, i.e. whether
     * [LaunchSyncState.Idle] means "not started yet" (wait) or "will never start" (do not wait).
     * A session still restoring counts as expected: it can still resolve to a signed-in account,
     * and the gate's own timeout bounds the wait if the restore stalls.
     */
    private fun launchSyncExpected(): Boolean = AuthRepository.state.value.launchSyncExpected()

    private fun armFirstRefreshGrace() {
        if (!awaitingFirstRefresh || firstRefreshGraceJob?.isActive == true) return
        val generation = firstRefreshGraceGeneration
        firstRefreshGraceJob = scope.launch {
            delay(FIRST_REFRESH_GRACE_MS)
            // Check-and-lift under the publish lock, in the same generation it was armed for.
            val lifted = synchronized(heroSelectionLock) {
                if (generation != firstRefreshGraceGeneration || !awaitingFirstRefresh) return@synchronized false
                awaitingFirstRefresh = false
                true
            }
            if (!lifted) return@launch
            publishCurrentState(requestKey = currentRequestKey)
        }
    }

    /** BUG-42: set by [resetHeroSelection]; while true, an empty catalog hero mid-load is NOT held
     *  (the user just changed Hero Sources and must see the change), cleared on the next non-empty
     *  catalog hero or when the load completes. Guarded by [heroSelectionLock]. */
    private var heroResetRequested = false



    /**
     * BUG-86 (H3's tail): every cloud pull used to end here, and every call used to republish. K2
     * suppressed the identical-payload calls upstream of this; this is the second belt. Once the
     * hero has COMMITTED, a call whose whole input signature (settings, TMDB, gate state, the set
     * of cached section keys) matches the previous one cannot change a single published field, so
     * it does not publish. The collection fallback still runs: it is keyed on its own request key
     * and is the path that fills a collection-only Home.
     */
    fun applyCurrentSettings() {
        armFirstRefreshGrace()
        val skipPublish = synchronized(heroSelectionLock) {
            val signature = currentSettingsSignatureLocked()
            val unchanged = lastAppliedSettingsSignature == signature
            lastAppliedSettingsSignature = signature
            unchanged && heroGateState == HeroGateState.Released
        }
        if (!skipPublish) {
            publishCurrentState(requestKey = currentRequestKey)
        }
        ensureCollectionHeroFallback(
            addons = AddonRepository.uiState.value.addons.enabledAddons(),
            forceRefresh = false,
            refreshSources = false,
            requestKey = currentRequestKey,
        )
    }

    /** Everything an [applyCurrentSettings] publish can depend on, in one comparable string. */
    private fun currentSettingsSignatureLocked(): String {
        val tmdb = TmdbSettingsRepository.snapshot()
        // snapshot() first so a not-yet-loaded settings store cannot report an empty signature.
        HomeCatalogSettingsRepository.snapshot()
        return buildString {
            append(HomeCatalogSettingsRepository.uiState.value.signature)
            append("|tmdb=")
            append(tmdb.enabled)
            append(':')
            append(tmdb.hasApiKey)
            append(':')
            append(tmdb.language)
            append(':')
            append(tmdb.useBasicInfo)
            append(':')
            append(tmdb.useArtwork)
            append("|gate=")
            append(heroGateState)
            append("|keys=")
            append(cachedSections.keys.sorted().joinToString(separator = ","))
        }
    }

    /**
     * Called when TMDB settings (enabled/apiKey/language) change so the hero overlay is rebuilt
     * under the new settings instead of continuing to show enrichment fetched under the old ones.
     */
    fun onTmdbSettingsChanged() {
        resetHeroEnrichment()
        applyCurrentSettings()
    }

    fun clear() = synchronized(heroSelectionLock) {
        activeJob?.cancel()
        activeJob = null
        activeRequestKey = null
        currentRequestKey = null
        lastCatalogHeroSelection = emptyList() // BUG-42: a new account/profile gets a new hero
        heroResetRequested = false
        heroRankingResets++
        awaitingFirstRefresh = true
        firstRefreshGraceGeneration++
        firstRefreshGraceJob?.cancel()
        firstRefreshGraceJob = null
        currentDefinitions = emptyList()
        cachedSections = emptyMap()
        cachedCollectionHeroItems = emptyList()
        collectionHeroJob?.cancel()
        collectionHeroJob = null
        collectionHeroRequestKey = null
        resetHeroEnrichment()
        lastPublishedCatalogHeroEmpty = true
        lastErrorMessage = null
        catalogLoadInProgress = false
        // BUG-86 (Wave H): a new account/profile gets a new commit cycle, so the gate goes all the
        // way back to Idle and both watchers are cancelled. Leaving it Released would let the next
        // profile's first, partial catalog publish through unheld.
        heroGateState = HeroGateState.Idle
        heroGateArmedAt = null
        heroGateIdleSince = null
        heroGateReleaseReason = null
        heroGateResetRequested = false
        heroGateWaiting = HeroGateWait.NONE
        heroGateSourcesSettled = 0
        heroGateSourcesTracked = 0
        catalogOutcomes = emptyMap()
        committedHeadKey = null
        committedHeroPayloads = emptyMap()
        heroItemOrigins = emptyMap()
        lastPruneCount = 0
        heroGateRearms = 0
        // BUG-86 hero-off rows (beta.18): the next profile's rows are gated afresh, and its rows
        // clock restarts at its own first evaluation (heroGateIdleSince above).
        rowsGateReleased = true
        rowsGateReason = null
        rowsGateElapsedMs = 0
        rowsHeldUnderHeroEnabled = true
        rowsHoldBaselineHeroEnabled = null
        lastAppliedSettingsSignature = null
        cancelGateWatchersLocked()
        _uiState.value = HomeUiState()
    }

    /**
     * BUG-42: the whole publish runs under [heroSelectionLock] — publishes come from the repo's
     * Default scope while [resetHeroSelection]/[clear] arrive from the main thread, and a
     * straggling publish must not write an older selection (or an older-generation UI state) after
     * either of them. Synchronous body, no suspension, nothing inside takes the lock again.
     *
     * The load state is NOT a parameter (Codex branch review round 7). Every caller but the
     * fan-out itself used to pass `_uiState.value.isLoading`, which is the value a held publish
     * forced to true rather than the value the load path last reported, so the forced flag fed
     * itself back in and outlived the hold. [catalogLoadInProgress] is the one writer of that
     * answer now, and [publishedIsLoading] is the only place the hold is allowed to override it.
     */
    private fun publishCurrentState(
        requestKey: String?,
    ) = synchronized(heroSelectionLock) {
        publishCurrentStateLocked(requestKey = requestKey)
    }

    private fun publishCurrentStateLocked(
        requestKey: String?,
    ) {
        val loadInProgress = catalogLoadInProgress
        val snapshot = HomeCatalogSettingsRepository.snapshot()
        val preferences = snapshot.preferences
        val todayIsoDate = if (snapshot.hideUnreleasedContent) CurrentDateProvider.todayIsoDate() else null
        fun HomeCatalogSection.withReleaseFilter(): HomeCatalogSection =
            if (todayIsoDate == null) this else filterReleasedItems(todayIsoDate)

        val sections = currentDefinitions
            .sortedBy { definition -> preferences[definition.key]?.order ?: Int.MAX_VALUE }
            .mapNotNull { definition ->
                val preference = preferences[definition.key]
                if (preference?.enabled == false) return@mapNotNull null

                val section = cachedSections[definition.key]?.withReleaseFilter() ?: return@mapNotNull null
                if (section.items.isEmpty()) return@mapNotNull null
                val customTitle = preference?.customTitle.orEmpty()
                // The DEFINITION owns the row's display fields, not the fetch that filled it: a
                // section cached before an add-on rename still carries the old add-on name, and the
                // rename deliberately does not re-fetch it (see `withCurrentMetadata`).
                section.withCurrentMetadata(
                    definition = definition,
                    customTitle = customTitle,
                    showCatalogType = snapshot.showCatalogType,
                )
            }

        // BUG-86 (Hole A): remember which catalog each item came from, and forget the items whose
        // origin catalog has left the definition set. This is what lets a previously selected hero
        // item be retained on a condition that MEANS something ("its catalog is still installed")
        // instead of the old proxy ("a load happens to be in flight").
        recordHeroItemOriginsLocked()
        pruneCommittedPayloadsLocked()

        val catalogHeroItems = if (snapshot.heroEnabled) {
            val heroRandom = Random((requestKey?.hashCode() ?: 0).absoluteValue + 1)
            val pool = currentDefinitions
                .filter { definition -> preferences[definition.key]?.heroSourceEnabled != false }
                .mapNotNull { definition -> cachedSections[definition.key] }
                .map { section -> section.withReleaseFilter() }
                .flatMap { section -> section.items }
                .distinctBy { item -> item.stableKey() }
            // BUG-42: keep what is already on screen at the head; only newcomers are shuffled in.
            // Release-filtered like the rows: an unreleased title the user just asked to hide must
            // not linger on the hero either (Codex gate 8).
            val everythingCached = cachedSections.values
                .map { section -> section.withReleaseFilter() }
                .flatMap { section -> section.items }
            val previousSelection = lastCatalogHeroSelection
            val previousStillReleased = if (todayIsoDate == null) {
                previousSelection
            } else {
                previousSelection.filterReleasedItems(todayIsoDate)
            }
            logDroppedHeadLocked(previousSelection, previousStillReleased)
            // BUG-86 (Hole A): NOT conditional on isLoading any more. The old condition opened the
            // moment a load finished, and the launch sync burst lands right after that: the head's
            // own section was pruned and re-fetched, the head was not in `everythingCached` for a
            // beat, and it was dropped. An item stays eligible while its ORIGIN catalog is still
            // installed; the release filter above is the only thing that can evict it.
            val retainedPrevious = previousStillReleased.filter { item ->
                item.stableKey() in heroItemOrigins
            }
            // Fresh cached instances FIRST so a kept item carries current metadata; the previous
            // instances only vouch for identity.
            val keepFrom = everythingCached + retainedPrevious
            val ranking = pinCommittedHead(
                ranking = stableHeroSelection(
                    previous = previousSelection,
                    pool = pool,
                    limit = HOME_HERO_ITEM_LIMIT,
                    random = heroRandom,
                    keepFrom = keepFrom,
                    key = MetaPreview::stableKey,
                ),
                committedKey = committedHeadKey,
                keepFrom = keepFrom,
                key = MetaPreview::stableKey,
            )
            lastCatalogHeroSelection = ranking
            ranking.take(HOME_HERO_ITEM_LIMIT)
        } else {
            emptyList()
        }
        lastPublishedCatalogHeroEmpty = snapshot.heroEnabled && catalogHeroItems.isEmpty()
        val resetRequested = heroResetRequested
        // Release-filtered like everything else on Home (an unreleased title the user just hid must
        // not survive on the collection hero either).
        val collectionHeroItems = if (todayIsoDate == null) {
            cachedCollectionHeroItems
        } else {
            cachedCollectionHeroItems.filterReleasedItems(todayIsoDate)
        }
        fun heroItemsFrom(source: HeroPublishSource): List<MetaPreview> = when (source) {
            HeroPublishSource.Off -> emptyList()
            HeroPublishSource.Catalog -> catalogHeroItems
            HeroPublishSource.Held -> _uiState.value.heroItems
            HeroPublishSource.CollectionFallback -> collectionHeroItems
        }
        // BUG-86 (Codex round 2): the CANDIDATE (what this publish would carry if nothing were
        // holding it) is computed before the gate is asked, so the gate reasons about the hero it
        // is actually going to commit. A Home whose hero-source catalogs came back empty but whose
        // collection fallback resolved has a non-empty candidate: it commits the fallback instead
        // of holding on `empty` until the timeout and then freezing nothing.
        val heroCandidate = heroItemsFrom(
            heroPublishSource(
                heroEnabled = snapshot.heroEnabled,
                catalogHeroEmpty = catalogHeroItems.isEmpty(),
                holding = false,
                resetRequested = resetRequested,
            )
        )

        val tmdbSettings = TmdbSettingsRepository.snapshot()

        // BUG-42: the hero commits each item's metadata exactly ONCE. Publishing raw catalog
        // metadata and then re-publishing the TMDB-localized payload rendered the same title twice
        // (English under French, caught frame-by-frame in a tester video), so a hero whose items
        // still have enrichment outstanding HOLDS — it keeps whatever was last published — until
        // the fetch lands or [HERO_ENRICHMENT_HOLD_TIMEOUT_MS] expires. After the gate has
        // released, that legacy hold covers only NEWCOMERS: everything committed is served from
        // the frozen map and can never wait on, or be repainted by, a later fetch.
        val committedBefore = heroGateState == HeroGateState.Released
        val enrichmentCandidates = if (committedBefore) {
            heroCandidate.filter { item -> item.stableKey() !in committedHeroPayloads }
        } else {
            heroCandidate
        }
        val awaitingEnrichment = heroItemsAwaitingEnrichment(enrichmentCandidates, tmdbSettings)

        val wasArmed = heroGateState == HeroGateState.Armed
        val decision = if (committedBefore) {
            null
        } else {
            evaluateHeroGateLocked(
                snapshot = snapshot,
                candidateEmpty = heroCandidate.isEmpty(),
                enrichmentPending = awaitingEnrichment.size,
            )
        }

        // The gate has answered, so the published list can now be derived from that answer: a
        // release with an empty catalog hero falls through to the collection fallback HERE, in the
        // same publish, instead of committing the previous (empty) hero and leaving nothing behind
        // to republish (BUG-86, Codex round 2).
        val publishSource = heroPublishSource(
            heroEnabled = snapshot.heroEnabled,
            catalogHeroEmpty = catalogHeroItems.isEmpty(),
            // While the gate is unreleased it IS the hold. Post-commit it is the legacy BUG-42
            // mid-load hold: the collection fallback is for a Home whose CATALOGS yield no hero,
            // not for the first few hundred ms of a load before the hero-source catalogs land, and
            // filling it in mid-load and then replacing all eight items when the catalog hero
            // arrived was the "one cover, then another" the sim probe caught (`inRows=0` head).
            holding = if (decision != null) !decision.released else loadInProgress || awaitingFirstRefresh,
            resetRequested = resetRequested,
        )
        val heroItems = heroItemsFrom(publishSource)
        when (publishSource) {
            HeroPublishSource.Catalog -> heroResetRequested = false
            HeroPublishSource.CollectionFallback ->
                if (!loadInProgress && !awaitingFirstRefresh) heroResetRequested = false
            HeroPublishSource.Off, HeroPublishSource.Held -> Unit
        }

        val publishedHeroItems: List<MetaPreview>
        var legacyHold = false
        when {
            // 1. The gate is committing right now: freeze the payload, pin the head, publish once.
            decision != null && decision.released -> {
                val committed = heroItems.map { item -> item.withTmdbEnrichment(tmdbSettings) }
                committedHeroPayloads = committed.associateBy { item -> item.stableKey() }
                committedHeadKey = committed.firstOrNull()?.stableKey()
                heroGateState = HeroGateState.Released
                heroGateReleaseReason = decision.reason
                heroGateResetRequested = false
                // BUG-86 hero-off rows (beta.18): the watchers are cancelled by THIS call only when
                // the rows go with the hero. A `heroOff`/`noSources` release that still owes the
                // launch sync burst keeps them, plus its own timeout job, and re-decides on every
                // later publish (branch 3's `refreshRowsGateLocked`).
                applyRowsGateDecisionLocked(decision, heroEnabled = snapshot.heroEnabled)
                log.i {
                    "heroGateReleased reason=${decision.reason} n=${committed.size} " +
                        "head=${committedHeadKey ?: "-"} rows=${sections.size} " +
                        "rowsReleased=${decision.rowsReleased} rowsWait=${decision.rowsWaiting}"
                }
                publishedHeroItems = committed
            }
            // 2. Still holding. The PREVIOUS hero and the PREVIOUS rows are republished unchanged:
            //    rows move under the hero (their order comes from the same settings the burst
            //    rewrites), so committing the hero once while the rows rebuild twice would just
            //    move the double one layer down.
            decision != null -> {
                publishedHeroItems = _uiState.value.heroItems
            }
            // 3. Committed. Serve the frozen instances (identity-equal, so an unchanged publish is
            //    suppressed by StateFlow equality) and let newcomers use the legacy hold.
            else -> {
                // BUG-86 hero-off rows (beta.18): the rows can still be held here, by a `heroOff`
                // or `noSources` release that owed the burst. Re-decided before the rows shape of
                // this publish is computed below.
                refreshRowsGateLocked(snapshot)
                legacyHold = awaitingEnrichment.isNotEmpty() && !heroEnrichmentHoldExpired
                publishedHeroItems = if (legacyHold) {
                    _uiState.value.heroItems
                } else {
                    serveCommittedHeroItemsLocked(heroItems, tmdbSettings)
                }
            }
        }

        val rowsHeld = rowsHeldForPublish(
            decisionReleased = decision?.released,
            // Codex beta.18 r5 (P2): the EFFECTIVE rows release after `applyRowsGateDecisionLocked`,
            // not the raw decision — a mid-launch Show Hero toggle overrides the decision's hold
            // (`rowsWait=toggle`), and publishing the raw `false` kept Swift holding the rows with
            // nothing left to republish them.
            decisionRowsReleased = if (decision?.released == true) rowsGateReleased else (decision?.rowsReleased ?: true),
            wasArmed = wasArmed,
            rowsGateReleased = rowsGateReleased,
        )

        val publishedSections = if (rowsHeld) {
            _uiState.value.sections
        } else {
            sections.map { section -> section.withTmdbEnrichment(tmdbSettings) }
        }
        val released = heroGateState == HeroGateState.Released
        val nextState = HomeUiState(
            isLoading = publishedIsLoading(catalogLoadInProgress = loadInProgress, rowsHeld = rowsHeld),
            heroItems = publishedHeroItems,
            sections = publishedSections,
            errorMessage = when {
                rowsHeld -> _uiState.value.errorMessage
                publishedSections.isEmpty() -> lastErrorMessage
                else -> null
            },
            heroGateReleased = released,
            heroGateReason = if (released) heroGateReleaseReason else null,
            // BUG-86 hero-off rows (beta.18): what THIS publish actually did with the rows, not
            // the repository's rows-gate field. The two differ while the gate is Armed — the field
            // is still `true` there because the rows are held by the HERO hold, not by the rows
            // gate — and the frontend needs the publish shape: `HeroPublishRoute` must never adopt
            // `sections` that this publish carried over from the previous one.
            rowsGateReleased = !rowsHeld,
            rowsGateReason = rowsGateReason,
        )
        // Stamped AFTER the gate decision has been applied above (heroGateState and
        // heroGateReleaseReason are written inside the `when`), so the probe fields describe the
        // state being published rather than the repository one main-thread hop later. See
        // [HomeUiState.heroRankingDebugSnapshot]. The instance escapes only on the next line, so
        // this write can never be seen half-done by a collector.
        nextState.heroRankingDebugSnapshot = heroRankingDebugLocked()
        _uiState.value = nextState

        if (awaitingEnrichment.isEmpty()) {
            releaseHeroEnrichmentHold()
            return
        }
        // Scheduled on every publish, loading included — a hold with no fetch behind it can only end
        // at the timeout, which would put hero first paint behind the whole catalog fan-out. While
        // the gate is armed this is also what CLEARS the gate's enrichment input.
        scheduleHeroEnrichment(awaitingEnrichment, tmdbSettings)
        if (legacyHold) armHeroEnrichmentHold()
    }

    /**
     * Rebuilds [heroItemOrigins] from the cached sections: item to the FIRST definition (in
     * definition order) that carries it. Entries whose origin catalog is no longer in
     * [currentDefinitions] are dropped, which is exactly the one event allowed to evict a committed
     * hero item (the user removed or disabled that add-on). The collection fallback's sentinel
     * origin follows the same rule against [cachedCollectionHeroItems] instead: see
     * [retainHeroItemOrigins].
     */
    private fun recordHeroItemOriginsLocked() {
        val origins = HashMap<String, String>(heroItemOrigins.size)
        origins.putAll(
            retainHeroItemOrigins(
                origins = heroItemOrigins,
                knownDefinitionKeys = currentDefinitions.mapTo(HashSet(), HomeCatalogDefinition::key),
                collectionHeroKeys = cachedCollectionHeroItems.mapTo(HashSet()) { item ->
                    item.stableKey()
                },
            )
        )
        currentDefinitions.forEach { definition ->
            cachedSections[definition.key]?.items?.forEach { item ->
                val itemKey = item.stableKey()
                if (itemKey !in origins) origins[itemKey] = definition.key
            }
        }
        // The collection fallback hero has no catalog behind it. It gets a sentinel origin so it is
        // retainable and freezable like any other hero item; ensureCollectionHeroFallback owns its
        // invalidation (it drops the cache itself when the collection set changes).
        cachedCollectionHeroItems.forEach { item ->
            val itemKey = item.stableKey()
            if (itemKey !in origins) origins[itemKey] = COLLECTION_HERO_ORIGIN
        }
        heroItemOrigins = origins
    }

    /**
     * The frozen payloads outlive the carousel slice on purpose (an item that scrolls out and comes
     * back must come back as the SAME instance), but not their own catalog: when the user removes
     * or disables the add-on that supplied a committed item, that item stops being committed. A
     * committed COLLECTION fallback item leaves the same way when its collection set changes (see
     * [retainHeroItemOrigins]), which is what lets the replacement fallback commit as a first
     * commit. This is also what bounds the map across a long session.
     */
    private fun pruneCommittedPayloadsLocked() {
        if (committedHeroPayloads.isEmpty()) return
        val surviving = committedHeroPayloads.filterKeys { itemKey -> itemKey in heroItemOrigins }
        if (surviving.size == committedHeroPayloads.size) return
        committedHeroPayloads = surviving
        val headKey = committedHeadKey
        if (headKey != null && headKey !in surviving) {
            log.i { "heroHeadDropped reason=originGone key=$headKey" }
            committedHeadKey = null
        }
    }

    /** BUG-86 probe: the one legitimate way a committed head leaves is the release filter. */
    private fun logDroppedHeadLocked(
        previousSelection: List<MetaPreview>,
        previousStillReleased: List<MetaPreview>,
    ) {
        val headKey = committedHeadKey ?: previousSelection.firstOrNull()?.stableKey() ?: return
        if (previousSelection.none { item -> item.stableKey() == headKey }) return
        if (previousStillReleased.any { item -> item.stableKey() == headKey }) return
        log.i { "heroHeadDropped reason=unreleased key=$headKey" }
    }

    /**
     * Post-commit hero payloads: the SAME instances that were frozen at release, so a publish that
     * changes nothing else is suppressed by StateFlow equality instead of re-running the whole
     * paint. The only mutation is the one-time gap-fill (see [withCommittedGapFill]); it is written
     * back so the item stays identity-stable from then on.
     *
     * An item that was NOT committed (a newcomer that entered the carousel after the commit) takes
     * the ordinary enrichment path.
     */
    private fun serveCommittedHeroItemsLocked(
        heroItems: List<MetaPreview>,
        settings: TmdbSettings,
    ): List<MetaPreview> {
        // After an explicit Hero Sources reset the frozen map is empty by design; the same is true
        // once a superseded collection fallback has been pruned out of it. Re-freeze on the first
        // settled publish so the new selection is as immutable as the first one was.
        if (committedHeroPayloads.isEmpty() && heroItems.isNotEmpty() && heroGateState == HeroGateState.Released) {
            val recommitted = heroItems.map { item -> item.withTmdbEnrichment(settings) }
            committedHeroPayloads = recommitted.associateBy { item -> item.stableKey() }
            committedHeadKey = recommitted.firstOrNull()?.stableKey()
            return recommitted
        }
        var payloads = committedHeroPayloads
        val served = heroItems.map { item ->
            val itemKey = item.stableKey()
            val frozen = payloads[itemKey] ?: return@map item.withTmdbEnrichment(settings)
            val filled = frozen.withCommittedGapFill(settings)
            if (filled !== frozen) payloads = payloads + (itemKey to filled)
            filled
        }
        committedHeroPayloads = payloads
        return served
    }

    /**
     * The single exception to a frozen payload: an EMPTY description or genres may be filled in
     * once, silently, from enrichment that landed after the commit. Nothing that repaints is
     * touched (never name, logo or banner), and a field that already has content is never replaced,
     * so text cannot swap under the user the way BUG-86 described.
     */
    private fun MetaPreview.withCommittedGapFill(settings: TmdbSettings): MetaPreview {
        if (!settings.enabled || !settings.hasApiKey || !settings.useBasicInfo) return this
        if (!description.isNullOrBlank() && genres.isNotEmpty()) return this
        val enrichment = heroEnrichmentOverlay[heroEnrichmentKey(settings)] ?: return this
        var updated = this
        if (description.isNullOrBlank() && !enrichment.description.isNullOrBlank()) {
            updated = updated.copy(description = enrichment.description)
        }
        if (genres.isEmpty() && enrichment.genres.isNotEmpty()) {
            updated = updated.copy(genres = enrichment.genres)
        }
        return updated
    }

    /**
     * Codex review: the key is LANGUAGE-QUALIFIED so an enrichment fetched under one TMDB
     * language can never be served under another — even if a settings-change reset races an
     * in-flight completion (reset can't take [heroEnrichmentMutex] from its non-suspend callers,
     * so a straggler write CAN land after the clear; with the language in the key, that straggler
     * is simply unmatchable dead weight until the next reset instead of stale UI).
     */
    private fun MetaPreview.heroEnrichmentKey(settings: TmdbSettings): String =
        "$type:$id:${settings.language}"

    /**
     * BUG-35 (beta.12): the fetch-volume product call landed on VISIBILITY-DRIVEN row enrichment —
     * see [requestRowEnrichment]. This application step is unchanged: row items render whatever
     * the shared overlay already holds (hero-fetched or row-fetched alike), and a section with no
     * resident overlay entries passes through untouched.
     */
    private fun HomeCatalogSection.withTmdbEnrichment(settings: TmdbSettings): HomeCatalogSection {
        if (!settings.enabled || !settings.hasApiKey || heroEnrichmentOverlay.isEmpty()) return this
        if (items.none { item -> item.heroEnrichmentKey(settings) in heroEnrichmentOverlay }) return this
        return copy(items = items.map { item -> item.withTmdbEnrichment(settings) })
    }

    /**
     * Applies cached TMDB preview enrichment. Gated on [settings] so a disabled/removed TMDB config
     * stops showing stale enrichment on the very next publish, and never touches id/type/poster —
     * those identify and route the card.
     */
    private fun MetaPreview.withTmdbEnrichment(settings: TmdbSettings): MetaPreview {
        if (!settings.enabled || !settings.hasApiKey) return this
        val enrichment = heroEnrichmentOverlay[heroEnrichmentKey(settings)] ?: return this

        var updated = this
        if (settings.useBasicInfo) {
            updated = updated.copy(
                name = enrichment.localizedTitle ?: updated.name,
                description = enrichment.description ?: updated.description,
                genres = enrichment.genres.ifEmpty { updated.genres },
            )
        }
        if (settings.useArtwork) {
            updated = updated.copy(
                logo = enrichment.logo ?: updated.logo,
                banner = enrichment.backdrop ?: updated.banner,
            )
        }
        return updated
    }

    /**
     * Hero items whose enrichment is neither cached nor already known to be unavailable — i.e. the
     * items a hero publish would have to commit raw. Empty whenever enrichment cannot change the
     * payload at all (disabled, no key, both TMDB categories off), which is the "publish raw
     * immediately, exactly as before" path.
     */
    private fun heroItemsAwaitingEnrichment(
        items: List<MetaPreview>,
        settings: TmdbSettings,
    ): List<MetaPreview> {
        if (!settings.enabled || !settings.hasApiKey) return emptyList()
        if (!settings.useBasicInfo && !settings.useArtwork) return emptyList()
        return items.filter { item ->
            val key = item.heroEnrichmentKey(settings)
            key !in heroEnrichmentOverlay && key !in heroEnrichmentAttempted
        }
    }

    /**
     * Bounds the held hero publish. Deliberately NOT restarted while a hold is already running: the
     * hero set grows with each catalog batch, and re-arming per publish would let the cap slide
     * forward indefinitely. One timer per hold, so the worst case stays one
     * [HERO_ENRICHMENT_HOLD_TIMEOUT_MS] window from the first held publish.
     */
    private fun armHeroEnrichmentHold() {
        // BUG-86: while the commit gate is armed IT owns the wait (and its own longer timeout), so
        // a second, shorter timer underneath would expire first and publish the raw hero the gate
        // is holding back. The gate feeds `enrichmentPending` from the same set this hold watched.
        if (heroGateState == HeroGateState.Armed) return
        if (heroEnrichmentHoldJob?.isActive == true) return
        // Codex review: cancellation racing the delay's completion can let a stale timer resume
        // AFTER releaseHeroEnrichmentHold() started a new hold era — the generation token makes
        // such a zombie a no-op instead of expiring the new request's hold.
        val generation = heroEnrichmentHoldGeneration
        heroEnrichmentHoldJob = scope.launch {
            delay(HERO_ENRICHMENT_HOLD_TIMEOUT_MS)
            if (generation != heroEnrichmentHoldGeneration) return@launch
            heroEnrichmentHoldExpired = true
            publishCurrentState(requestKey = currentRequestKey)
        }
    }

    /** Read from the enrichment completion path, which runs outside [heroSelectionLock]. */
    private val heroGateIsArmed: Boolean
        get() = heroGateState == HeroGateState.Armed

    /** Clears the hold without touching the overlay — the next unresolved hero may hold again. */
    private fun releaseHeroEnrichmentHold() {
        heroEnrichmentHoldGeneration += 1
        heroEnrichmentHoldJob?.cancel()
        heroEnrichmentHoldJob = null
        heroEnrichmentHoldExpired = false
    }

    /** Full invalidation (settings changed, signed out): nothing may survive into the next language. */
    private fun resetHeroEnrichment() {
        heroEnrichmentFetchParent.cancel()
        heroEnrichmentFetchParent = SupervisorJob()
        heroEnrichmentOverlay = emptyMap()
        heroEnrichmentAttempted = emptySet()
        heroEnrichmentInFlight = emptySet()
        releaseHeroEnrichmentHold()
    }

    /**
     * BUG-35 (beta.12): localize a row's LEADING items when the row actually scrolls into view.
     * tvOS calls this from each catalog row's `onAppear`, which bounds fetch volume by what the
     * user actually looks at instead of the whole catalog fan-out (the deferred fetch-volume
     * product call, resolved): ≤ [HOME_ROW_ENRICHMENT_PREFIX] items per row, deduped per
     * item+language for the whole session by the same overlay/attempted/in-flight sets the hero
     * uses, fetched through the same mutex-guarded pipeline, republished by its existing
     * completion path. Rows are never HELD like the hero — the caption text updating in place as
     * the localized payload lands is the accepted row-level trade (BUG-42's double-commit
     * objection was about the full-bleed hero, which keeps its once-only hold).
     */
    fun requestRowEnrichment(sectionKey: String) {
        val settings = TmdbSettingsRepository.snapshot()
        if (!settings.enabled || !settings.hasApiKey) return
        // Same gate the hero path applies (heroItemsAwaitingEnrichment): with both output
        // categories off, a fetch could not change a single rendered field — don't spend it.
        if (!settings.useBasicInfo && !settings.useArtwork) return
        val section = _uiState.value.sections.find { it.key == sectionKey } ?: return
        // No pre-filter against the overlay sets here: this is a non-suspend caller, and
        // [scheduleHeroEnrichment] re-checks all three sets under the mutex before claiming —
        // an already-resident prefix just claims nothing and the launch returns immediately.
        scheduleHeroEnrichment(section.items.take(HOME_ROW_ENRICHMENT_PREFIX), settings)
    }

    /**
     * Fetches TMDB preview enrichment for the given items, keyed by item so a removed/failed item
     * never gets retried on every publish and so overlapping publishes (each catalog batch reshuffles
     * the hero) never fetch the same item twice. Fetches are additive and are never cancelled by a
     * later publish — a cancelled fetch would leave its items neither resolved nor attempted, which
     * is precisely the state a held publish waits on. The completion republish sources its requestKey
     * the same way the settings-driven republishes do, so the seeded hero shuffle always matches
     * whatever request is currently live — a job that outlives its request can't resurrect an old seed.
     */
    private fun scheduleHeroEnrichment(items: List<MetaPreview>, settings: TmdbSettings) {
        if (items.isEmpty()) return
        scope.launch(heroEnrichmentFetchParent) {
            // Claiming the batch happens under the mutex (not synchronously in the caller) so two
            // concurrent publishes can never both claim — and both fetch — the same item. All
            // THREE sets are rechecked here (Codex review): a queued job can reach this lock
            // after an earlier fetch already moved its item from in-flight into the overlay or
            // attempted set, and claiming on the in-flight set alone would refetch it.
            val missing = heroEnrichmentMutex.withLock {
                val claimable = items.filter { item ->
                    val key = item.heroEnrichmentKey(settings)
                    key !in heroEnrichmentInFlight &&
                        key !in heroEnrichmentOverlay &&
                        key !in heroEnrichmentAttempted
                }
                heroEnrichmentInFlight = heroEnrichmentInFlight + claimable.map { it.heroEnrichmentKey(settings) }
                claimable
            }
            if (missing.isEmpty()) return@launch
            // Inert unless the burst simulator is armed (see HomeLaunchBurstSim).
            HomeLaunchBurstSim.enrichmentDelayMs.takeIf { it > 0 }?.let { delay(it) }
            val results = missing.map { item ->
                async {
                    item.heroEnrichmentKey(settings) to runCatching {
                        TmdbMetadataService.fetchPreviewEnrichment(item.type, item.id, settings)
                    }.getOrNull()
                }
            }.awaitAll()

            val additions = results.mapNotNull { (key, enrichment) -> enrichment?.let { key to it } }.toMap()
            val nullKeys = results.filter { (_, enrichment) -> enrichment == null }.map { (key, _) -> key }.toSet()

            heroEnrichmentMutex.withLock {
                heroEnrichmentOverlay = heroEnrichmentOverlay + additions
                heroEnrichmentAttempted = heroEnrichmentAttempted + nullKeys
                heroEnrichmentInFlight = heroEnrichmentInFlight - additions.keys - nullKeys

                // Republished even when every fetch missed: an all-miss batch is what releases a
                // held hero publish (the items are now "attempted"), so gating this on additions
                // would pin the hero on the timeout path for no reason.
                //
                // EXCEPT after the hold timed out (Codex review): the raw hero is already on
                // screen then, and a completion-triggered republish would swap its text in place —
                // the exact BUG-35/42 double commit this hold exists to prevent, just slower. The
                // overlay/attempted bookkeeping above still lands, so the NEXT natural publish (a
                // catalog batch, a refresh, a settings change — all visual transitions anyway)
                // serves the localized payload.
                //
                // The publish itself stays INSIDE the lock (Codex review round 2 on this spot):
                // two completions finishing close together could otherwise publish out of order —
                // the earlier batch's state overwriting the later, fully-localized one, and
                // re-arming the hold. Safe against self-deadlock: publishCurrentState only
                // ever *launches* the claim coroutine, it never takes this mutex inline.
                // BUG-86: while the gate is ARMED the full publish always runs, expired hold or
                // not. The gate is waiting on exactly this completion to clear `enrichmentPending`,
                // and nothing is on screen to double-commit yet. The sections-only CAS below stays
                // for the post-commit expired case it was written for.
                if (!heroEnrichmentHoldExpired || heroGateIsArmed) {
                    publishCurrentState(requestKey = currentRequestKey)
                } else {
                    // BUG-35 (beta.12, Codex gate 4-5): once the hero hold has expired, the full
                    // republish above stays suppressed so the raw hero on screen never swaps its
                    // text in place — but row enrichment (requestRowEnrichment) rides this same
                    // completion, and skipping entirely left row batches updating only the overlay,
                    // invisible until an unrelated publish. Sections-only update: hero untouched
                    // (exact objects last published), rows re-run the overlay application, which
                    // never touches id/type/poster and is idempotent for already-localized items.
                    val settingsNow = TmdbSettingsRepository.snapshot()
                    // CAS update, not read-copy-write (Codex gate 4-5 round 3): a catalog batch
                    // publishing between a plain read and write would be clobbered by the stale
                    // copy. `update` retries on contention, and the transform touches ONLY
                    // `sections`, so whatever state won the race keeps its loading/error/hero.
                    _uiState.update { state ->
                        state.copy(sections = state.sections.map { section -> section.withTmdbEnrichment(settingsNow) })
                    }
                }
            }
        }
    }

    /** Launches [block] on the repository's own scope. Burst simulator only (see [HomeLaunchBurstSim]). */
    internal fun launchBurstSimTask(block: suspend CoroutineScope.() -> Unit): Job =
        scope.launch(block = block)

    private suspend fun HomeCatalogDefinition.toSection(forceRefresh: Boolean): HomeCatalogSection {
        // Inert unless the burst simulator is armed: it makes one nominated hero-source catalog
        // fail its FIRST fetch, so the gate has to survive a Failed outcome plus the retry.
        HomeLaunchBurstSim.consumeFirstFetchFailure(key)?.let { failure -> throw failure }
        val page = fetchCatalogPage(
            manifestUrl = manifestUrl,
            type = type,
            catalogId = catalogId,
            maxItems = HOME_CATALOG_PREVIEW_FETCH_LIMIT,
            forceRefresh = forceRefresh,
        )
        val items = page.items
        if (items.isEmpty()) {
            return HomeCatalogSection(
                key = key,
                title = defaultTitle,
                subtitle = addonName,
                addonName = addonName,
                target = CatalogTarget.Addon(
                    manifestUrl = manifestUrl,
                    contentType = type,
                    catalogId = catalogId,
                    supportsPagination = supportsPagination,
                ),
                items = emptyList(),
                availableItemCount = 0,
                hasMore = false,
            )
        }

        return HomeCatalogSection(
            key = key,
            title = defaultTitle,
            subtitle = addonName,
            addonName = addonName,
            target = CatalogTarget.Addon(
                manifestUrl = manifestUrl,
                contentType = type,
                catalogId = catalogId,
                supportsPagination = supportsPagination,
            ),
            items = items,
            availableItemCount = page.rawItemCount,
            hasMore = supportsPagination && page.nextSkip != null,
        )
    }

    private fun ensureCollectionHeroFallback(
        addons: List<ManagedAddon>,
        forceRefresh: Boolean,
        refreshSources: Boolean,
        requestKey: String?,
    ) {
        if (!lastPublishedCatalogHeroEmpty) return
        val snapshot = HomeCatalogSettingsRepository.snapshot()
        if (!snapshot.heroEnabled) return
        val collections = enabledCollectionsForHero(snapshot)
        if (collections.isEmpty()) {
            cachedCollectionHeroItems = emptyList()
            collectionHeroRequestKey = null
            return
        }

        val nextRequestKey = collectionHeroRequestKey(
            collections = collections,
            addons = addons,
            snapshot = snapshot,
            requestKey = requestKey,
        )
        if (!refreshSources && collectionHeroRequestKey == nextRequestKey) return

        collectionHeroJob?.cancel()
        // BUG-42: a SAME-key re-resolve (forced refresh) keeps the previously resolved collection
        // hero on screen until the new one lands — publishing an EMPTY hero here and the resolved
        // list a moment later was a second commit (backdrop → blank → backdrop) on every
        // collection-only Home. A CHANGED key (different collections/settings) invalidates the
        // cached items: they are dropped now, and the next publish fills the hero once.
        // Only a CHANGE of key with something actually cached is an invalidation — a first resolve,
        // or a re-key after clear() emptied the cache, has nothing to invalidate (and must not
        // release the mid-load hold: sim run 2026-08-18 showed exactly that regression).
        val keyChanged = collectionHeroRequestKey != null &&
            collectionHeroRequestKey != nextRequestKey &&
            cachedCollectionHeroItems.isNotEmpty()
        if (keyChanged) cachedCollectionHeroItems = emptyList()
        collectionHeroRequestKey = nextRequestKey
        if (keyChanged) {
            // The old collection's art must leave now, not when the network answers — also through
            // the mid-load hold (an explicit collection/settings change is an invalidation, not
            // incremental loading).
            synchronized(heroSelectionLock) { heroResetRequested = true }
            publishCurrentState(requestKey = requestKey)
        }

        collectionHeroJob = scope.launch {
            val sources = collectionHeroSources(collections)
            val sourceResults = sources.map { source ->
                async {
                    runCatching {
                        source.resolveCollectionHeroItems(
                            addons = addons,
                            forceRefresh = forceRefresh,
                        )
                    }.getOrDefault(emptyList())
                }
            }.awaitAll()
            val random = Random((nextRequestKey.hashCode()).absoluteValue + 7)
            cachedCollectionHeroItems = roundRobinCollectionHeroItems(sourceResults)
                .distinctBy { item -> item.stableKey() }
                .shuffled(random)
                .take(HOME_HERO_ITEM_LIMIT)
            publishCurrentState(requestKey = requestKey)
        }
    }

    private fun enabledCollectionsForHero(snapshot: HomeCatalogSettingsSnapshot): List<Collection> {
        val preferences = snapshot.preferences
        return CollectionRepository.collections.value
            .filter { collection ->
                collection.folders.isNotEmpty() &&
                    preferences["collection_${collection.id}"]?.enabled != false
            }
            .sortedBy { collection ->
                preferences["collection_${collection.id}"]?.order ?: Int.MAX_VALUE
            }
    }

    private fun collectionHeroSources(collections: List<Collection>): List<CollectionSource> =
        collections
            .flatMap { collection -> collection.folders }
            .flatMap { folder -> folder.resolvedSources }
            .take(HOME_COLLECTION_HERO_SOURCE_LIMIT)

    private suspend fun CollectionSource.resolveCollectionHeroItems(
        addons: List<ManagedAddon>,
        forceRefresh: Boolean,
    ): List<MetaPreview> {
        val page = when {
            isTmdb -> TmdbCollectionSourceResolver.resolve(source = this, page = 1)
            isTrakt -> TraktPublicListSourceResolver.resolve(source = this, page = 1)
            else -> {
                val catalogSource = addonCatalogSource() ?: return emptyList()
                val resolvedCatalog = addons.findCollectionCatalog(catalogSource) ?: return emptyList()
                fetchCatalogPage(
                    manifestUrl = resolvedCatalog.addon.manifestUrl,
                    type = catalogSource.type,
                    catalogId = catalogSource.catalogId,
                    genre = catalogSource.genre,
                    maxItems = HOME_COLLECTION_HERO_SOURCE_ITEM_LIMIT,
                    forceRefresh = forceRefresh,
                )
            }
        }
        val items = page.items
        return if (HomeCatalogSettingsRepository.snapshot().hideUnreleasedContent) {
            items.filterReleasedItems(CurrentDateProvider.todayIsoDate())
        } else {
            items
        }
    }

    private fun roundRobinCollectionHeroItems(sourceResults: List<List<MetaPreview>>): List<MetaPreview> {
        val iterators = sourceResults.filter { it.isNotEmpty() }.map { it.iterator() }
        if (iterators.isEmpty()) return emptyList()
        val merged = mutableListOf<MetaPreview>()
        var hasMore = true
        while (hasMore && merged.size < HOME_COLLECTION_HERO_SOURCE_LIMIT * HOME_COLLECTION_HERO_SOURCE_ITEM_LIMIT) {
            hasMore = false
            iterators.forEach { iterator ->
                if (iterator.hasNext()) {
                    merged.add(iterator.next())
                    hasMore = true
                }
            }
        }
        return merged
    }

    private fun collectionHeroRequestKey(
        collections: List<Collection>,
        addons: List<ManagedAddon>,
        snapshot: HomeCatalogSettingsSnapshot,
        requestKey: String?,
    ): String = buildString {
        append(requestKey.orEmpty())
        append("|hideUnreleased=")
        append(snapshot.hideUnreleasedContent)
        append("|collections=")
        collections.forEach { collection ->
            val preference = snapshot.preferences["collection_${collection.id}"]
            append(collection.id)
            append(":")
            append(preference?.order ?: Int.MAX_VALUE)
            append(":")
            collection.folders.forEach { folder ->
                append(folder.id)
                append("[")
                folder.resolvedSources.forEach { source ->
                    append(collectionSourceKey(source))
                    append(",")
                }
                append("]")
            }
            append(";")
        }
        append("|addons=")
        addons.forEach { addon ->
            append(addon.manifest?.id.orEmpty())
            append(":")
            append(addon.manifestUrl)
            append(":")
            append(addon.manifest?.catalogs?.size ?: 0)
            append(";")
        }
    }

    private fun collectionSourceKey(source: CollectionSource): String =
        source.catalogRouteKey()
}

private const val HOME_HERO_ITEM_LIMIT = 8

/** Sentinel origin for hero items that came from the collection fallback, not from a catalog. */
internal const val COLLECTION_HERO_ORIGIN = " collectionHero"
/**
 * BUG-42: see `HomeRepository.awaitingFirstRefresh`.
 *
 * Pinned to [HERO_COMMIT_GATE_TIMEOUT_MS] rather than kept at its original 5 s. It used to hold
 * only the hero, so overshooting the gate's budget cost nothing visible; since Wave H holds the
 * ROWS too, this is the entire on-screen budget for a profile whose enabled add-ons declare no
 * catalogs (a subtitle or stream-only add-on plus collections), and such a profile has strictly
 * LESS to wait for than the catalog-bearing one the 4 s budget was sized for. Beyond that the grace
 * can no longer decide anything either: `decideIdleHeroGate` releases `noSources` at the budget, so
 * a longer grace would only leave `awaitingFirstRefresh` set for a second after the gate had
 * already answered, re-holding a collection hero that resolved in that window (`heroPublishSource`
 * reads the flag once the gate is Released). One budget, one answer.
 */
private const val FIRST_REFRESH_GRACE_MS = HERO_COMMIT_GATE_TIMEOUT_MS

/**
 * BUG-35 (beta.12): how many leading items of a row [HomeRepository.requestRowEnrichment]
 * localizes when the row scrolls into view. Covers the on-screen cards (~7 on Home) plus the
 * first step of a horizontal scroll; per-item+language session dedup means a row re-appearing
 * costs nothing. Worst-case fetch volume is this × rows-actually-seen, not × the catalog fan-out.
 */
private const val HOME_ROW_ENRICHMENT_PREFIX = 12
private const val HOME_COLLECTION_HERO_SOURCE_LIMIT = 6
private const val HOME_COLLECTION_HERO_SOURCE_ITEM_LIMIT = 8
private const val HOME_CATALOG_FETCH_BATCH_SIZE = 4
private const val HOME_CATALOG_PREVIEW_FETCH_LIMIT = 18
private const val HOME_CATALOG_PUBLISH_INTERVAL = 2

/**
 * BUG-86 (Wave H, K1b): whether the catalog fan-out publishes after the batch at [batchIndex].
 *
 * The interval exists to bound UI churn during a long fan-out, and it is right for a settled Home:
 * every publish re-runs the hero ranking and re-applies enrichment across every section. It is
 * WRONG while the commit gate is armed. A batch's fetch outcomes are a gate input, and a held
 * publish emits a [HomeUiState] equal to the previous one (previous hero, held rows, still
 * loading), so the StateFlow suppresses it: the "churn" the interval saves is zero, while the
 * evaluation it skips can be the one that would have released the gate. With the default interval
 * of 2 the skipped batches are 2, 4, 6, ...; a hero-source catalog settling in one of those used to
 * wait for the NEXT batch's whole network round trip, and on a slow launch for the rest of the
 * fan-out, which is time taken straight out of the gate's 4 s budget.
 */
internal fun shouldPublishAfterBatch(batchIndex: Int, gateArmed: Boolean): Boolean =
    gateArmed || batchIndex == 0 || (batchIndex + 1) % HOME_CATALOG_PUBLISH_INTERVAL == 0

/**
 * BUG-86 (Codex branch review round 7): what a publish reports as [HomeUiState.isLoading].
 *
 * A HELD publish (`rowsHeld`) is still "assembling" however the catalog fan-out is doing: the rows
 * it republishes are the previous, empty ones on a cold launch, and reporting `false` with no
 * sections would paint the empty state (or, after a partial failure, the error state and its
 * Retry button) for the second or two before the gate releases. Every other publish reports the real
 * thing, and that is the whole rule: the override belongs to the hold, and it ends with the hold.
 *
 * The bug it replaces was the feedback loop, not the formula. `catalogLoadInProgress` used to be a
 * parameter every caller but the fan-out filled in from `_uiState.value.isLoading`, so a publish
 * during the hold read back the value the hold had forced. Once the fan-out finished under an armed
 * gate, `true` was the only value the state could carry from then on, the releasing publish
 * included, and a profile whose hero-source catalogs failed or came back empty was left on the
 * loading placeholder for the rest of the session: nothing republishes with a literal `false` after
 * the fan-out that set it, so the error and empty states below it were unreachable.
 */
internal fun publishedIsLoading(catalogLoadInProgress: Boolean, rowsHeld: Boolean): Boolean =
    catalogLoadInProgress || rowsHeld

/**
 * BUG-86 hero-off rows (beta.18): whether ONE publish republishes the previous rows instead of the
 * ones it just built. The three cases are `publishCurrentStateLocked`'s three branches, in order.
 *
 * The third one is what changed. A publish taken after the hero has committed used to be
 * unconditionally free to publish rows, which is right for every reason except the two that release
 * the hero without consulting an input: a `heroOff` launch releases on its FIRST evaluation, so
 * every publish the launch sync burst then drives is a branch-3 publish, and the rows it reordered
 * went straight to screen underneath the FEAT-15 focus panel. The rows gate's own state carries the
 * hold across those publishes now (see `HeroCommitGate.decideRowsGate`).
 *
 * @param decisionReleased the gate's answer for this publish, or null when the hero already
 *   committed and no decision was taken.
 * @param decisionRowsReleased the ROWS half of that same decision; ignored when there is none.
 * @param wasArmed whether the gate was Armed on entry, i.e. whether a hold here is a hold of
 *   something already painted rather than of the pre-gate initial state.
 * @param rowsGateReleased the repository's rows-gate state, as of this publish's own re-evaluation.
 */
internal fun rowsHeldForPublish(
    decisionReleased: Boolean?,
    decisionRowsReleased: Boolean,
    wasArmed: Boolean,
    rowsGateReleased: Boolean,
): Boolean = when {
    decisionReleased == null -> !rowsGateReleased
    decisionReleased -> !decisionRowsReleased
    else -> wasArmed
}

/**
 * BUG-86 (Wave H): which entries of `HomeRepository.heroItemOrigins` survive a publish.
 *
 * An origin is what makes a committed hero item retainable and freezable, so it must stay alive
 * exactly as long as the thing that supplied the item. For a catalog item that is its definition
 * still being in the definition set. For the collection fallback it is the item still being in
 * `cachedCollectionHeroItems`: `ensureCollectionHeroFallback` empties that cache the moment its
 * request key changes (a different collection set, or different settings behind it), and the
 * superseded fallback hero has to stop being retainable at that moment.
 *
 * The sentinel used to be preserved unconditionally, which pinned the OLD fallback head and kept
 * its payload frozen after the collection behind it was gone. `pruneCommittedPayloadsLocked` could
 * not drop either, so when the replacement fallback arrived `serveCommittedHeroItemsLocked` still
 * saw a non-empty commit map, skipped its re-freeze, and served the new hero unfrozen and unpinned
 * free to be repainted by the next enrichment or sync publish, which is the doubled hero this
 * whole gate exists to prevent.
 */
internal fun retainHeroItemOrigins(
    origins: Map<String, String>,
    knownDefinitionKeys: Set<String>,
    collectionHeroKeys: Set<String>,
): Map<String, String> = origins.filter { (itemKey, definitionKey) ->
    if (definitionKey == COLLECTION_HERO_ORIGIN) {
        itemKey in collectionHeroKeys
    } else {
        definitionKey in knownDefinitionKeys
    }
}

/**
 * BUG-86 (Wave H, K1b): can an enabled addon still turn a persisted hero-source key into a catalog
 * definition?
 *
 * Narrower than `hasPendingEnabledManifests()` (`enabled && isRefreshing`), which the gate used to
 * read, on purpose. `refreshAddon` sets `isRefreshing` on an addon that ALREADY has a manifest, so
 * a plain re-fetch (Settings, the Search/Home retry buttons, a forced refresh) reported "a manifest
 * is pending" even though that addon's catalogs were already in `currentDefinitions` and its answer
 * to the gate could not change. Combined with an unresolved persisted hero-source key (which every
 * long-lived profile accumulates, because `normalizePreferences` KEEPS preferences whose catalog
 * key has gone away), that pinned the gate on `sourcesReady = false` for the length of the slowest
 * re-fetch, and on a loaded machine that outlives the 4 s budget. Only an addon with NO manifest
 * that is still fetching one can produce a new definition, so only that counts as pending.
 */
internal fun List<ManagedAddon>.hasUnresolvedEnabledManifests(): Boolean =
    any { addon -> addon.enabled && addon.manifest == null && addon.isRefreshing }

/**
 * BUG-86 (Wave H): whether a launch sync burst can still land for this account, i.e. whether
 * `LaunchSyncState.Idle` means "not started yet" (the gate waits) or "will never start" (it does
 * not). It is the second factor of the gate's sync term, and therefore a gate INPUT in its own
 * right: `HomeRepository.startGateInputsObserverLocked` collects this boolean off
 * `AuthRepository.state`, because on a signed-out cold launch whose session restore resolves after
 * the catalog fan-out finished, the auth transition is the only event that makes Idle readable as
 * settled. Nothing else republishes then, and the gate could only end at the timeout.
 *
 * A session still restoring counts as expected: it can still resolve to a signed-in account, and
 * the gate's own timeout bounds the wait if the restore stalls. An anonymous account never gets a
 * profile-select pull, so it is not expected either.
 */
internal fun AuthState.launchSyncExpected(): Boolean = when (this) {
    is AuthState.Authenticated -> !isAnonymous
    AuthState.Loading -> true
    AuthState.Unauthenticated -> false
}

/**
 * BUG-86 (Wave H): the one transition that takes the hero commit gate BACKWARDS, out of
 * [HeroGateState.Released] and into [HeroGateState.Armed], when a catalog-bearing refresh arrives.
 *
 * A [HeroGateReason.NO_SOURCES] release is not a hero commit, it is a claim about the profile: no
 * catalog can ever supply a hero here, so holding would pin Home behind a timer that was never
 * armed. Catalogs arriving afterwards falsify the claim, and a gate that stayed Released would
 * leave that hero unpinned and unfrozen for the rest of the session.
 *
 * Every other release IS a commit and is final: `all`, `timeout`, `heroOff` and `reset` all mean a
 * head was chosen and pinned, and re-arming on one of those would let the head move again, which is
 * the whole bug. Only `HomeRepository.clear()` (profile switch, sign-out) and an explicit Hero
 * Sources change may disturb those.
 */
internal fun heroGateShouldRearm(state: HeroGateState, releaseReason: String?): Boolean =
    state == HeroGateState.Released && releaseReason == HeroGateReason.NO_SOURCES

/**
 * Hard cap on how long the hero's METADATA commit waits for TMDB enrichment before publishing raw
 * catalog metadata instead. Hero first paint is a monitored latency metric (BUG-26 / LaunchTrace),
 * so a slow or dead TMDB must degrade to English text rather than leave the hero region empty:
 * 2s covers a warm parallel preview fetch of the whole hero set with room to spare, and past it a
 * localized title is worth less than the blank hero costs. Bounds the hero only — catalog rows
 * publish on the same pass regardless of enrichment state.
 */
private const val HERO_ENRICHMENT_HOLD_TIMEOUT_MS = 2_000L

private fun prioritizeDefinitions(
    definitions: List<HomeCatalogDefinition>,
    snapshot: HomeCatalogSettingsSnapshot,
): List<HomeCatalogDefinition> {
    val orderedDefinitions = definitions.sortedBy { definition ->
        snapshot.preferences[definition.key]?.order ?: Int.MAX_VALUE
    }
    val (priority, remainder) = orderedDefinitions.partition { definition ->
        val preference = snapshot.preferences[definition.key]
        if (preference == null) {
            true
        } else {
            preference.enabled || (snapshot.heroEnabled && preference.heroSourceEnabled)
        }
    }
    return priority + remainder
}
