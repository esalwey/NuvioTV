@file:OptIn(ExperimentalForeignApi::class)

package com.nuvio.app.features.plugins

import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.NSUserDomainMask
import platform.Foundation.create
import platform.Foundation.stringWithContentsOfFile
import platform.Foundation.writeToFile

/**
 * File-backed storage for per-profile plugin state. The payload embeds every scraper's JS
 * source, and CFPreferences aborts the process outright once an app's defaults plist crosses
 * ~4 MB (`__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`), so this
 * data must never go through NSUserDefaults.
 */
internal object PluginStateFiles {
    private fun directory(): String? {
        val base = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory,
            NSUserDomainMask,
            true,
        ).firstOrNull() as? String ?: return null
        val dir = "$base/PluginState"
        NSFileManager.defaultManager.createDirectoryAtPath(
            dir,
            withIntermediateDirectories = true,
            attributes = null,
            error = null,
        )
        return dir
    }

    private fun path(profileId: Int): String? =
        directory()?.let { "$it/plugins_state_$profileId.json" }

    fun read(profileId: Int): String? {
        val path = path(profileId) ?: return null
        return NSString.stringWithContentsOfFile(path, encoding = NSUTF8StringEncoding, error = null)
    }

    @OptIn(BetaInteropApi::class)
    fun write(profileId: Int, payload: String) {
        val path = path(profileId) ?: return
        NSString.create(string = payload).writeToFile(
            path,
            atomically = true,
            encoding = NSUTF8StringEncoding,
            error = null,
        )
    }

    fun deleteAll() {
        directory()?.let { NSFileManager.defaultManager.removeItemAtPath(it, error = null) }
    }
}
