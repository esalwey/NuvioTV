package com.nuvio.app.features.home

import com.nuvio.app.core.sync.LaunchSyncSignal.LaunchSyncState

/**
 * BUG-86 (Wave H, the hero commit protocol): the pure decision half of the hero commit gate.
 *
 * The doubled hero is a TEMPORAL double: Home publishes a hero built from whichever catalogs
 * happened to have landed, and then the launch sync burst (addons pull, collections pull, home
 * catalog settings pull) reorders the rows, re-normalizes the hero sources and re-fetches the
 * catalogs a second later, so a SECOND, different hero commits on top of the first. The gate is the
 * fix: [HomeRepository] holds the hero (and the rows that move under it) until every input that can
 * still change the head has settled, then commits once and freezes the payload.
 *
 * This file is deliberately free of repository state so the whole decision table is unit testable
 * (`HeroCommitGateTest`); [HomeRepository] only gathers the inputs and applies the outcome.
 */
enum class HeroGateState {
    /** No catalog-bearing refresh has happened yet, so there is nothing to gate. */
    Idle,

    /** A load is in flight and the hero has not committed: publishes keep the previous payload. */
    Armed,

    /** The hero committed. Its payload is frozen and the head is pinned for the session. */
    Released,
}

/** Terminal state of one hero-source catalog's fetch. Both count as "this source has settled". */
enum class CatalogOutcome { Loaded, Failed }

/**
 * Everything the gate is allowed to look at.
 *
 * @param heroEnabled the profile's "Show Hero" setting.
 * @param heroSourceKeys the PERSISTED hero-source preference keys (see
 *   `HomeCatalogSettingsRepository.heroSourceKeys`), which may name catalogs whose addon manifest
 *   is still loading and therefore has no definition yet.
 * @param knownDefinitionKeys the keys of the catalog definitions that currently exist.
 * @param outcomes per definition key, the terminal outcome of its fetch this load.
 * @param manifestsPending true while a key in `heroSourceKeys - knownDefinitionKeys` can still turn
 *   into a real definition, i.e. while an ENABLED addon that has no manifest yet is still fetching
 *   one. An addon that already has a manifest and is merely re-fetching it does NOT count: its
 *   catalogs are already in `knownDefinitionKeys`, so waiting on it can only burn the gate's
 *   budget (see `HomeRepository.hasUnresolvedEnabledManifests`).
 * @param syncState the launch sync burst's state (see `LaunchSyncSignal`).
 * @param launchSyncExpected false when this account cannot get a launch sync at all (signed out or
 *   anonymous), which is what makes [LaunchSyncState.Idle] readable as "settled" rather than
 *   "has not started yet".
 * @param enrichmentPending how many candidate hero items still have a TMDB fetch outstanding.
 * @param candidateEmpty true when the hero candidate list is empty, which can never be a commit.
 *   The candidate is what the publish would actually carry, so it already includes the collection
 *   fallback: a Home whose hero-source catalogs came back empty but whose collection hero resolved
 *   has a NON-empty candidate and commits it (see `heroPublishSource`).
 * @param heroSourcesAllOff true when the profile's stored preferences name catalogs and every one
 *   of them has `heroSourceEnabled = false`: the user deliberately turned every hero source off.
 *   Distinct from an EMPTY [heroSourceKeys] on a profile that simply has no stored selection yet
 *   (`HomeCatalogSettingsRepository.heroSourceKeys` then falls back to the first definitions), and
 *   the difference matters: with every source off no catalog can ever fill the candidate, so
 *   waiting on [candidateEmpty] could only end at the timeout with the same empty hero, four
 *   seconds of held rows later.
 * @param resetRequested an EXPLICIT Hero Sources change from Settings: the user is looking at the
 *   result, so the gate must not make them wait for the burst.
 * @param elapsedMs milliseconds since the gate armed (0 while [HeroGateState.Idle]).
 * @param rowsElapsedMs milliseconds since the repository FIRST evaluated this gate era, armed or
 *   not (BUG-86 hero-off rows, beta.18). Deliberately not [elapsedMs]: the two releases that hold
 *   the rows on their own ([HeroGateReason.HERO_OFF] and [HeroGateReason.NO_SOURCES]) are exactly
 *   the shapes that can answer before, or entirely without, a catalog-bearing refresh, so the only
 *   clock the rows hold can be bounded by is the one that starts at the first evaluation. See
 *   [HeroGateDecision.rowsReleased].
 * @param timeoutMs the hard cap, normally [HERO_COMMIT_GATE_TIMEOUT_MS].
 */
data class HeroGateInputs(
    val heroEnabled: Boolean,
    val heroSourceKeys: Set<String>,
    val knownDefinitionKeys: Set<String>,
    val outcomes: Map<String, CatalogOutcome>,
    val manifestsPending: Boolean,
    val syncState: LaunchSyncState,
    val launchSyncExpected: Boolean = true,
    val enrichmentPending: Int,
    val candidateEmpty: Boolean,
    val heroSourcesAllOff: Boolean = false,
    val resetRequested: Boolean,
    val elapsedMs: Long,
    val rowsElapsedMs: Long = 0,
    val timeoutMs: Long = HERO_COMMIT_GATE_TIMEOUT_MS,
)

/**
 * [state] is [HeroGateState.Released] when the hero may commit now, [HeroGateState.Armed] when it
 * must keep holding. [reason] is non-null exactly when released and is surfaced verbatim in the
 * device probe line (`gate=released:<reason>`) so a held launch is diagnosable from a photo.
 * [waiting] names the FIRST unmet input at this evaluation (see [HeroGateWait]); it rides the probe
 * as `gateWait=` so a `released:timeout` line says which input was late.
 *
 * [rowsReleased] is the ROWS half, and it is not always the same answer as [released] — see
 * [decideHeroGate]'s KDoc for the two reasons where they diverge and why. [rowsWaiting] says which
 * of the rows terms decided it (see [HeroGateRowsWait]); it rides the probe as `rowsWait=`.
 */
data class HeroGateDecision(
    val state: HeroGateState,
    val reason: String?,
    val waiting: String = HeroGateWait.NONE,
    val rowsReleased: Boolean = state == HeroGateState.Released,
    val rowsWaiting: String = HeroGateRowsWait.NONE,
) {
    val released: Boolean get() = state == HeroGateState.Released
}

/**
 * BUG-86 hero-off rows (beta.18): why the ROWS are, or are no longer, held. Values are part of the
 * probe contract (`rowsWait=` in `HomeRepository.heroRankingDebug`), which is what a tester's About
 * pane photo has to show for a "Show Hero off" launch.
 */
object HeroGateRowsWait {
    /** The launch sync burst settled (or was never coming), so the rows order is final. */
    const val SETTLED = "settled"

    /** The burst is still running, or has not started yet and is still expected: rows hold. */
    const val SYNC = "sync"

    /** The rows budget ran out with the burst still outstanding. Diagnosable, never silent. */
    const val TIMEOUT = "timeout"

    /** The rows are not independently gated at this evaluation: they follow the hero decision. */
    const val NONE = "n/a"
    /**
     * Codex beta.18 r3 (P2): the user flipped Show Hero OFF while the launch gate was still armed
     * (or before the first evaluation). That is an explicit action, not a hero-off LAUNCH, so the
     * rows release at once instead of inheriting the launch-sync hold.
     */
    const val TOGGLE = "toggle"
}

/** [decideRowsGate]'s answer: whether the rows may publish, and which term decided it. */
data class RowsGateDecision(val released: Boolean, val waiting: String)

/**
 * BUG-86 hero-off rows (beta.18): the rows half of the gate, as its own two-term table.
 *
 * Extracted from [decideHeroGate] because `HomeRepository` has to apply the SAME rule twice: once
 * inside the publish that releases the hero, and again on every publish after it while the rows are
 * still held (the hero decision is taken exactly once, so there is no second [HeroGateDecision] to
 * read the answer off).
 *
 * @param syncSettled see [syncSettled] — the launch burst has landed, or none is coming.
 * @param rowsElapsedMs see [HeroGateInputs.rowsElapsedMs].
 */
internal fun decideRowsGate(
    syncSettled: Boolean,
    rowsElapsedMs: Long,
    timeoutMs: Long = HERO_COMMIT_GATE_TIMEOUT_MS,
): RowsGateDecision = when {
    // Checked ahead of the timeout on purpose: when both are true at the same evaluation the
    // honest reason in a tester's photo is that the burst landed, not that the budget expired.
    syncSettled -> RowsGateDecision(released = true, waiting = HeroGateRowsWait.SETTLED)
    rowsElapsedMs >= timeoutMs -> RowsGateDecision(released = true, waiting = HeroGateRowsWait.TIMEOUT)
    else -> RowsGateDecision(released = false, waiting = HeroGateRowsWait.SYNC)
}

/**
 * The gate's unmet-input vocabulary, in the order the readiness conjunction checks them. Values are
 * part of the probe contract (`gateWait=` in `HomeRepository.heroRankingDebug`): a timeout release
 * carries the input that was still outstanding when the budget ran out, which is the difference
 * between "the tester's network is slow" and "an event never re-evaluated the gate".
 */
object HeroGateWait {
    /** A tracked hero-source catalog has no terminal fetch outcome yet, or an unresolved persisted
     *  hero-source key can still become a definition because a manifest is still in flight. */
    const val SOURCES = "sources"

    /** The launch sync burst is running, or has not started yet and is still expected. */
    const val SYNC = "sync"

    /** At least one candidate hero item still has a TMDB enrichment fetch outstanding. */
    const val ENRICH = "enrich"

    /** Everything settled but the candidate list is empty, so there is nothing to commit. */
    const val EMPTY = "empty"

    /** Nothing outstanding. */
    const val NONE = "-"
}

/** The five release reasons. Values are part of the probe contract read by test31. */
object HeroGateReason {
    /** Every input settled and there is a non-empty candidate: the normal, healthy commit. */
    const val ALL = "all"

    /** Hero is off for this profile, so there is nothing to gate. */
    const val HERO_OFF = "heroOff"

    /** The user changed Hero Sources explicitly and must see the result now. */
    const val RESET = "reset"

    /** [HERO_COMMIT_GATE_TIMEOUT_MS] elapsed. Visible in the probe, never silent. */
    const val TIMEOUT = "timeout"

    /** No catalog can ever supply a hero here (collection-only or add-on-less profile). */
    const val NO_SOURCES = "noSources"
}

/**
 * Hard cap on how long the hero holds before it commits whatever it has.
 *
 * Sized from the cold-launch trace behind BUG-86: the launch sync burst landed about 2 s after the
 * load started, and the burst itself is 5 sequential RPCs plus 4 parallel ones, roughly 1 to 2.5 s
 * on home Wi-Fi. 4 s therefore covers a healthy launch with margin while still bounding the worst
 * case to something a user reads as "loading" rather than "broken". A timeout is never a guarantee,
 * which is why it is reported: the release reason rides the probe line as
 * `gate=released:timeout`, so a slow network shows up in the tester's photo instead of silently
 * degrading into the very double-commit this gate exists to prevent.
 */
const val HERO_COMMIT_GATE_TIMEOUT_MS = 4_000L

/**
 * The Idle half of the decision table: what a publish that lands BEFORE the first catalog-bearing
 * refresh is allowed to do.
 *
 * Before that refresh there is genuinely nothing to decide. A profile whose add-ons are still
 * fetching their manifests looks exactly like one that will never have a catalog at all, and
 * releasing [HeroGateReason.NO_SOURCES] here would commit an empty hero on every launch, ahead of
 * the manifests. So the answer is to hold. The point of this function is that the hold is BOUNDED,
 * by the same budget every other launch shape gets.
 *
 * It was not, and that was a real regression. The gate's own [HERO_COMMIT_GATE_TIMEOUT_MS] timer is
 * armed by the first catalog-bearing refresh, so a profile whose enabled add-ons declare no
 * catalogs (a subtitle or stream-only add-on plus collections) never arms it: the only exit was the
 * separate first-refresh grace. Since Wave H holds the ROWS as well as the hero, that grace became
 * a full-screen "Setting up your catalogs..." on every launch of such a profile, for LONGER than a
 * catalog-bearing profile is ever held, even though the catalog-less one has strictly less to wait
 * for. Past the budget the honest answer is the one the post-grace path already gives: no catalog
 * can supply a hero here, so release `noSources` and let the rows and the collection fallback
 * through.
 *
 * @param awaitingFirstRefresh whether the first catalog-bearing refresh is still outstanding.
 * @param idleElapsedMs milliseconds since the FIRST publish evaluated in this Idle era, which is
 *   the closest the Idle path has to the armed path's "since the gate armed".
 * @param timeoutMs the hard cap, normally [HERO_COMMIT_GATE_TIMEOUT_MS].
 * @return the hold decision, or null when the caller must fall through to [decideHeroGate] with an
 *   empty definition set, which releases [HeroGateReason.NO_SOURCES].
 */
fun decideIdleHeroGate(
    awaitingFirstRefresh: Boolean,
    idleElapsedMs: Long,
    timeoutMs: Long = HERO_COMMIT_GATE_TIMEOUT_MS,
): HeroGateDecision? = if (awaitingFirstRefresh && idleElapsedMs < timeoutMs) {
    HeroGateDecision(state = HeroGateState.Armed, reason = null, waiting = HeroGateWait.SOURCES)
} else {
    null
}

/**
 * The gate's whole decision table. Order matters and is part of the contract:
 * hero off, then explicit reset, then timeout, then the readiness conjunction.
 *
 * BUG-86 hero-off rows (beta.18) — why the ROWS can outlive the hero decision.
 *
 * Two of the five reasons answer the hero question WITHOUT consulting a single input:
 * [HeroGateReason.HERO_OFF] (there is no hero to commit) and [HeroGateReason.NO_SOURCES] (no
 * catalog can ever supply one). Both are correct about the hero and both used to open the rows with
 * it, because the rows rode the same boolean. They are not correct about the rows.
 *
 * The rows come out of the very settings the launch sync burst rewrites — `HomeCatalogSettings`'
 * per-catalog `enabled`/`order` and the collection set — so a rows publish taken before the burst
 * lands is a publish of an order that is about to change. On a "Show Hero" OFF profile that is not
 * a cosmetic reshuffle: the top of Home is the FEAT-15 focus panel, whose resting title is the
 * FIRST item of the FIRST catalog row, so reordering the rows underneath repaints the panel with a
 * different title. That is the tester's build-117 photo exactly — rows open at 1.7 s with a
 * collection first, the burst reorders at 2.5 s with a catalog first, and the panel's cover changes
 * with it. The doubled hero this gate was built for, one layer down.
 *
 * So for those two reasons alone the rows keep waiting on [syncSettled], bounded by the same
 * [HeroGateInputs.timeoutMs] budget everything else gets (measured from
 * [HeroGateInputs.rowsElapsedMs], which unlike [HeroGateInputs.elapsedMs] also ticks for a profile
 * that never arms the gate). Every other reason IS a hero commit taken with the burst already
 * folded in, so its rows release with it and [HeroGateDecision.rowsWaiting] reads
 * [HeroGateRowsWait.NONE].
 */
fun decideHeroGate(inputs: HeroGateInputs): HeroGateDecision {
    // Computed before the early returns so a TIMEOUT release can still report what it was waiting
    // on. That is the whole diagnostic value of the probe's `gateWait=` field: a timeout with
    // `gateWait=sync` is a slow network, a timeout with `gateWait=-` means every input was ready
    // and something failed to re-evaluate the gate.
    val waiting = firstUnmetInput(inputs)

    if (!inputs.heroEnabled) return releasedHeroRowsGated(HeroGateReason.HERO_OFF, inputs)
    if (inputs.resetRequested) return released(HeroGateReason.RESET)
    if (inputs.elapsedMs >= inputs.timeoutMs) return released(HeroGateReason.TIMEOUT, waiting)

    val trackedKeys = inputs.heroSourceKeys.intersect(inputs.knownDefinitionKeys)

    // Nothing to wait for and nothing that can still arrive: a collection-only profile, or one
    // whose add-ons are all gone. Holding would pin Home on the timeout for no reason.
    if (trackedKeys.isEmpty() && inputs.knownDefinitionKeys.isEmpty() && !inputs.manifestsPending) {
        return releasedHeroRowsGated(HeroGateReason.NO_SOURCES, inputs)
    }

    return if (waiting == HeroGateWait.NONE) {
        released(HeroGateReason.ALL)
    } else {
        HeroGateDecision(state = HeroGateState.Armed, reason = null, waiting = waiting)
    }
}

/**
 * The readiness conjunction, reported as the FIRST unmet term instead of a bare boolean.
 *
 * Order is diagnostic, not arbitrary: an empty candidate list is a SYMPTOM of unloaded sources, so
 * `sources` is reported ahead of `empty`, and a launch that reports `empty` really does have every
 * catalog settled and nothing to show.
 */
private fun firstUnmetInput(inputs: HeroGateInputs): String {
    val trackedKeys = inputs.heroSourceKeys.intersect(inputs.knownDefinitionKeys)
    val unknownKeys = inputs.heroSourceKeys - inputs.knownDefinitionKeys
    // A persisted hero-source key with no definition yet is only a reason to wait while a manifest
    // that could still supply it is loading. Once the manifests have settled, that key names a
    // catalog this profile simply does not have any more and can never produce an outcome.
    val sourcesReady = trackedKeys.all { key -> key in inputs.outcomes } &&
        (unknownKeys.isEmpty() || !inputs.manifestsPending)
    if (!sourcesReady) return HeroGateWait.SOURCES

    if (!syncSettled(inputs)) return HeroGateWait.SYNC

    if (inputs.enrichmentPending != 0) return HeroGateWait.ENRICH
    // An empty candidate is worth waiting on only while a hero SOURCE could still fill it. Once the
    // user has turned every hero source off AND the definition set is final (no manifest can still
    // arrive with catalogs that would default into the free slots), nothing will ever arrive:
    // holding here would spend the whole budget and then commit the same empty hero, with Home's
    // rows held behind it the entire time. Releasing instead lets the publish fall through to the
    // collection fallback (see [heroPublishSource]), which is the only hero such a profile can have.
    if (inputs.candidateEmpty && !(inputs.heroSourcesAllOff && !inputs.manifestsPending)) {
        return HeroGateWait.EMPTY
    }
    return HeroGateWait.NONE
}

/**
 * The sync term of the readiness conjunction, as one function so [firstUnmetInput] and the rows
 * half ([decideHeroGate], [decideRowsGate]) can never drift apart on what "the burst has landed"
 * means. [HeroGateInputs.launchSyncExpected] is the half that makes [LaunchSyncState.Idle] readable
 * as "will never start" rather than "has not started yet".
 */
internal fun syncSettled(syncState: LaunchSyncState, launchSyncExpected: Boolean): Boolean =
    when (syncState) {
        LaunchSyncState.NotApplicable, LaunchSyncState.Settled -> true
        LaunchSyncState.Idle -> !launchSyncExpected
        LaunchSyncState.Running -> false
    }

internal fun syncSettled(inputs: HeroGateInputs): Boolean =
    syncSettled(inputs.syncState, inputs.launchSyncExpected)

/** A release whose ROWS go with it: the hero committed with the burst already folded in. */
private fun released(reason: String, waiting: String = HeroGateWait.NONE) =
    HeroGateDecision(
        state = HeroGateState.Released,
        reason = reason,
        waiting = waiting,
        rowsReleased = true,
        rowsWaiting = HeroGateRowsWait.NONE,
    )

/**
 * A release that answers the HERO question without consulting an input ([HeroGateReason.HERO_OFF],
 * [HeroGateReason.NO_SOURCES]) and therefore has to decide the rows separately — see
 * [decideHeroGate]'s KDoc.
 */
private fun releasedHeroRowsGated(reason: String, inputs: HeroGateInputs): HeroGateDecision {
    val rows = decideRowsGate(
        syncSettled = syncSettled(inputs),
        rowsElapsedMs = inputs.rowsElapsedMs,
        timeoutMs = inputs.timeoutMs,
    )
    return HeroGateDecision(
        state = HeroGateState.Released,
        reason = reason,
        // The HERO waited on nothing here, and `gateWait=` describes the hero. The rows' own
        // outstanding term rides `rowsWait=` instead, so the two stay separately readable.
        waiting = HeroGateWait.NONE,
        rowsReleased = rows.released,
        rowsWaiting = rows.waiting,
    )
}

/** Which list a publish's hero items come from. See [heroPublishSource]. */
enum class HeroPublishSource {
    /** "Show Hero" is off for this profile: the hero region is empty by configuration. */
    Off,

    /** The hero-source catalogs produced a selection, which is what the hero normally is. */
    Catalog,

    /** Nothing may commit yet, so the PREVIOUS hero is republished unchanged. */
    Held,

    /** No catalog hero and nothing holding: the collection fallback is this Home's hero. */
    CollectionFallback,
}

/**
 * Where one publish's hero comes from, given the gate's decision for that SAME publish.
 *
 * The order of the branches is the contract, and so is the caller's order of operations: the gate
 * must be asked BEFORE this is evaluated. It used to be the other way round. The published list
 * was chosen while the gate was still Armed and the gate was then released later in the same
 * publish, so a Home whose hero-source catalogs came back empty could never show its collection
 * fallback: the [Held] branch republished the previous (empty) hero, the timeout released on that
 * empty list, and the commit froze it. Nothing published afterwards, because the fan-out was over
 * and the gate's watchers were cancelled at release, so the collection hero stayed missing for the
 * rest of the session. Deciding first makes a release fall through to [CollectionFallback] in the
 * very publish that releases.
 *
 * @param holding whether this publish must keep the previous payload: while the gate is Armed that
 *   is the gate's own answer; after the commit it is the legacy BUG-42 mid-load hold, which now
 *   covers newcomers only.
 * @param resetRequested an explicit Hero Sources change, which outranks the hold: the user is
 *   looking at the result, so a stale hero must leave now.
 */
fun heroPublishSource(
    heroEnabled: Boolean,
    catalogHeroEmpty: Boolean,
    holding: Boolean,
    resetRequested: Boolean,
): HeroPublishSource = when {
    !heroEnabled -> HeroPublishSource.Off
    !catalogHeroEmpty -> HeroPublishSource.Catalog
    holding && !resetRequested -> HeroPublishSource.Held
    else -> HeroPublishSource.CollectionFallback
}
