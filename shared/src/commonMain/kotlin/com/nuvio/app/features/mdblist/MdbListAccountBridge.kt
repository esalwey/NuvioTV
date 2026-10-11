package com.nuvio.app.features.mdblist

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.tracking.TrackingRefreshIntent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * What the MDBList account card shows. Flat and primitive on purpose: this is the model Swift
 * reads, so it avoids the scope / generation types the account controller uses internally.
 *
 * Error fields hold one of the codes in [MdbListAccountErrorCodes] (null when there is no error);
 * screens turn them into localized text.
 */
data class MdbListAccountUiState(
    /** False in a build without MDBLIST_CLIENT_ID: the account cannot be connected there. */
    val credentialsConfigured: Boolean = false,
    val isConnected: Boolean = false,
    /** A code is being requested, or the account is being disconnected. */
    val isWorking: Boolean = false,
    val username: String? = null,
    val isSupporter: Boolean = false,
    /** The code to enter while an authorization waits for approval. */
    val userCode: String? = null,
    /** Where to enter [userCode], as a readable address (no code in it). */
    val verificationUrl: String? = null,
    /** The approval page with the code filled in; this is what the QR code encodes. */
    val verificationUrlWithCode: String? = null,
    val errorCode: String? = null,
    /** The account was disconnected here but MDBList did not confirm revoking the app's access. */
    val revokeFailed: Boolean = false,
    val isSyncing: Boolean = false,
    val lastSyncedAtEpochMs: Long? = null,
    val syncErrorCode: String? = null,
    /** Why the last change to which lists show in the library did not apply. */
    val listErrorCode: String? = null,
)

object MdbListAccountErrorCodes {
    const val MISSING_CLIENT_ID = "missing_client_id"
    const val INVALID_RESPONSE = "invalid_response"
    const val WRITE_REQUIRED = "write_required"
    const val CODE_EXPIRED = "code_expired"
    const val ACCESS_DENIED = "access_denied"
    const val AUTHORIZATION_REVOKED = "authorization_revoked"
    const val RATE_LIMITED = "rate_limited"
    const val UNAVAILABLE = "unavailable"
}

/**
 * Swift-facing entry point of the MDBList account: connect with a code (and QR) shown on the TV,
 * disconnect, sync now, and choose which MDBList lists appear in the library. Every action is
 * fire-and-forget; the outcome arrives through [state] and [listOptions].
 */
object MdbListAccountBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("MdbListAccountBridge"))
    private val syncing = MutableStateFlow(false)
    private val listError = MutableStateFlow<String?>(null)

    val state: StateFlow<MdbListAccountUiState> by lazy {
        combine(
            MdbListTracker.auth.state,
            MdbListTracker.account.status,
            MdbListTracker.sync.state,
            syncing,
            listError,
        ) { auth, status, sync, isSyncing, listErrorCode ->
            buildState(auth, status, sync, isSyncing, listErrorCode)
        }.stateIn(scope, SharingStarted.WhileSubscribed(5_000), currentState())
    }

    /** Every list that can be hidden from the library (the watchlist is always shown). */
    val listOptions: StateFlow<List<MdbListLibraryListOption>> by lazy {
        MdbListTracker.library.listOptions.stateIn(scope, SharingStarted.WhileSubscribed(5_000), emptyList())
    }

    /** Makes the tracker follow the active profile and resumes a code that was left waiting. */
    fun ensureLoaded() {
        ensureTrackingProvidersRegistered()
        MdbListTracker.ensureLoaded()
        if (MdbListTracker.auth.state.value.session != null) {
            try {
                MdbListTracker.account.resumePolling()
            } catch (_: CancellationException) {
                // The account changed while resuming; the next state emission reflects it.
            }
        }
    }

    fun connect() {
        scope.launch {
            listError.value = null
            try {
                MdbListTracker.account.connect()
            } catch (_: CancellationException) {
                // The account changed under the request; the state flow shows the new one.
            }
        }
    }

    fun cancel() {
        try {
            MdbListTracker.account.cancel()
        } catch (_: CancellationException) {
            // The account changed since the code was shown.
        }
    }

    fun disconnect() {
        scope.launch {
            try {
                MdbListTracker.account.disconnect()
            } catch (_: CancellationException) {
                // The account changed under the request; the state flow shows the new one.
            }
        }
    }

    /** Pulls watched history, progress and lists from MDBList now, ignoring the refresh interval. */
    fun syncNow() {
        if (syncing.value) return
        syncing.value = true
        scope.launch {
            try {
                MdbListTracker.sync.refresh(TrackingRefreshIntent.USER_INITIATED)
                MdbListTracker.library.refresh(TrackingRefreshIntent.USER_INITIATED)
            } catch (_: Exception) {
                // Failures are published by the sync repository and read from state.syncErrorCode.
            } finally {
                syncing.value = false
            }
        }
    }

    /** Shows or hides one list in the library. The change applies once the lists are reloaded. */
    fun setListVisible(key: String, visible: Boolean) {
        listError.value = null
        MdbListTracker.library.setListVisibleAsync(key, visible) { error ->
            if (error != null) listError.value = error.errorCode()
        }
    }

    private fun currentState(): MdbListAccountUiState = buildState(
        MdbListTracker.auth.state.value,
        MdbListTracker.account.status.value,
        MdbListTracker.sync.state.value,
        syncing.value,
        listError.value,
    )

    private fun buildState(
        auth: MdbListAuthState,
        status: MdbListAccountStatus,
        sync: MdbListSyncState,
        isSyncing: Boolean,
        listErrorCode: String?,
    ): MdbListAccountUiState {
        val sameProfile = status.scope?.profileId == auth.scope.profileId
        val connected = auth.isAuthenticated
        val syncState = sync.takeIf { connected && it.scope == auth.scope }
        return MdbListAccountUiState(
            credentialsConfigured = MdbListTracker.auth.hasRequiredCredentials(),
            isConnected = connected,
            isWorking = sameProfile && status.isBusy,
            username = auth.user?.username?.takeIf { connected },
            isSupporter = connected && auth.user?.isSupporter == true,
            userCode = auth.session?.userCode?.takeUnless { connected },
            verificationUrl = auth.session?.verificationUri?.takeUnless { connected },
            verificationUrlWithCode = auth.session?.verificationUriComplete?.takeUnless { connected },
            errorCode = if (connected) null else {
                (status.authError.takeIf { sameProfile } ?: auth.error)?.errorCode()
                    ?: status.error.takeIf { sameProfile }?.errorCode()
            },
            revokeFailed = sameProfile && status.revokeFailed,
            isSyncing = connected && (isSyncing || syncState?.isLoading == true),
            lastSyncedAtEpochMs = syncState?.snapshot?.checkedAtEpochMs,
            syncErrorCode = syncState?.error?.errorCode(),
            listErrorCode = listErrorCode,
        )
    }
}

private fun MdbListAuthError.errorCode(): String = when (this) {
    MdbListAuthError.MISSING_CLIENT_ID -> MdbListAccountErrorCodes.MISSING_CLIENT_ID
    MdbListAuthError.INVALID_RESPONSE -> MdbListAccountErrorCodes.INVALID_RESPONSE
    MdbListAuthError.INSUFFICIENT_SCOPE -> MdbListAccountErrorCodes.WRITE_REQUIRED
    MdbListAuthError.CODE_EXPIRED -> MdbListAccountErrorCodes.CODE_EXPIRED
    MdbListAuthError.ACCESS_DENIED -> MdbListAccountErrorCodes.ACCESS_DENIED
    MdbListAuthError.AUTHORIZATION_REVOKED -> MdbListAccountErrorCodes.AUTHORIZATION_REVOKED
}

private fun MdbListSyncError.errorCode(): String = when (this) {
    MdbListSyncError.RATE_LIMIT -> MdbListAccountErrorCodes.RATE_LIMITED
    MdbListSyncError.AUTHORIZATION_REVOKED -> MdbListAccountErrorCodes.AUTHORIZATION_REVOKED
    MdbListSyncError.INVALID_RESPONSE -> MdbListAccountErrorCodes.INVALID_RESPONSE
    MdbListSyncError.UNAVAILABLE -> MdbListAccountErrorCodes.UNAVAILABLE
}

private fun Throwable.errorCode(): String =
    (this as? MdbListAuthException)?.error?.errorCode() ?: toMdbListSyncError().errorCode()
