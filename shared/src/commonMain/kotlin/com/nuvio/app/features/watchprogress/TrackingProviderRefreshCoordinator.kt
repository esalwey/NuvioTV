package com.nuvio.app.features.watchprogress

import com.nuvio.app.features.tracking.TrackingProviderId

/**
 * "Refresh this provider; if it is the active source, refresh the read models too."
 *
 * Kept as a free function so the rule can be tested without touching the coordinator singleton.
 */
suspend fun coordinateTrackingProviderRefresh(
    providerId: TrackingProviderId,
    refreshProvider: suspend () -> Boolean,
    activeProviderId: () -> TrackingProviderId?,
    refreshActiveReadModels: suspend () -> Boolean,
): Boolean {
    if (!refreshProvider()) return false
    if (activeProviderId() != providerId) return true
    return refreshActiveReadModels()
}
