package com.nuvio.app.features.collection

expect object CollectionStorage {
    fun loadPayload(): String?

    /** Returns false when the payload did not durably persist (callers must not report success). */
    fun savePayload(payload: String): Boolean
}
