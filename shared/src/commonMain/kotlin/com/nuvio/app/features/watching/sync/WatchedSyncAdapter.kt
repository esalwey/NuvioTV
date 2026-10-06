package com.nuvio.app.features.watching.sync

import com.nuvio.app.features.watched.WatchedItem
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf

data class WatchedDeltaEvent(
    val eventId: Long,
    val operation: String,
    val contentId: String,
    val contentType: String,
    val title: String,
    val season: Int?,
    val episode: Int?,
    val watchedAt: Long,
)

interface WatchedSyncAdapter {
    suspend fun pull(
        profileId: Int,
        pageSize: Int,
    ): List<WatchedItem>

    /**
     * Fully-watched series keys the provider tracks separately from individual watched items.
     * `null` means "this adapter has no opinion" and leaves the current set untouched — which is
     * every adapter the fork ships today (Nuvio Sync and Trakt both derive the set locally).
     */
    suspend fun pullFullyWatchedSeriesKeys(profileId: Int): Set<String>? = null

    /**
     * Extra watched keys the provider knows a title is *also* addressable by (alternate ids and
     * type aliases). They join the published watched-key set without producing additional watched
     * items, so a lookup under a different id still reads as watched and continue watching stays
     * free of duplicates. Upstream fed this from Simkl's anime ids; the fork's producer is Trakt.
     */
    suspend fun pullExtraWatchedKeys(profileId: Int): Set<String> = emptySet()

    /**
     * Reactive form of [pullExtraWatchedKeys] that re-emits when the provider's own state changes
     * (after a mutation or a sync). Adapters with no alternate-id story keep the empty default.
     */
    fun observeExtraWatchedKeys(profileId: Int): Flow<Set<String>> = flowOf(emptySet())

    suspend fun getDeltaCursor(profileId: Int): Long? = null

    suspend fun pullDelta(
        profileId: Int,
        sinceEventId: Long,
        limit: Int,
    ): List<WatchedDeltaEvent> = emptyList()

    suspend fun push(
        profileId: Int,
        items: Collection<WatchedItem>,
    )

    suspend fun delete(
        profileId: Int,
        items: Collection<WatchedItem>,
    )
}
