package com.nuvio.app.features.home

import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.catalog.CatalogTarget

data class MetaPreview(
    val id: String,
    val type: String,
    val name: String,
    val poster: String? = null,
    val banner: String? = null,
    val logo: String? = null,
    val posterShape: PosterShape = PosterShape.Poster,
    val description: String? = null,
    val releaseInfo: String? = null,
    val rawReleaseDate: String? = null,
    val popularity: Double? = null,
    val voteCount: Int? = null,
    val imdbRating: String? = null,
    val genres: List<String> = emptyList(),
)

fun MetaPreview.stableKey(): String = "$type:$id"

enum class PosterShape {
    Poster,
    Square,
    Landscape,
}

data class HomeCatalogSection(
    val key: String,
    val title: String,
    val subtitle: String,
    val addonName: String,
    val target: CatalogTarget,
    val items: List<MetaPreview>,
    val availableItemCount: Int = items.size,
    val hasMore: Boolean = false,
)

fun HomeCatalogSection.canOpenCatalog(previewLimit: Int): Boolean =
    availableItemCount > previewLimit || hasMore

data class HomeUiState(
    val isLoading: Boolean = false,
    val heroItems: List<MetaPreview> = emptyList(),
    val sections: List<HomeCatalogSection> = emptyList(),
    val errorMessage: String? = null,
    /**
     * BUG-86 (Wave H): false while the hero commit gate is still holding, i.e. while [heroItems]
     * and [sections] are the PREVIOUS payload republished unchanged rather than the current
     * candidate. tvOS's HomeViewModel holds its own assignment on this flag so the hero and the
     * rows under it paint exactly once, in their final order. See `HeroCommitGate`.
     */
    val heroGateReleased: Boolean = false,
    /**
     * Why the gate released, one of `HeroGateReason` (`all`, `heroOff`, `reset`, `timeout`,
     * `noSources`). Null while still holding. Rides the device probe line as `gate=released:<x>`.
     */
    val heroGateReason: String? = null,
    /**
     * BUG-86 hero-off rows (beta.18): false while the ROWS are still held even though the hero
     * decision has already released. Only the two hero reasons that answer without consulting an
     * input can produce that — `heroOff` and `noSources` (see `decideHeroGate`'s KDoc) — and on a
     * "Show Hero" OFF profile it is the difference between the FEAT-15 focus panel painting its
     * resting title once and painting a different one a second later when the launch sync burst
     * reorders the rows underneath it.
     *
     * Appended, never inserted: the About-pane probe line and `test31` are both parsed positionally
     * by humans, and Kotlin/Native does not carry default arguments into the ObjC initializer, so
     * every existing construction site has to keep its shape.
     */
    val rowsGateReleased: Boolean = true,
    /**
     * Which rows term decided it, one of `HeroGateRowsWait` (`settled`, `sync`, `timeout`, `n/a`).
     * Rides the device probe line as `rowsWait=`.
     */
    val rowsGateReason: String? = null,
) {
    /**
     * `HomeRepository.heroRankingDebug` as it read at the instant THIS state was published.
     *
     * The probe line used to interleave two clocks: the frontend logged a published state on the
     * main thread and then read the repository's live debug string to describe it, so every field
     * in the line (`gate=`, `gateWait=`, `sync=`, `hold=`, `sources=`, `head=`, `prune=`, `rearm=`)
     * could describe a LATER repository state than the `state` it was printed next to. The
     * direction of that skew is a false PASS: a held publish printing `gate=released:all` because
     * the gate released during the dispatch hop reads as a healthy launch in a tester's photo, and
     * a held launch is exactly what the probe exists to catch.
     *
     * Deliberately a body property, not a constructor parameter, on both counts that matter:
     *
     * 1. It is EXCLUDED from `equals`/`hashCode`. Wave H's publish cadence leans on StateFlow
     *    suppressing equal states (a held publish emits an equal [HomeUiState], and every gate
     *    re-evaluation during the hold is one); folding a per-publish diagnostic string into
     *    equality would turn each of those back into a real emission.
     * 2. It keeps the exported initializer's shape, so existing Kotlin and Swift construction sites
     *    are untouched. Kotlin/Native does not carry default arguments into the ObjC initializer.
     *
     * The cost is that `copy()` does not carry it; the one copy site in `HomeRepository.refresh`
     * re-stamps it explicitly. Written once, before the instance is assigned to the state flow, so
     * it never mutates under a reader.
     */
    var heroRankingDebugSnapshot: String? = null
        internal set
}

data class CatalogRequest(
    val addon: ManagedAddon,
    val catalogId: String,
    val catalogName: String,
    val type: String,
    val supportsPagination: Boolean,
)
