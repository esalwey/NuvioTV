package com.nuvio.app.features.watched

import com.nuvio.app.core.storage.PayloadFileStore

/**
 * File-backed (Trakt-library / BUG-11 defect class — see [PayloadFileStore]): one string holding
 * every watched marker, growing with the full watch history.
 */
actual object WatchedStorage {
    private const val subdirectory = "Watched"

    private fun payloadKey(profileId: Int) = "watched_payload_$profileId"

    actual fun loadPayload(profileId: Int): String? =
        PayloadFileStore.load(subdirectory, payloadKey(profileId))

    actual fun savePayload(profileId: Int, payload: String) {
        PayloadFileStore.save(subdirectory, payloadKey(profileId), payload)
    }

    /** Sign-out cleanup (called by TvOsAccountDataCleaner). */
    fun deleteAll() = PayloadFileStore.deleteAll(subdirectory)
}
