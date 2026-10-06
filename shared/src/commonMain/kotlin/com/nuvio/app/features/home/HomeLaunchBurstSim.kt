package com.nuvio.app.features.home

import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.collection.CollectionSyncService
import kotlin.concurrent.Volatile
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * BUG-86: a deterministic, offline reproduction of the LAUNCH SYNC BURST that doubles the hero on a
 * tester's TV and never on ours.
 *
 * The bug needs a signed-in profile whose cloud pull lands a second or two after Home first paints:
 * the addons pull changes the addon signature (forced refresh), the home-catalog-settings pull
 * rewrites every row `order` and re-normalizes the hero sources, and the collections pull re-emits
 * the collection set. Our sim fixture has none of that (one seeded add-on, no signed-in sync), so
 * every publish there is `isLoading = true` and the holes never open. This object replays the same
 * three events, in the same order, against whatever profile is loaded, plus the two aggravators the
 * video showed: a hero-source catalog that fails its first fetch, and slow TMDB enrichment.
 *
 * On the UNFIXED code (before Wave H) this deterministically yields the red baseline the gate is
 * measured against: a `rows` reorder, a `paint ... same=1`, a head payload hash change, and
 * `inRows=0` then `inRows=1 headChanged=1`. On the fixed code the burst arrives after the gate has
 * released and nothing repaints.
 *
 * INERT unless [arm] is called. tvOS arms it from `-debug.homeLaunchBurstSim YES`, honoured only
 * alongside `-debug.homeHeroProbe YES`.
 *
 * WARNING, debug builds and disposable fixtures only: the burst PERSISTS its mutations locally. It
 * reverses the profile's Home row order and its collection order and turns "hide unreleased
 * content" on, exactly as an incoming remote payload would. Nothing is pushed to the server (see
 * [runBurst]), so the next real pull restores the account's true state, but do not arm this on a
 * profile whose local ordering you care about.
 *
 * Swift: `HomeLaunchBurstSim.shared.arm(burstAfterFirstPublishMs:failFirstHeroSources:enrichmentDelayMs:)`.
 * Kotlin default arguments are not exported to Objective-C, so Swift passes all three.
 */
object HomeLaunchBurstSim {
    private val log = Logger.withTag("HomeLaunchBurstSim")

    /**
     * Definition keys whose NEXT catalog fetch must throw. `HomeRepository.toSection` consumes the
     * key as it throws, so the retry succeeds and the gate sees Failed then Loaded.
     */
    @Volatile
    var catalogFirstFetchFailKeys: Set<String> = emptySet()

    /** Artificial latency added before every TMDB preview-enrichment batch. 0 disables it. */
    @Volatile
    var enrichmentDelayMs: Long = 0L

    @Volatile
    private var armed: Boolean = false

    /**
     * Arms the simulation. Idempotent: a second call while armed is ignored, so wiring it to an
     * app-launch hook that can run twice is safe.
     *
     * @param burstAfterFirstPublishMs delay between Home's first non-empty hero publish and the
     *   burst. 1 s matches the 1.1 s gap measured between the two Home builds in IMG_8455.
     * @param failFirstHeroSources make the first persisted hero-source catalog fail its first fetch.
     * @param enrichmentDelayMs latency to add to TMDB enrichment. 2.5 s is past the legacy 2 s
     *   enrichment hold, which is what forces the raw-then-enriched publish on unfixed code.
     */
    fun arm(
        burstAfterFirstPublishMs: Long = 1_000,
        failFirstHeroSources: Boolean = true,
        enrichmentDelayMs: Long = 2_500,
    ) {
        if (armed) return
        armed = true
        this.enrichmentDelayMs = enrichmentDelayMs
        if (failFirstHeroSources) {
            catalogFirstFetchFailKeys = HomeCatalogSettingsRepository.heroSourceKeys()
                .take(1)
                .toSet()
        }
        log.i {
            "armed burstAfter=${burstAfterFirstPublishMs}ms failKeys=$catalogFirstFetchFailKeys " +
                "enrichmentDelay=${enrichmentDelayMs}ms"
        }
        HomeRepository.launchBurstSimTask { runBurst(burstAfterFirstPublishMs) }
    }

    /**
     * Consumed by `HomeRepository.toSection`. Not atomic on purpose: this is debug-only code, and a
     * duplicate failure for the same key would only make the simulated launch harsher.
     */
    internal fun consumeFirstFetchFailure(definitionKey: String): Throwable? {
        val keys = catalogFirstFetchFailKeys
        if (definitionKey !in keys) return null
        catalogFirstFetchFailKeys = keys - definitionKey
        return IllegalStateException("HomeLaunchBurstSim: simulated first-fetch failure for $definitionKey")
    }

    private suspend fun runBurst(burstAfterFirstPublishMs: Long) {
        val painted = withTimeoutOrNull(FIRST_PUBLISH_TIMEOUT_MS) {
            HomeRepository.uiState.first { state -> state.heroItems.isNotEmpty() }
        }
        log.i { "first hero publish ${if (painted == null) "TIMED OUT" else "seen"}, bursting in ${burstAfterFirstPublishMs}ms" }
        delay(burstAfterFirstPublishMs)

        // 1. Addons pull: a server-supplied user set name changes every descriptor and forces a
        //    full refresh. This is the prune path (Hole E) and it is a pure read of the addon list,
        //    so it writes nothing back to AddonRepository and triggers no push.
        val ready = AddonRepository.uiState.value.addons
            .enabledAddons()
            .filter { addon -> addon.manifest != null }
            .map { addon -> addon.copy(userSetName = "sim-" + addon.manifestUrl.hashCode()) }
        log.i { "burst step 1: refresh(force) with ${ready.size} renamed addons" }
        HomeRepository.refresh(addons = ready, force = true)

        // 2. Home catalog settings pull: every row order reversed and the unreleased filter turned
        //    on, which is what re-normalizes the hero sources (Hole D) and release-filters the head
        //    (Hole C). applyFromRemote persists locally and never pushes.
        val payload = HomeCatalogSettingsRepository.exportToSyncPayload()
        log.i { "burst step 2: applyFromRemote with ${payload.items.size} reversed items" }
        HomeCatalogSettingsRepository.applyFromRemote(
            payload.copy(
                hideUnreleasedContent = true,
                items = payload.items
                    .reversed()
                    .mapIndexed { index, item -> item.copy(order = index) },
            )
        )

        // 3. Collections pull: a re-emission of the collection set in a different order. This one
        //    CAN reach the server, because CollectionRepository.setCollections emits a local change
        //    event that CollectionSyncService debounces and pushes. Holding the service's own
        //    remote-apply flag across the whole debounce window is what makes the sim read-only:
        //    the flag is checked when the debounced event fires, not when it is emitted.
        val wasSyncingFromRemote = CollectionSyncService.isSyncingFromRemote
        CollectionSyncService.isSyncingFromRemote = true
        try {
            val reversed = CollectionRepository.collections.value.reversed()
            log.i { "burst step 3: setCollections with ${reversed.size} reversed collections (push suppressed)" }
            CollectionRepository.setCollections(reversed)
            delay(PUSH_SUPPRESSION_MS)
        } finally {
            CollectionSyncService.isSyncingFromRemote = wasSyncingFromRemote
        }
        log.i { "burst complete" }
    }
}

/** How long to wait for Home's first non-empty hero before bursting anyway. */
private const val FIRST_PUBLISH_TIMEOUT_MS = 6_000L

/**
 * Longer than CollectionSyncService's own 1.5 s push debounce, so the suppression flag is still
 * set when the debounced local-change event fires.
 */
private const val PUSH_SUPPRESSION_MS = 3_000L
