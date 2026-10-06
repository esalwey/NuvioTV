package com.nuvio.app.features.watchprogress

import com.nuvio.app.core.storage.PayloadFileStore

/**
 * File-backed (Trakt-library / BUG-11 defect class — see [PayloadFileStore]): one string holding
 * the full watch-progress history, growing with every item ever played — ~191KB on the Living
 * Room device (2026-08-01).
 */
actual object WatchProgressStorage {
    private const val subdirectory = "WatchProgress"
    private const val payloadKey = "watch_progress_payload"

    actual fun loadPayload(profileId: Int): String? =
        PayloadFileStore.load(subdirectory, "${payloadKey}_$profileId")

    actual fun savePayload(profileId: Int, payload: String) {
        PayloadFileStore.save(subdirectory, "${payloadKey}_$profileId", payload)
    }

    /** Sign-out cleanup (called by TvOsAccountDataCleaner). */
    fun deleteAll() = PayloadFileStore.deleteAll(subdirectory)
}
