package com.nuvio.app.core.account

import kotlin.concurrent.Volatile

/**
 * Compose-free seam letting `core.auth.AuthRepository` wipe all local account data without
 * importing `core.storage.LocalAccountDataCleaner` — a god-object that imports ~29 repositories
 * (so it migrates near-last). The phone app installs an adapter backed by `LocalAccountDataCleaner`
 * at startup; tvOS leaves the default no-op until its own storages exist.
 *
 * Mirrors the established StringProvider / FeaturePolicy / ActiveProfileProvider injection pattern.
 */
fun interface AccountDataCleaner {
    fun wipe()
}

object AccountDataCleanerProvider {
    @Volatile
    var cleaner: AccountDataCleaner = AccountDataCleaner { /* no-op default */ }
}

/**
 * Erases what one profile slot keeps in local profile-scoped storage (settings, auth, caches).
 * Deleting a profile calls it so a profile created later at the same index starts empty instead of
 * inheriting the deleted one's data. Installed by the Apple host; the default does nothing.
 */
fun interface ProfileDataEraser {
    fun erase(profileIndex: Int)
}

object ProfileDataEraserProvider {
    @Volatile
    var eraser: ProfileDataEraser = ProfileDataEraser { /* no-op default */ }
}
