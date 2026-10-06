package com.nuvio.app.features.simkl

import com.nuvio.app.core.storage.PayloadFileStore
import com.nuvio.app.core.storage.ProfileScopedKey

/**
 * File-backed storage for the Simkl library snapshot (same defect class and fix as BUG-11's
 * PluginStateFiles / Trakt's TraktLibraryStorage — see [PayloadFileStore]): the snapshot
 * serializes EVERY entry of every Simkl list, with nested seasons and episodes and per-episode
 * watched_at, into one string. A large Simkl library can cross the CFPreferences oversized-write
 * cap the same way the Trakt library did on the Living Room device (2026-08-01). This data must
 * never go through NSUserDefaults.
 */
internal actual object SimklSyncStorage {
    private const val subdirectory = "SimklSync"
    private const val payloadKey = "simkl_sync_snapshot"

    // ProfileScopedKey.of resolves the active profile, so the filename stays per-profile the
    // same way the old defaults key did (e.g. "simkl_sync_snapshot_2.json").
    actual fun loadPayload(): String? =
        PayloadFileStore.load(subdirectory, ProfileScopedKey.of(payloadKey))

    actual fun savePayload(payload: String) {
        PayloadFileStore.save(subdirectory, ProfileScopedKey.of(payloadKey), payload)
    }

    actual fun removeProfile(profileId: Int) =
        PayloadFileStore.remove(subdirectory, ProfileScopedKey.of(payloadKey, profileId))

    /** Sign-out cleanup — mirrors PluginStateFiles.deleteAll (called by TvOsAccountDataCleaner). */
    fun deleteAll() = PayloadFileStore.deleteAll(subdirectory)
}
