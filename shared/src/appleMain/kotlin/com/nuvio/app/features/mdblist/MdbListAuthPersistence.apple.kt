package com.nuvio.app.features.mdblist

import com.nuvio.app.core.storage.ProfileScopedKey
import com.nuvio.app.features.profiles.MAX_PROFILES
import platform.Foundation.NSUserDefaults

/**
 * Per-profile MDBList OAuth tokens (a small JSON payload: tokens, user, pending device session),
 * kept where the Trakt and Simkl tokens already live. The payload is a few hundred bytes, so
 * NSUserDefaults is the right store; the unbounded sync snapshot lives in
 * [PlatformMdbListSyncStorage] instead.
 */
actual object PlatformMdbListAuthPersistence : MdbListAuthPersistence {
    private const val payloadKey = "mdblist_auth_payload"

    actual override fun read(profileId: Int): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(ProfileScopedKey.of(payloadKey, profileId))

    actual override fun write(profileId: Int, value: String?) {
        val key = ProfileScopedKey.of(payloadKey, profileId)
        if (value == null) {
            NSUserDefaults.standardUserDefaults.removeObjectForKey(key)
        } else {
            NSUserDefaults.standardUserDefaults.setObject(value, forKey = key)
        }
    }

    actual override fun clear() {
        (1..MAX_PROFILES).forEach { profileId ->
            NSUserDefaults.standardUserDefaults.removeObjectForKey(ProfileScopedKey.of(payloadKey, profileId))
        }
    }
}
