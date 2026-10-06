package com.nuvio.app.features.watched

import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.WatchProgressSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ported from upstream's `WatchedRepositoryTest` additions in `e0cbf447` and `7a491570` only —
 * the fork already has a large, pre-existing `WatchedRepositoryTest` in `composeApp/src/commonTest`
 * that must keep compiling untouched. This file covers just the new [watchedProviderRefreshOrNull]
 * and [extraWatchedKeysChanged] cases; named distinctly so it can never collide with the
 * composeApp class. Also carries upstream's `eb2d5d3a`/`3acbe6f2` additions (provider snapshot
 * acknowledgement + oversized-payload guard).
 */
class WatchedRepositoryHelpersTest {
    @Test
    fun oversizedLegacyPayload_isNotRestored() {
        assertTrue(shouldRestoreWatchedPayload(4 * 1024 * 1024))
        assertFalse(shouldRestoreWatchedPayload(4 * 1024 * 1024 + 1))
    }

    @Test
    fun successfulTrackerPush_waitsForRemoteSnapshotAcknowledgement() {
        val outcome = WatchedPushOutcome(
            succeededTrackerProviderIds = setOf(TrackingProviderId.TRAKT),
        )

        assertFalse(shouldAcknowledgeNuvioWatchedPush(WatchProgressSource.TRAKT, outcome))
    }

    @Test
    fun providerSnapshot_acknowledgesPendingMarkByPresence() {
        val localItem = WatchedItem(
            id = "pending",
            type = "movie",
            name = "pending",
            markedAtEpochMs = 1_999L,
        )
        val remoteItem = localItem.copy(markedAtEpochMs = 1_000L)
        val key = watchedItemKey(localItem.type, localItem.id)

        val merged = mergeWatchedSnapshot(
            serverItems = listOf(remoteItem),
            localItems = listOf(localItem),
            dirtyKeys = setOf(key),
            acknowledgeDirtyByPresence = true,
        )

        assertEquals(mapOf(key to remoteItem), merged.items)
        assertTrue(merged.dirtyKeys.isEmpty())
    }

    @Test
    fun emptyProviderExtraKeys_doNotTriggerInitialRefresh() {
        assertFalse(extraWatchedKeysChanged(previous = null, current = emptySet()))
    }

    @Test
    fun populatedProviderExtraKeys_triggerRefreshFromEmptyState() {
        assertTrue(extraWatchedKeysChanged(previous = null, current = setOf("series:tt1:-1:-1")))
    }

    @Test
    fun changedProviderExtraKeys_triggerRefresh() {
        assertTrue(
            extraWatchedKeysChanged(
                previous = setOf("series:tt1:-1:-1"),
                current = setOf("series:tt2:-1:-1"),
            ),
        )
    }

    @Test
    fun providerRefreshFailure_isContainedWithoutReplacingState() = runBlocking {
        val failure = IllegalStateException("rate limited")
        var observedFailure: Throwable? = null

        val result = watchedProviderRefreshOrNull(
            refresh = { throw failure },
            onFailure = { observedFailure = it },
        )

        assertNull(result)
        assertEquals(failure, observedFailure)
    }

    @Test
    fun providerRefreshCancellation_isNotContained() = runBlocking {
        assertFailsWith<CancellationException> {
            watchedProviderRefreshOrNull(
                refresh = { throw CancellationException("cancelled") },
                onFailure = {},
            )
        }
        Unit
    }
}
