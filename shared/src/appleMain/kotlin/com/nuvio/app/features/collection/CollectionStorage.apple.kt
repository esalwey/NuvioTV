package com.nuvio.app.features.collection

import com.nuvio.app.core.storage.PayloadFileStore
import com.nuvio.app.core.storage.ProfileScopedKey

/**
 * File-backed (Trakt-library / BUG-11 defect class — see [PayloadFileStore]): the payload
 * serializes every collection with every item into one string and grows without bound —
 * ~197KB on the Living Room device (2026-08-01), the largest defaults survivor after the
 * Trakt snapshot moved out.
 */
actual object CollectionStorage {
    private const val subdirectory = "Collections"
    private const val payloadKey = "collections_payload"

    actual fun loadPayload(): String? =
        PayloadFileStore.load(subdirectory, ProfileScopedKey.of(payloadKey))

    actual fun savePayload(payload: String) =
        PayloadFileStore.save(subdirectory, ProfileScopedKey.of(payloadKey), payload)

    /** Sign-out cleanup (called by TvOsAccountDataCleaner). */
    fun deleteAll() = PayloadFileStore.deleteAll(subdirectory)
}
