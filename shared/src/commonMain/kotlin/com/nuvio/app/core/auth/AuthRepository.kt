package com.nuvio.app.core.auth

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

import co.touchlab.kermit.Logger
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.account.AccountDataCleanerProvider
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.functions.functions
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.seconds

object AuthRepository {
    private val SESSION_RESTORE_TIMEOUT = 10.seconds

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("AuthRepository"))
    private val log = Logger.withTag("AuthRepository")

    private val _state = MutableStateFlow<AuthState>(AuthState.Loading)
    val state: StateFlow<AuthState> = _state.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private var initialized = false
    private var validatedRemoteUserId: String? = null
    private var sessionRestoreTimedOut = false
    private var sessionStatusJob: Job? = null
    // Fork: the restore watchdog is a second launch upstream doesn't have; reinitialize() must
    // cancel it too or a stale watchdog fires into the NEW client's restore.
    private var restoreWatchdogJob: Job? = null
    // STAB-01: true while supabase-kt reports RefreshFailure (token refresh failed on a network or
    // server error; the session stays stored and the refresh is retried). Errors seen in that
    // window come from a stale token, not from a deleted account.
    private var refreshFailureActive = false

    fun initialize() {
        if (initialized) return
        initialized = true

        val savedAnonId = AuthStorage.loadAnonymousUserId()
        if (savedAnonId != null) {
            _state.value = AuthState.Authenticated(
                userId = savedAnonId,
                email = null,
                isAnonymous = true,
            )
        }

        // A damaged or wedged stored session must not brick boot: supabase-kt's session restore
        // can stall without ever leaving Initializing (storage read that never returns, restore
        // coroutine dying), which would pin the root gate on the splash forever. If we are still
        // Loading after the timeout, fall back to signed-out — a late successful restore still
        // flips the gate to Authenticated through the collector below.
        restoreWatchdogJob = scope.launch {
            delay(SESSION_RESTORE_TIMEOUT)
            sessionRestoreTimedOut = true
            if (_state.compareAndSet(AuthState.Loading, AuthState.Unauthenticated)) {
                log.w { "Session restore still pending after $SESSION_RESTORE_TIMEOUT; treating as signed out (stored session may be damaged or unreadable)" }
            }
        }

        sessionStatusJob = scope.launch {
            debugSessionRestoreStall()?.let { stall ->
                log.w { "debug.authRestoreStallSeconds active — delaying session-status collection by $stall to simulate a wedged restore" }
                delay(stall)
            }
            SupabaseProvider.client.auth.sessionStatus.collect { status ->
                if (AuthStorage.loadAnonymousUserId() != null) return@collect
                if (status !is SessionStatus.RefreshFailure) refreshFailureActive = false
                when (status) {
                    is SessionStatus.Authenticated -> {
                        val user = status.session.user
                        // Anonymous Supabase sessions are QR-login scaffolding
                        // (TvLoginRepository), never a signed-in account. A RESTORED one (the
                        // scaffolding got persisted, e.g. the app quit mid-pairing) used to be
                        // silently ignored here, pinning the gate on the splash until the 10s
                        // watchdog — surface it as signed out immediately instead. During live
                        // pairing the state is already Unauthenticated, so this is a no-op there.
                        if (user?.isAnonymous == true) {
                            if (_state.compareAndSet(AuthState.Loading, AuthState.Unauthenticated)) {
                                log.i { "Restored session is anonymous QR scaffolding — treating as signed out" }
                            }
                            return@collect
                        }
                        val userId = user?.id.orEmpty()
                        if (!validateRemoteSession(userId)) return@collect
                        _state.value = AuthState.Authenticated(
                            userId = userId,
                            email = user?.email,
                            isAnonymous = false,
                        )
                    }
                    is SessionStatus.NotAuthenticated -> {
                        _state.value = AuthState.Unauthenticated
                    }
                    is SessionStatus.Initializing -> {
                        // Never re-enter Loading once the restore watchdog has fired — that
                        // would re-brick the gate the watchdog just unbricked.
                        if (AuthStorage.loadAnonymousUserId() == null && !sessionRestoreTimedOut) {
                            _state.value = AuthState.Loading
                        }
                    }
                    is SessionStatus.RefreshFailure -> {
                        refreshFailureActive = true
                        handleRefreshFailure()
                    }
                }
            }
        }
    }

    /**
     * STAB-01: a failed token refresh (Wi-Fi drop, server hiccup) is not a sign-out. supabase-kt
     * keeps the stored session and retries the refresh, so an account that is already signed in
     * stays [AuthState.Authenticated]. Before this, the gate fell to the Welcome screen and tore
     * the app down mid-playback. During a cold start (or after the restore watchdog fired) the
     * stored session's user is used, so an offline launch with an expired token still opens the
     * app. Only a real NotAuthenticated (or a remote invalidation) signs the user out.
     */
    private suspend fun handleRefreshFailure() {
        val current = _state.value
        if (current is AuthState.Authenticated) {
            log.w { "Session refresh failed; keeping the signed-in session until the retry succeeds" }
            return
        }
        val canPromote = current is AuthState.Loading ||
            (current is AuthState.Unauthenticated && sessionRestoreTimedOut)
        if (!canPromote) return
        val storedUser = runCatching { SupabaseProvider.client.auth.sessionManager.loadSession() }
            .onFailure { e -> log.w(e) { "Could not read the stored session after a refresh failure" } }
            .getOrNull()
            ?.user
        val userId = storedUser?.id.orEmpty()
        if (storedUser == null || storedUser.isAnonymous == true || userId.isBlank()) {
            if (current is AuthState.Loading) {
                _state.value = AuthState.Unauthenticated
            }
            return
        }
        log.w { "Session refresh failed during restore; using the stored session offline" }
        _state.value = AuthState.Authenticated(
            userId = userId,
            email = storedUser.email,
            isAnonymous = false,
        )
    }

    /**
     * Step 1 of a server switch (see ServerConnectionController.switchServer): drop the current
     * session and every piece of account-scoped local state, BEFORE the new server is saved.
     * Returns failure if any step threw; the controller then aborts the switch.
     */
    suspend fun prepareForServerSwitch(): Result<Unit> {
        _error.value = null
        val anonymousClear = runCatching { AuthStorage.clearAnonymousUserId() }
        validatedRemoteUserId = null
        val sessionClear = runCatching { SupabaseProvider.client.auth.clearSession() }
        // Fork: run the FULL account-data wipe (same semantics as signOut()). Upstream only clears
        // the session here; on this fork the wipe is what erases per-profile payloads, sync
        // cursors, provider credentials and Trakt/Simkl tokens — nothing from server A may sync
        // into server B. Mobile's LocalAccountDataCleaner is installed by the fork's composeApp
        // too, so the divergence applies to every frontend of this fork.
        val localCleanup = runCatching { AccountDataCleanerProvider.cleaner.wipe() }
        _state.value = AuthState.Unauthenticated
        val failure = anonymousClear.exceptionOrNull()
            ?: sessionClear.exceptionOrNull()
            ?: localCleanup.exceptionOrNull()
        val cancellation = sessionClear.exceptionOrNull() as? CancellationException
        if (cancellation != null) throw cancellation
        return if (failure == null) {
            Result.success(Unit)
        } else {
            log.e(failure) { "Server-switch preparation did not complete cleanly" }
            Result.failure(failure)
        }
    }

    /**
     * Step 3 of a server switch (after SupabaseProvider.reset()): tear down the collectors that
     * captured the previous client and run [initialize] again against the new one. Observers of
     * [state] (Swift AuthViewModel, Compose) keep working — same StateFlow instance.
     */
    fun reinitialize() {
        sessionStatusJob?.cancel()
        sessionStatusJob = null
        restoreWatchdogJob?.cancel()
        restoreWatchdogJob = null
        // Fork: a watchdog that fired for the OLD client must not suppress Loading for the new one.
        sessionRestoreTimedOut = false
        initialized = false
        validatedRemoteUserId = null
        refreshFailureActive = false
        _state.value = AuthState.Loading
        initialize()
    }

    private suspend fun validateRemoteSession(userId: String): Boolean {
        if (userId.isBlank() || validatedRemoteUserId == userId) return true

        return runCatching {
            SupabaseProvider.client.auth.retrieveUserForCurrentSession(false)
            validatedRemoteUserId = userId
            true
        }.getOrElse { e ->
            if (isInvalidRemoteSessionError(e)) {
                log.w(e) { "Stored Supabase session no longer belongs to an active account; clearing local auth" }
                clearLocalSessionAfterRemoteInvalidation()
                false
            } else {
                log.w(e) { "Unable to validate stored Supabase session; keeping cached auth state" }
                true
            }
        }
    }

    @OptIn(ExperimentalUuidApi::class)
    fun signInAnonymously() {
        _error.value = null
        val userId = Uuid.random().toString()
        AuthStorage.saveAnonymousUserId(userId)
        _state.value = AuthState.Authenticated(
            userId = userId,
            email = null,
            isAnonymous = true,
        )
    }

    suspend fun signUpWithEmail(email: String, password: String): Result<Unit> = runCatching {
        _error.value = null
        SupabaseProvider.client.auth.signUpWith(Email) {
            this.email = email
            this.password = password
        }
        Unit
    }.onFailure { e ->
        log.e(e) { "Email sign-up failed" }
        _error.value = e.safeAuthErrorDescription()
            ?: resourceString("Sign-up failed", StringKey.auth_sign_up_failed)
    }

    suspend fun signInWithEmail(email: String, password: String): Result<Unit> = runCatching {
        _error.value = null
        SupabaseProvider.client.auth.signInWith(Email) {
            this.email = email
            this.password = password
        }
    }.onFailure { e ->
        log.e(e) { "Email sign-in failed" }
        _error.value = e.safeAuthErrorDescription()
            ?: resourceString("Sign-in failed", StringKey.auth_sign_in_failed)
    }

    suspend fun signOut(): Result<Unit> {
        _error.value = null
        val anonymousRead = runCatching { AuthStorage.loadAnonymousUserId() }
        val wasAnonymous = anonymousRead.getOrNull() != null
        val anonymousClear = runCatching { AuthStorage.clearAnonymousUserId() }
        validatedRemoteUserId = null
        val remoteSignOut = if (wasAnonymous) {
            Result.success(Unit)
        } else {
            runCatching { SupabaseProvider.client.auth.signOut() }
        }

        val fallbackSessionClear = if (remoteSignOut.isFailure) {
            runCatching { SupabaseProvider.client.auth.clearSession() }
                .onFailure { error -> log.w(error) { "Failed to clear Supabase session after sign-out failure" } }
        } else {
            Result.success(Unit)
        }
        // Fork: route local cleanup through the AccountDataCleanerProvider seam
        // (LocalAccountDataCleaner is composeApp-only).
        val localCleanup = runCatching { AccountDataCleanerProvider.cleaner.wipe() }
        _state.value = AuthState.Unauthenticated

        val failure = anonymousRead.exceptionOrNull()
            ?: anonymousClear.exceptionOrNull()
            ?: remoteSignOut.exceptionOrNull()
            ?: fallbackSessionClear.exceptionOrNull()
            ?: localCleanup.exceptionOrNull()
        val cancellation = remoteSignOut.exceptionOrNull() as? CancellationException
            ?: fallbackSessionClear.exceptionOrNull() as? CancellationException
        if (cancellation != null) throw cancellation
        return if (failure == null) {
            Result.success(Unit)
        } else {
            log.e(failure) { "Sign-out did not complete cleanly; all local cleanup steps were attempted" }
            _error.value = failure.message
                ?: resourceString("Sign out failed", StringKey.auth_sign_out_failed)
            Result.failure(failure)
        }
    }

    suspend fun signOutIfSessionInvalid(error: Throwable, source: String): Boolean {
        if (!isInvalidRemoteSessionError(error)) return false
        if (refreshFailureActive) {
            // STAB-01: the token could not be refreshed (offline or server error), so a 401/403
            // here is the stale token talking. Keep the account; the refresh retry settles it.
            log.w(error) { "$source failed while the session refresh is failing; keeping local auth" }
            return false
        }

        log.w(error) { "$source failed because the current Supabase account/session is no longer valid; clearing local auth" }
        clearLocalSessionAfterRemoteInvalidation()
        return true
    }

    private suspend fun clearLocalSessionAfterRemoteInvalidation() {
        _error.value = null
        AuthStorage.clearAnonymousUserId()
        validatedRemoteUserId = null
        runCatching {
            SupabaseProvider.client.auth.clearSession()
        }.onFailure { e ->
            log.w(e) { "Failed to clear Supabase session after remote invalidation; continuing local reset" }
        }
        val localCleanup = runCatching { AccountDataCleanerProvider.cleaner.wipe() }
        _state.value = AuthState.Unauthenticated
        localCleanup.onFailure { error ->
            log.e(error) { "Local account cleanup failed after remote session invalidation" }
        }
    }

    suspend fun deleteAccount(): Result<Unit> = runCatching {
        _error.value = null
        SupabaseProvider.client.functions.invoke("delete-account")
        SupabaseProvider.client.auth.signOut()
        validatedRemoteUserId = null
        try {
            AccountDataCleanerProvider.cleaner.wipe()
        } finally {
            _state.value = AuthState.Unauthenticated
        }
    }.onFailure { e ->
        log.e(e) { "Account deletion failed" }
        _error.value = e.message ?: resourceString("Account deletion failed", StringKey.auth_account_deletion_failed)
    }

    fun clearError() {
        _error.value = null
    }

    private fun isInvalidRemoteSessionError(error: Throwable): Boolean {
        val restError = error.findCause<RestException>()
        val message = buildString {
            append(error.message.orEmpty())
            if (restError != null) {
                append(' ')
                append(restError.error)
                append(' ')
                append(restError.description)
            }
        }.lowercase()

        // STAB-01: an expired access token is not a deleted account. supabase-kt refreshes it (or
        // reports NotAuthenticated when the refresh token itself is revoked), so wiping local
        // data on "JWT expired" signed people out after any long network drop.
        if ("jwt" in message && "expired" in message) return false
        if (restError?.statusCode == 401 || restError?.statusCode == 403) return true

        return (
            "jwt" in message &&
                ("invalid" in message || "malformed" in message)
            ) || (
            "user" in message &&
                ("does not exist" in message || "not found" in message || "deleted" in message)
            ) || (
            "foreign key" in message &&
                ("auth.users" in message || "user_id" in message)
            )
    }

    private fun Throwable.safeAuthErrorDescription(): String? =
        findCause<AuthRestException>()
            ?.errorDescription
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: findCause<RestException>()
                ?.description
                ?.trim()
                ?.takeIf { it.isNotEmpty() }

    private inline fun <reified T : Throwable> Throwable.findCause(): T? {
        var current: Throwable? = this
        while (current != null) {
            if (current is T) return current
            current = current.cause
        }
        return null
    }
}
