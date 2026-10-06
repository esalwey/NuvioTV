package com.nuvio.app.features.auth

import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.TvLoginRepository
import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.network.NetworkStatusRepository
import com.nuvio.app.core.network.ServerAuthRequirement
import com.nuvio.app.core.network.ServerConfiguration
import com.nuvio.app.core.network.ServerConfigurationRepository
import com.nuvio.app.core.network.ServerDiscoveryException
import com.nuvio.app.core.network.ServerDiscoveryFailure
import com.nuvio.app.core.network.ServerDiscoveryService
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.sync.ProfileSettingsSync
import com.nuvio.app.core.sync.SyncManager
import kotlin.concurrent.Volatile
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class ServerSwitchFailure {
    SessionClear,
    Save,
    Restart,
}

data class ServerConnectionUiState(
    val activeServer: ServerConfiguration = ServerConfigurationRepository.active.value,
    val isDiscovering: Boolean = false,
    val isSwitching: Boolean = false,
    val discoveredServer: ServerConfiguration? = null,
    val failure: ServerDiscoveryFailure? = null,
    val statusCode: Int? = null,
    val switchFailure: ServerSwitchFailure? = null,
    /**
     * Incremented once per SUCCESSFUL server switch. A durable success signal for conflated
     * observers (Compose collectors may never see the transient `isSwitching = true`): dismiss
     * switch UI when this changes, not on an isSwitching edge.
     */
    val switchGeneration: Int = 0,
)

/**
 * Discover-then-switch state machine shared by every frontend (Compose AuthScreen dialogs, tvOS
 * SwiftUI watches [state]). Lives in :shared (Compose-free) — upstream keeps it in composeApp.
 *
 * Init-order note: this object must NOT be referenced while AuthRepository / SupabaseProvider are
 * initialising (its state default reads ServerConfigurationRepository.active, nothing else).
 */
object ServerConnectionController {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("ServerConnectionController"))
    private val log = Logger.withTag("ServerConnectionController")
    private val _state = MutableStateFlow(ServerConnectionUiState())
    val state: StateFlow<ServerConnectionUiState> = _state.asStateFlow()
    private var discoveryJob: Job? = null

    /**
     * Which sign-in capability a discovered server must advertise. Phone/desktop keep the upstream
     * default (email+password); the tvOS installer sets [ServerAuthRequirement.EmailPasswordOrTvLogin]
     * so a QR-only self-hosted server is accepted.
     */
    // Fork: upstream has no requirement knob.
    @Volatile
    var authRequirement: ServerAuthRequirement = ServerAuthRequirement.EmailPassword

    fun discover(url: String) {
        if (_state.value.isDiscovering || _state.value.isSwitching) return
        discoveryJob?.cancel()
        discoveryJob = scope.launch {
            _state.update {
                it.copy(
                    isDiscovering = true,
                    discoveredServer = null,
                    failure = null,
                    statusCode = null,
                    switchFailure = null,
                )
            }
            ServerDiscoveryService.discover(url, authRequirement).fold(
                onSuccess = { server ->
                    _state.update { it.copy(isDiscovering = false, discoveredServer = server) }
                },
                onFailure = { error ->
                    val discoveryError = error as? ServerDiscoveryException
                    _state.update {
                        it.copy(
                            isDiscovering = false,
                            failure = discoveryError?.failure ?: ServerDiscoveryFailure.ConnectionFailed,
                            statusCode = discoveryError?.statusCode,
                        )
                    }
                },
            )
        }
    }

    fun connectDiscovered() {
        val server = _state.value.discoveredServer ?: return
        // Pre-flight the deterministic save precondition BEFORE switchServer runs the account
        // wipe: saveCustom() refuses when the feature policy is off, and the wipe-before-save
        // order is deliberate (server-A data must never sync into server B), so a save refusal
        // after the wipe would destroy local state without completing the switch.
        if (!FeaturePolicyProvider.policy.customServerConnectionsEnabled) {
            _state.update { it.copy(switchFailure = ServerSwitchFailure.Save) }
            return
        }
        switchServer { ServerConfigurationRepository.saveCustom(server) }
    }

    fun useOfficial() {
        if (!_state.value.activeServer.isCustom) return
        switchServer(ServerConfigurationRepository::useOfficial)
    }

    fun resetDiscovery() {
        if (_state.value.isSwitching) return
        discoveryJob?.cancel()
        discoveryJob = null
        _state.update {
            it.copy(
                isDiscovering = false,
                discoveredServer = null,
                failure = null,
                statusCode = null,
                switchFailure = null,
            )
        }
    }

    // Codex round 3: admission must be atomic BEFORE the coroutine is scheduled — checking
    // `_state.value.isSwitching` alone lets two rapid confirm presses both pass the guard (the
    // flag is only set once the first coroutine runs) and race two destructive wipes.
    private val switchAdmissionLock = SynchronizedObject()
    private var switchAdmitted = false

    private fun switchServer(save: () -> Boolean) {
        synchronized(switchAdmissionLock) {
            if (switchAdmitted) return
            switchAdmitted = true
        }
        scope.launch {
            _state.update { it.copy(isSwitching = true, failure = null, switchFailure = null) }
            try {
                // Fork: stop everything that holds the OLD client before the session/data wipe —
                // an in-flight QR poll or account-scoped sync coroutine would otherwise keep
                // talking to (or pushing server-A data through) a client that is about to close.
                // The wipe runs BEFORE save() on purpose: persisting the new server first would
                // risk cross-server contamination if the wipe then failed (old session + new
                // active server on next launch). The trade-off — a save() disk failure after the
                // wipe leaves the user signed out on the old server — is the safe side; callers
                // pre-flight the deterministic save preconditions (see connectDiscovered).
                TvLoginRepository.cancel()
                SyncManager.cancelAccountSync()
                if (AuthRepository.prepareForServerSwitch().isFailure) {
                    _state.update {
                        it.copy(isSwitching = false, switchFailure = ServerSwitchFailure.SessionClear)
                    }
                    return@launch
                }
                if (!save()) {
                    _state.update { it.copy(isSwitching = false, switchFailure = ServerSwitchFailure.Save) }
                    return@launch
                }
                SupabaseProvider.reset()
                AuthRepository.reinitialize()
                // Fork: re-arm settings-push observation — the wipe's clearAccountState() cancelled
                // it (idempotent; the tvOS cleaner also re-arms, composeApp's does not).
                ProfileSettingsSync.startObserving()
                NetworkStatusRepository.requestRefresh(force = true)
                _state.value = ServerConnectionUiState(
                    activeServer = ServerConfigurationRepository.active.value,
                    switchGeneration = _state.value.switchGeneration + 1,
                )
                log.i { "Switched server → ${ServerConfigurationRepository.active.value.displayHost}" }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.e(error) { "Server switch failed during restart" }
                _state.update { it.copy(isSwitching = false, switchFailure = ServerSwitchFailure.Restart) }
            } finally {
                synchronized(switchAdmissionLock) { switchAdmitted = false }
            }
        }
    }
}
