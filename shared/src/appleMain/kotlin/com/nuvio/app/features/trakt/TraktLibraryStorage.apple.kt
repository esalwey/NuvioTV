package com.nuvio.app.features.trakt

import com.nuvio.app.core.storage.PayloadFileStore
import com.nuvio.app.core.storage.ProfileScopedKey

/**
 * File-backed storage for the Trakt library snapshot (same defect class and fix as BUG-11's
 * PluginStateFiles — see [PayloadFileStore]): the snapshot serializes EVERY entry of every Trakt
 * list into one string, and a large Trakt library crossed the CFPreferences oversized-write cap
 * on the Living Room device the first time the tracking-registry refresh persisted a full
 * snapshot (2026-08-01). This data must never go through NSUserDefaults.
 */
actual object TraktLibraryStorage {
    private const val subdirectory = "TraktLibrary"
    private const val payloadKey = "trakt_library_payload"

    // ProfileScopedKey.of resolves the active profile, so the filename stays per-profile the
    // same way the old defaults key did (e.g. "trakt_library_payload_2.json").
    actual fun loadPayload(): String? =
        PayloadFileStore.load(subdirectory, ProfileScopedKey.of(payloadKey))

    actual fun savePayload(payload: String) {
        PayloadFileStore.save(subdirectory, ProfileScopedKey.of(payloadKey), payload)
    }

    /** Sign-out cleanup — mirrors PluginStateFiles.deleteAll (called by TvOsAccountDataCleaner). */
    fun deleteAll() = PayloadFileStore.deleteAll(subdirectory)
}
