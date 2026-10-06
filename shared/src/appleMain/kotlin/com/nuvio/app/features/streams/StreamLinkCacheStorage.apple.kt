package com.nuvio.app.features.streams

import com.nuvio.app.core.storage.PayloadFileStore
import com.nuvio.app.core.storage.ProfileScopedKey

/**
 * File-backed (Trakt-library / BUG-11 defect class — see [PayloadFileStore]): entries are
 * individually small, but the repository writes one key per content item ever fetched and only
 * prunes on read, so the never-read tail accumulates in the defaults plist without bound.
 */
actual object StreamLinkCacheStorage {
    private const val subdirectory = "StreamLinkCache"

    actual fun loadEntry(hashedKey: String): String? =
        PayloadFileStore.load(subdirectory, ProfileScopedKey.of(hashedKey))

    actual fun saveEntry(hashedKey: String, payload: String) {
        PayloadFileStore.save(subdirectory, ProfileScopedKey.of(hashedKey), payload)
    }

    actual fun removeEntry(hashedKey: String) =
        PayloadFileStore.remove(subdirectory, ProfileScopedKey.of(hashedKey))

    /** Sign-out cleanup (called by TvOsAccountDataCleaner). */
    fun deleteAll() = PayloadFileStore.deleteAll(subdirectory)
}
