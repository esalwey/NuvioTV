@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.nuvio.app.core.storage

import kotlinx.cinterop.BetaInteropApi
import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.NSUserDefaults
import platform.Foundation.NSUserDomainMask
import platform.Foundation.create
import platform.Foundation.stringWithContentsOfFile
import platform.Foundation.writeToFile

/**
 * File backing for payload stores whose defaults writes can grow with user data (the BUG-11 /
 * Trakt-library defect class): CFPreferences aborts the process outright on an oversized
 * defaults write (`__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`), so
 * any payload without a hard size bound must never go through NSUserDefaults.
 *
 * Each store owns one subdirectory of Application Support (PluginStateFiles layout), and files
 * are named after the exact defaults key they replace: [load] drains a legacy defaults value
 * into the file store on first read, and [save]/[remove] delete the legacy key so the defaults
 * plist shrinks back on devices that wrote through the old path. [load]/[save] only drop the
 * legacy key after the file write succeeds, so a failed write never loses the only copy.
 */
internal object PayloadFileStore {

    fun load(subdirectory: String, key: String): String? {
        val path = path(subdirectory, key) ?: return legacyDefaultsValue(key)
        NSString.stringWithContentsOfFile(path, encoding = NSUTF8StringEncoding, error = null)
            ?.let { return it }
        // Migration: drain the legacy defaults value into the file store, then drop the key.
        val legacy = legacyDefaultsValue(key) ?: return null
        if (writeFile(path, legacy)) {
            removeLegacyDefaultsValue(key)
        }
        return legacy
    }

    /** Returns false when the write did not durably land (no resolvable path, or the file write failed). */
    fun save(subdirectory: String, key: String, payload: String): Boolean {
        val path = path(subdirectory, key) ?: return false
        if (!writeFile(path, payload)) return false
        // Keep shrinking the defaults plist even for keys that are never read back.
        removeLegacyDefaultsValue(key)
        return true
    }

    fun remove(subdirectory: String, key: String) {
        path(subdirectory, key)?.let {
            NSFileManager.defaultManager.removeItemAtPath(it, error = null)
        }
        removeLegacyDefaultsValue(key)
    }

    /** Sign-out cleanup — drops the store's whole directory (called by TvOsAccountDataCleaner). */
    fun deleteAll(subdirectory: String) {
        directory(subdirectory, create = false)?.let {
            NSFileManager.defaultManager.removeItemAtPath(it, error = null)
        }
    }

    private fun directory(subdirectory: String, create: Boolean = true): String? {
        val base = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory,
            NSUserDomainMask,
            true,
        ).firstOrNull() as? String ?: return null
        val dir = "$base/$subdirectory"
        if (create) {
            NSFileManager.defaultManager.createDirectoryAtPath(
                dir,
                withIntermediateDirectories = true,
                attributes = null,
                error = null,
            )
        }
        return dir
    }

    private fun path(subdirectory: String, key: String): String? =
        directory(subdirectory)?.let { "$it/$key.json" }

    private fun legacyDefaultsValue(key: String): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(key)

    private fun removeLegacyDefaultsValue(key: String) {
        NSUserDefaults.standardUserDefaults.removeObjectForKey(key)
    }

    @OptIn(BetaInteropApi::class)
    private fun writeFile(path: String, payload: String): Boolean =
        NSString.create(string = payload).writeToFile(
            path,
            atomically = true,
            encoding = NSUTF8StringEncoding,
            error = null,
        )
}
