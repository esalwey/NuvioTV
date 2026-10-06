package com.nuvio.app.core.storage

import java.io.File

/**
 * JVM analogue of appleMain's `PayloadFileStore` (`shared/src/appleMain/.../PayloadFileStore.kt`)
 * — one subdirectory per store under the same per-process temp root [JvmPreferencesRoot] uses,
 * files named after the exact key they hold. No legacy-defaults migration (nothing to migrate
 * from on the JVM); [load]/[save]/[remove]/[deleteAll] otherwise mirror the apple contract.
 */
internal object JvmPayloadFileStore {

    fun load(subdirectory: String, key: String): String? {
        val target = file(subdirectory, key)
        return if (target.exists()) runCatching { target.readText(Charsets.UTF_8) }.getOrNull() else null
    }

    /** Returns false when the write did not durably land, matching the apple/android contract. */
    fun save(subdirectory: String, key: String, payload: String): Boolean {
        val target = file(subdirectory, key)
        return runCatching {
            target.parentFile?.mkdirs()
            target.writeText(payload, Charsets.UTF_8)
        }.isSuccess
    }

    fun remove(subdirectory: String, key: String) {
        file(subdirectory, key).delete()
    }

    /** Sign-out cleanup (mirrors apple's PayloadFileStore.deleteAll). */
    fun deleteAll(subdirectory: String) {
        directory(subdirectory).deleteRecursively()
    }

    private fun directory(subdirectory: String): File =
        File(JvmPreferencesRoot.directory, subdirectory)

    private fun file(subdirectory: String, key: String): File =
        File(directory(subdirectory), "$key.json")
}
