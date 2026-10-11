package com.nuvio.app.features.mdblist

import com.nuvio.app.core.storage.PayloadFileStore
import com.nuvio.app.core.storage.ProfileScopedKey

/**
 * File-backed storage for the MDBList sync snapshot: watched history, playback progress and every
 * library list with its items. That payload has no size bound, so it must never go through
 * NSUserDefaults (see [PayloadFileStore]).
 */
actual object PlatformMdbListSyncStorage : MdbListSyncStorage {
    private const val subdirectory = "MdbListSync"
    private const val payloadKey = "mdblist_sync_snapshot"

    actual override suspend fun load(profileId: Int): String? =
        PayloadFileStore.load(subdirectory, ProfileScopedKey.of(payloadKey, profileId))

    actual override suspend fun save(profileId: Int, payload: String, checkScope: () -> Unit) {
        checkScope()
        check(PayloadFileStore.save(subdirectory, ProfileScopedKey.of(payloadKey, profileId), payload)) {
            "Unable to save the MDBList cache"
        }
    }

    actual override suspend fun remove(profileId: Int, checkScope: () -> Unit) {
        checkScope()
        PayloadFileStore.remove(subdirectory, ProfileScopedKey.of(payloadKey, profileId))
    }

    actual fun clearAll() = PayloadFileStore.deleteAll(subdirectory)
}
