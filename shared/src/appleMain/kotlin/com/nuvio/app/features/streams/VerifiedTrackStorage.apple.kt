package com.nuvio.app.features.streams

import com.nuvio.app.core.storage.PayloadFileStore

/**
 * Fork (VERIFIED-LANGUAGES): one file-backed payload (`VerifiedTracks/verified_tracks`), device
 * wide — track lists are facts about files, not about a profile. Bounded by the store (5,000 keys).
 */
actual object VerifiedTrackStorage {
    private const val subdirectory = "VerifiedTracks"
    private const val key = "verified_tracks"

    actual fun loadPayload(): String? = PayloadFileStore.load(subdirectory, key)

    actual fun savePayload(payload: String) {
        PayloadFileStore.save(subdirectory, key, payload)
    }

    actual fun clear() = PayloadFileStore.remove(subdirectory, key)
}
