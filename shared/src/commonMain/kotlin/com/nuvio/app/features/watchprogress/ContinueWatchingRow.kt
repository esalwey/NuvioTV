package com.nuvio.app.features.watchprogress

/**
 * Mirrors mobile's `HomeContinueWatchingMaxRecentProgressItems` (composeApp `HomeScreen.kt`): the
 * number of recent progress entries a Continue Watching row scans before the per-series dedup and
 * completion filters run.
 */
const val ContinueWatchingRowScanLimit = 300

/**
 * Builds the provider-aware Continue Watching row shared by the tvOS surfaces.
 *
 * Applies mobile's two gates that the bare [continueWatchingEntries] call omits — the active
 * provider's dropped/hidden-show filter and its recency window — before delegating to
 * [continueWatchingEntries] for per-series dedup, completed-entry removal, recency sort and the cap.
 * Both gates are seam-driven: a provider that does not implement them contributes no filtering, so
 * Trakt (hidden + window), Simkl (hidden only) and NuvioSync (neither) all fall out of the same call.
 *
 * `ContinueWatchingSortMode` is intentionally absent. This row is entry-only, and for an entry-only
 * row all three sort modes degrade to the same recency order — the modes only differ once next-up
 * placeholders join the list.
 *
 * No next-up construction happens here either: tvOS deliberately has no Up Next row.
 *
 * CW alias fix (REMAINING_FIX #2): a series is grouped under [canonicalSeriesId] — its IMDb id
 * once [ContinueWatchingSeriesIdentity] knows it — so one show stored under a `tmdb:` and a `tt`
 * id is one card, the newest row of both. The stored ids stay as they are.
 */
fun buildContinueWatchingRowEntries(
    entries: List<WatchProgressEntry>,
    isDroppedShow: (contentId: String) -> Boolean,
    recencyCutoffEpochMs: Long?,
    limit: Int = ContinueWatchingRowScanLimit,
    canonicalSeriesId: (String) -> String = ContinueWatchingSeriesIdentity::canonical,
): List<WatchProgressEntry> = entries
    .filterNot { entry -> isDroppedShow(entry.parentMetaId) }
    .filter { entry ->
        recencyCutoffEpochMs == null || entry.lastUpdatedEpochMs >= recencyCutoffEpochMs
    }
    .continueWatchingEntries(limit = limit, canonicalSeriesId = canonicalSeriesId)
