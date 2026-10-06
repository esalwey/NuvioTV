package com.nuvio.app.features.simkl

/**
 * Per-profile Simkl credential storage, shaped like [com.nuvio.app.features.trakt.TraktAuthStorage].
 *
 * One small JSON payload (`SimklAuthState`: an access token plus username/account metadata) per
 * profile. Unlike [SimklSyncStorage] this must NOT move to `PayloadFileStore` — that store exists
 * for the unbounded Simkl library snapshot, which can cross the CFPreferences oversized-write cap.
 * A token payload is a few hundred bytes and belongs in NSUserDefaults, exactly where the Trakt
 * tokens already live.
 */
expect object SimklAuthStorage {
    fun loadPayload(profileId: Int): String?
    fun savePayload(profileId: Int, payload: String)
    fun removeProfile(profileId: Int)
}
