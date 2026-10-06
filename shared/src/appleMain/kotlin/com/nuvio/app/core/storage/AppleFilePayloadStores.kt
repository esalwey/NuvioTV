package com.nuvio.app.core.storage

import com.nuvio.app.core.account.AccountDataStores

/**
 * Sign-out deletion entry point for every file-backed payload store ([PayloadFileStore]
 * subdirectories). Both account cleaners — tvOS (TvOsAccountDataCleaner in
 * TvOsProviderInstaller.kt) and iOS (composeApp's PlatformLocalAccountDataCleaner.ios) — go
 * through this so neither platform's wipe can drift when a store is added.
 *
 * The subdirectory list comes from `core.account.AccountDataStores`, not from the store objects
 * themselves: calling `Xyz.deleteAll()` on nine `object`s by name meant the wipe depended on
 * lazily-initialised singletons and on somebody remembering to add the tenth. Deleting by
 * subdirectory name needs neither. Adding a file-backed store means adding an
 * `AppleKeySpec.FileStore(...)` entry to `AccountDataStores.all`, NOT editing this file.
 */
object AppleFilePayloadStores {
    fun deleteAll() {
        AccountDataStores.appleFileStoreSubdirectories().forEach { subdirectory ->
            PayloadFileStore.deleteAll(subdirectory)
        }
    }
}
