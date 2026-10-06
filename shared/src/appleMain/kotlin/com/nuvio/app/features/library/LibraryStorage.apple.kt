package com.nuvio.app.features.library

import com.nuvio.app.core.storage.PayloadFileStore

/**
 * File-backed (Trakt-library / BUG-11 defect class — see [PayloadFileStore]): one string holding
 * the user's whole library, growing with every saved item.
 */
actual object LibraryStorage {
    private const val subdirectory = "Library"

    private fun payloadKey(profileId: Int) = "library_payload_$profileId"

    actual fun loadPayload(profileId: Int): String? =
        PayloadFileStore.load(subdirectory, payloadKey(profileId))

    actual fun savePayload(profileId: Int, payload: String) {
        PayloadFileStore.save(subdirectory, payloadKey(profileId), payload)
    }

    /** Sign-out cleanup (called by TvOsAccountDataCleaner). */
    fun deleteAll() = PayloadFileStore.deleteAll(subdirectory)
}
