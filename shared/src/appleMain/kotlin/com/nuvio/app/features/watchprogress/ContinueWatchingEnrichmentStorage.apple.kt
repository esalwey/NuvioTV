package com.nuvio.app.features.watchprogress

import com.nuvio.app.core.storage.PayloadFileStore

/**
 * File-backed (Trakt-library / BUG-11 defect class — see [PayloadFileStore]): each key holds the
 * full next-up + in-progress snapshot for one profile/source, and the row count grows with every
 * show the user has in flight (each row carrying poster/backdrop/logo URLs and episode metadata).
 * Keys arrive fully resolved from ContinueWatchingEnrichmentCache.
 */
actual object ContinueWatchingEnrichmentStorage {
    private const val subdirectory = "ContinueWatchingEnrichment"

    actual fun loadPayload(key: String): String? =
        PayloadFileStore.load(subdirectory, key)

    actual fun savePayload(key: String, payload: String) {
        PayloadFileStore.save(subdirectory, key, payload)
    }

    actual fun removePayload(key: String) =
        PayloadFileStore.remove(subdirectory, key)

    /** Sign-out cleanup (called by TvOsAccountDataCleaner). */
    fun deleteAll() = PayloadFileStore.deleteAll(subdirectory)
}
