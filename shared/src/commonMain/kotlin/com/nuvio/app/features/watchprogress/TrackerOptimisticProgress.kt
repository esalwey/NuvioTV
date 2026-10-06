package com.nuvio.app.features.watchprogress

import kotlin.math.abs

/*
 * Shared rules for the local playback rows a tracker's Continue Watching projection carries until
 * the tracker's own snapshot catches up ("optimistic" rows): Trakt's overlay in
 * `TraktProgressRepository` and Simkl's `SimklOptimisticProgressOverlay` (CW sync #3/#4).
 *
 * With a tracker as the Watch Progress Source, Continue Watching shows the tracker's snapshot and
 * hides every local row the tracker can represent, so these rows are the only way local playback
 * reaches Home before the tracker confirms it.
 */

/** A row's life with no newer local write — Trakt's `OPTIMISTIC_PROGRESS_TTL_MS`. */
internal const val TrackerOptimisticProgressTtlMs: Long = 3L * 60L * 1_000L

/**
 * A scrobble stop for the title is in flight (with its retries and timeouts): its rows are held at
 * least this long, so a stop that fails slowly still finds them to keep ([TrackerOptimisticFailedStopRetentionMs]).
 * A delivered stop releases the hold again: the rows go back to [TrackerOptimisticProgressTtlMs],
 * counted from the delivery.
 */
internal const val TrackerOptimisticStopInFlightHoldMs: Long = 10L * 60L * 1_000L

/**
 * A scrobble stop for the title failed: the tracker never recorded this viewing, so once the rows
 * expired its next snapshot would put Continue Watching back on the episode it last knew about —
 * the "stayed on the old episode" symptom. The rows stay this long instead, unless the tracker's
 * snapshot confirms or supersedes them first. In memory only: a relaunch drops them.
 */
internal const val TrackerOptimisticFailedStopRetentionMs: Long = 24L * 60L * 60L * 1_000L

/**
 * True when [remote], the tracker's snapshot row for the same episode, confirms [optimistic]: at
 * least as recent (a minute's slack), and completed for a completed row, or within 3 % of its
 * position for one in progress. Trakt's and Simkl's overlays both reconcile with it.
 */
internal fun trackerSnapshotConfirmsOptimisticProgress(
    remote: WatchProgressEntry,
    optimistic: WatchProgressEntry,
): Boolean {
    val normalizedRemote = remote.normalizedCompletion()
    val normalizedOptimistic = optimistic.normalizedCompletion()
    val remoteNewEnough =
        normalizedRemote.lastUpdatedEpochMs >= normalizedOptimistic.lastUpdatedEpochMs - 60_000L
    if (normalizedOptimistic.isEffectivelyCompleted) {
        return normalizedRemote.isEffectivelyCompleted && remoteNewEnough
    }
    val closeEnough = abs(normalizedRemote.progressFraction - normalizedOptimistic.progressFraction) <= 0.03f
    return closeEnough && remoteNewEnough
}
