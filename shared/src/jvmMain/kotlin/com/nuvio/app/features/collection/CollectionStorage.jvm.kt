package com.nuvio.app.features.collection

import com.nuvio.app.core.storage.JvmPayloadFileStore
import com.nuvio.app.core.storage.ProfileScopedKey

/**
 * JVM actual for shared/src/jvmMain (beta.14 Wave 4, docs/issue-triage-plan-2026-08-21.md §6.1).
 * Ported from appleMain's file-backed actual (not androidMain's SharedPreferences one) — this
 * expect's `savePayload` returns a durable-write result, which [JvmPayloadFileStore] models the
 * same way appleMain's `PayloadFileStore` does.
 */
actual object CollectionStorage {
    private const val subdirectory = "Collections"
    private const val payloadKey = "collections_payload"

    actual fun loadPayload(): String? =
        JvmPayloadFileStore.load(subdirectory, ProfileScopedKey.of(payloadKey))

    actual fun savePayload(payload: String): Boolean =
        JvmPayloadFileStore.save(subdirectory, ProfileScopedKey.of(payloadKey), payload)

    /** Sign-out cleanup, mirrors the apple/android actuals' deleteAll(). */
    fun deleteAll() = JvmPayloadFileStore.deleteAll(subdirectory)
}
