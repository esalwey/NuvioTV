package com.nuvio.app.features.mdblist

/**
 * English user-facing text for MDBList failures that surface as plain strings in shared state
 * (the library snapshot's error line). Screens that render account status read the typed
 * [MdbListAuthError] / [MdbListSyncError] values instead and localize them themselves.
 */
internal fun MdbListAuthError.userMessage(): String = when (this) {
    MdbListAuthError.MISSING_CLIENT_ID -> "MDBList connection is unavailable in this build."
    MdbListAuthError.INVALID_RESPONSE -> "MDBList returned an incomplete response. Please try again."
    MdbListAuthError.INSUFFICIENT_SCOPE ->
        "MDBList did not grant permission to update watch history. Reconnect and allow write access."
    MdbListAuthError.CODE_EXPIRED -> "This code has expired. Try again to get a new code."
    MdbListAuthError.ACCESS_DENIED -> "Connection was declined. Try again to connect your account."
    MdbListAuthError.AUTHORIZATION_REVOKED ->
        "Your MDBList connection has expired or been revoked. Connect again to resume syncing."
}

internal fun MdbListSyncError.userMessage(): String = when (this) {
    MdbListSyncError.RATE_LIMIT ->
        "MDBList\u2019s request limit has been reached. Syncing will resume after the limit resets."
    MdbListSyncError.AUTHORIZATION_REVOKED -> MdbListAuthError.AUTHORIZATION_REVOKED.userMessage()
    MdbListSyncError.INVALID_RESPONSE -> MdbListAuthError.INVALID_RESPONSE.userMessage()
    MdbListSyncError.UNAVAILABLE -> "Could not sync with MDBList. Please try again."
}

internal fun Throwable.mdbListUserMessage(): String =
    (this as? MdbListAuthException)?.error?.userMessage() ?: toMdbListSyncError().userMessage()

