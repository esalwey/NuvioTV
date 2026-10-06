package com.nuvio.app.core.ui

// Fork: public (upstream: internal) — composeApp MainActivity initializes this cross-module.
expect object CardDepthStyleStorage {
    fun loadPayload(): String?
    fun savePayload(payload: String)
}
