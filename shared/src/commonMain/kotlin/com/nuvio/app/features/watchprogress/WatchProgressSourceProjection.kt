package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.tracking.TrackingProgressSnapshot
import com.nuvio.app.features.tracking.WatchProgressSource

/**
 * Chooses the entry list the active source owns.
 *
 * Fork note: upstream returns the provider projection verbatim once a provider is active, because
 * their anime ids are handled by a second provider. The fork keeps the shipped behaviour of
 * merging in local-only rows whose ids the active provider can never return (`kitsu:`, `mal:`,
 * `anilist:`) — otherwise those titles vanish from continue watching while Trakt is the source.
 * [canProviderRepresent] comes from `TrackingProgressProvider.canRepresentContentId`.
 */
fun projectWatchProgressSourceEntries(
    source: WatchProgressSource,
    nuvioEntries: Collection<WatchProgressEntry>,
    providerEntries: Collection<WatchProgressEntry>,
    canProviderRepresent: (String) -> Boolean = { true },
): List<WatchProgressEntry> {
    if (source.providerId == null) return nuvioEntries.toList()

    val localOnlyEntries = nuvioEntries.filterNot { entry -> canProviderRepresent(entry.parentMetaId) }
    if (localOnlyEntries.isEmpty()) return providerEntries.toList()

    val providerKeys = providerEntries.mapTo(mutableSetOf()) { entry -> entry.resolvedProgressKey() }
    val merged = providerEntries.toMutableList()
    localOnlyEntries.forEach { localEntry ->
        if (localEntry.resolvedProgressKey() !in providerKeys) {
            merged += localEntry
        }
    }
    return merged
}

fun projectWatchProgressUiState(
    source: WatchProgressSource,
    entries: List<WatchProgressEntry>,
    providerSnapshot: TrackingProgressSnapshot?,
    hasLoadedNuvioRemoteProgress: Boolean,
    seriesIdentityVersion: Long = 0L,
): WatchProgressUiState = WatchProgressUiState(
    source = source,
    entries = entries,
    hiddenContentIds = providerSnapshot?.hiddenContentIds.orEmpty(),
    hasLoadedRemoteProgress =
        providerSnapshot?.hasLoadedRemoteProgress ?: hasLoadedNuvioRemoteProgress,
    seriesIdentityVersion = seriesIdentityVersion,
)

/**
 * BUG-76: every show the user has progress on, regardless of which source is active — local ∪
 * **every registered provider's** snapshot, deduped on [resolvedProgressKey] keeping the most
 * recently updated row.
 *
 * [providerEntries] deliberately spans *all* progress providers, not just the active one: a show
 * imported from Trakt lives in Trakt's snapshot and never in the local store, so unioning with the
 * active provider alone would still drop it the moment the user switches to Simkl — which is the
 * exact scenario this exists to survive.
 *
 * The deliberate contrast with [projectWatchProgressSourceEntries] above: that answers "what
 * should Continue Watching show?" and is therefore source-scoped, correctly going empty when the
 * active provider has no history. This answers "which shows does this user follow?", which no
 * source flip should change. `UpcomingEpisodesRepository` seeds its air-date sweep from progress ∪
 * library and needs the second question — while it asked the first, a Trakt→Simkl flip emptied
 * half the seed and took down a row that only depends on the Library.
 */
fun unionFollowedShowEntries(
    nuvioEntries: Collection<WatchProgressEntry>,
    providerEntries: Collection<WatchProgressEntry>,
): List<WatchProgressEntry> {
    if (providerEntries.isEmpty()) return nuvioEntries.toList()
    if (nuvioEntries.isEmpty() && providerEntries.distinctBy { it.resolvedProgressKey() }.size == providerEntries.size) {
        return providerEntries.toList()
    }
    // Most-recent wins rather than "the provider wins": [providerEntries] may span SEVERAL
    // providers (see the KDoc), and registry iteration order must not decide which row survives.
    val byKey = LinkedHashMap<String, WatchProgressEntry>()
    (providerEntries.asSequence() + nuvioEntries.asSequence()).forEach { entry ->
        val key = entry.resolvedProgressKey()
        val existing = byKey[key]
        if (existing == null || entry.lastUpdatedEpochMs > existing.lastUpdatedEpochMs) {
            byKey[key] = entry
        }
    }
    return byKey.values.toList()
}
