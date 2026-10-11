package com.nuvio.app.core.sync

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider

/**
 * Runs [block] with the profile-scoped storages (`ProfileScopedKey.of(...)`) pointed at
 * [profileId] instead of the active profile, then restores the previous provider.
 *
 * The settings storages have no profile parameter, so reading or writing another profile's
 * settings (profile "copy settings") goes through this seam. The block must be synchronous and
 * short: it holds no lock against other threads, so a profile-scoped write racing it from another
 * thread would land in [profileId]. Callers serialise copies behind the settings sync mutex.
 */
internal inline fun <T> withProfileScope(profileId: Int, block: () -> T): T {
    val previous = ActiveProfileProvider.provider
    ActiveProfileProvider.provider = ActiveProfileIdProvider { profileId }
    try {
        return block()
    } finally {
        ActiveProfileProvider.provider = previous
    }
}
