package com.nuvio.app.core.storage

import com.nuvio.app.core.account.AccountDataStores
import com.nuvio.app.features.profiles.MAX_PROFILES
import platform.Foundation.NSUserDefaults

/**
 * iOS half of the account-data wipe: NSUserDefaults keys for ALL profile slots (the repo-level
 * `clearLocalState()` calls in [LocalAccountDataCleaner] only touch the active profile's
 * `ProfileScopedKey`s), plus the file-backed payload stores.
 *
 * Driven entirely by `core.account.AccountDataStores` — the same registry tvOS's
 * `TvOsAccountDataCleaner` reads, so the two Apple wipes can no longer drift. Adding a persisted
 * store means adding a line to `AccountDataStores.all`, NOT editing this file.
 */
internal actual object PlatformLocalAccountDataCleaner {

    actual fun wipe() {
        val defaults = NSUserDefaults.standardUserDefaults

        AccountDataStores.applePlainKeys().forEach(defaults::removeObjectForKey)

        // 1..MAX_PROFILES, not the legacy 1..4 this file used to iterate — profiles 5 and 6 were
        // never wiped on the phone build.
        val profileIndexedPrefixes = AccountDataStores.appleProfileIndexedPrefixes()
        val profileScopedBaseKeys = AccountDataStores.appleProfileScopedBases()
        (1..MAX_PROFILES).forEach { profileId ->
            profileIndexedPrefixes.forEach { prefix ->
                defaults.removeObjectForKey("$prefix$profileId")
            }
            profileScopedBaseKeys.forEach { baseKey ->
                defaults.removeObjectForKey("${baseKey}_$profileId")
            }
        }

        // Keys that embed runtime data (content-id hashes, manifest URLs, debrid provider ids)
        // cannot be enumerated, so they are swept by prefix. This also clears legacy defaults
        // values left by pre-migration builds for stores that are file-backed today
        // (stream_link_*, cw_enrichment_cache_*, plugins_state_*).
        val dynamicPrefixes = AccountDataStores.appleDynamicPrefixes()
        for (key in defaults.dictionaryRepresentation().keys) {
            val keyString = key as? String ?: continue
            if (dynamicPrefixes.any { keyString.startsWith(it) }) {
                defaults.removeObjectForKey(keyString)
            }
        }

        // File-backed payload stores (PayloadFileStore) — the defaults-key removals above only
        // cover values left behind by pre-migration builds.
        AppleFilePayloadStores.deleteAll()
    }
}
