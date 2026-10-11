package com.nuvio.app.features.servers

import co.touchlab.kermit.Logger
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** A server brand the user can sign in to (the rows of the "Add a server" section). */
data class MediaServerProviderInfo(
    val id: String,
    val displayName: String,
    /** "10.9", "4.7": the oldest server version the provider supports, for the unsupported-version message. */
    val minimumVersion: String,
)

data class MediaServerLibraryInfo(
    val id: String,
    val name: String,
    /** The library's content type: "movie", "series", "collection" or "mixed". */
    val kind: String,
    val selected: Boolean,
)

/** What the server row and detail page say about a connection's health. */
enum class MediaServerStatus {
    OK,
    DISABLED,
    SIGN_IN_REQUIRED,
    UNREACHABLE,
}

/**
 * One connected Jellyfin / Emby account, flattened to plain values for the tvOS settings pages.
 * Never carries the access token.
 */
data class MediaServerInfo(
    val id: String,
    val providerId: String,
    val providerName: String,
    val name: String,
    val address: String,
    val userName: String,
    val enabled: Boolean,
    val useCatalogMetadata: Boolean,
    val importWatchState: Boolean,
    /** The provider can match catalog titles by external id, which "Use addon metadata" relies on. */
    val supportsCatalogMetadata: Boolean,
    /** The provider can read watched state and resume points, which "Import watch progress" relies on. */
    val supportsWatchStateImport: Boolean,
    val libraries: List<MediaServerLibraryInfo>,
    val status: MediaServerStatus,
)

data class MediaServersUiState(
    val servers: List<MediaServerInfo> = emptyList(),
    val providers: List<MediaServerProviderInfo> = emptyList(),
    /** A sign-in is running; the password has left the form and only lives in that request. */
    val isConnecting: Boolean = false,
    val connectFailure: ServerFailure? = null,
    /** The provider whose sign-in [connectFailure] belongs to (for the "unsupported version" text). */
    val connectFailureProviderId: String? = null,
    /** Bumped once per successful sign-in; [connectedServerId] names the connection it produced. */
    val connectGeneration: Int = 0,
    val connectedServerId: String? = null,
    /** The connection whose library list is being refreshed. */
    val refreshingServerId: String? = null,
    /** Bumped when a refresh fails, so the page can surface it once per failure. */
    val refreshFailureGeneration: Int = 0,
    val refreshFailure: ServerFailure? = null,
)

/**
 * Swift-facing controller for Settings → Media servers. The tvOS counterpart of upstream's
 * `MediaServersSettingsPage` / `MediaServerSettingsPage` / `ServerSignInSheet` state: every action
 * is fire-and-forget into [ServerRepository] and every outcome comes back through [state].
 */
object MediaServersController {
    private val log = Logger.withTag("MediaServersController")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("MediaServersController"))
    private val local = MutableStateFlow(LocalState())

    private data class LocalState(
        val isConnecting: Boolean = false,
        val connectFailure: ServerFailure? = null,
        val connectFailureProviderId: String? = null,
        val connectGeneration: Int = 0,
        val connectedServerId: String? = null,
        val refreshingServerId: String? = null,
        val refreshFailureGeneration: Int = 0,
        val refreshFailure: ServerFailure? = null,
    )

    val state: StateFlow<MediaServersUiState> = combine(ServerRepository.uiState, local) { servers, localState ->
        MediaServersUiState(
            servers = servers.connections.map { it.toInfo(servers.failures[it.id]) },
            providers = ServerProviders.registered.map { MediaServerProviderInfo(it.id, it.displayName, it.minimumVersion) },
            isConnecting = localState.isConnecting,
            connectFailure = localState.connectFailure,
            connectFailureProviderId = localState.connectFailureProviderId,
            connectGeneration = localState.connectGeneration,
            connectedServerId = localState.connectedServerId,
            refreshingServerId = localState.refreshingServerId,
            refreshFailureGeneration = localState.refreshFailureGeneration,
            refreshFailure = localState.refreshFailure,
        )
    }.stateIn(scope, SharingStarted.Eagerly, MediaServersUiState(providers = providerInfos()))

    init {
        ServerRepository.ensureLoaded()
    }

    /** Loads the active profile's connections; call before the first read so [state] is never one profile behind. */
    fun ensureLoaded() {
        ServerRepository.ensureLoaded()
    }

    /**
     * Signs in and stores the connection. A second call while one is running is ignored. Signing in
     * again to a server that is already connected replaces its token and keeps its library choices.
     */
    fun connect(providerId: String, address: String, username: String, password: String) {
        if (local.value.isConnecting) return
        val provider = ServerProviders.forId(providerId) ?: return
        local.update { it.copy(isConnecting = true, connectFailure = null, connectFailureProviderId = null) }
        scope.launch {
            try {
                val connection = ServerRepository.connect(provider, address, username.trim(), password)
                local.update {
                    it.copy(
                        isConnecting = false,
                        connectGeneration = it.connectGeneration + 1,
                        connectedServerId = connection.id,
                    )
                }
            } catch (cancelled: CancellationException) {
                local.update { it.copy(isConnecting = false) }
                throw cancelled
            } catch (error: Throwable) {
                log.w { "Signing in to ${provider.id} failed: ${error.serverFailure()}" }
                local.update {
                    it.copy(
                        isConnecting = false,
                        connectFailure = error.serverFailure(),
                        connectFailureProviderId = provider.id,
                    )
                }
            }
        }
    }

    /** Forgets the last sign-in error (the form was edited, or the sheet closed). */
    fun clearConnectFailure() {
        local.update { it.copy(connectFailure = null, connectFailureProviderId = null) }
    }

    fun refreshLibraries(connectionId: String) {
        if (local.value.refreshingServerId != null) return
        local.update { it.copy(refreshingServerId = connectionId, refreshFailure = null) }
        scope.launch {
            try {
                ServerRepository.refreshLibraries(connectionId)
                local.update { it.copy(refreshingServerId = null) }
            } catch (cancelled: CancellationException) {
                local.update { it.copy(refreshingServerId = null) }
                throw cancelled
            } catch (error: Throwable) {
                log.w { "Refreshing libraries of $connectionId failed: ${error.serverFailure()}" }
                local.update {
                    it.copy(
                        refreshingServerId = null,
                        refreshFailure = error.serverFailure(),
                        refreshFailureGeneration = it.refreshFailureGeneration + 1,
                    )
                }
            }
        }
    }

    /**
     * Indexes the selected libraries in the background, so the first "find this title on my server"
     * lookup of a session does not wait for the index. Cheap to repeat: an index is reused until it
     * goes stale or the connections change.
     */
    fun warm() {
        ServerMatcher.warm()
    }

    fun setEnabled(connectionId: String, enabled: Boolean) = ServerRepository.setEnabled(connectionId, enabled)

    fun setCatalogMetadata(connectionId: String, enabled: Boolean) = ServerRepository.setCatalogMetadata(connectionId, enabled)

    fun setImportWatchState(connectionId: String, enabled: Boolean) = ServerRepository.setImportWatchState(connectionId, enabled)

    fun setLibrarySelected(connectionId: String, libraryId: String, selected: Boolean) =
        ServerRepository.setLibrarySelected(connectionId, libraryId, selected)

    /** Signs out of the server (best effort) and forgets the connection and its token. */
    fun remove(connectionId: String) = ServerRepository.remove(connectionId)

    private fun providerInfos(): List<MediaServerProviderInfo> =
        ServerProviders.registered.map { MediaServerProviderInfo(it.id, it.displayName, it.minimumVersion) }

    private fun ServerConnection.toInfo(failure: ServerFailure?): MediaServerInfo {
        val provider = ServerRepository.provider(this)
        return MediaServerInfo(
            id = id,
            providerId = providerId,
            providerName = provider?.displayName ?: providerId,
            name = name,
            address = address,
            userName = userName,
            enabled = enabled,
            useCatalogMetadata = useCatalogMetadata,
            importWatchState = importWatchState,
            supportsCatalogMetadata = provider?.supports(ServerCapability.EXTERNAL_ID_LOOKUP) == true,
            supportsWatchStateImport = provider?.supports(ServerCapability.USER_STATE_READ) == true,
            libraries = libraries.map { MediaServerLibraryInfo(it.id, it.name, it.kind.contentType, it.selected) },
            status = when {
                !enabled -> MediaServerStatus.DISABLED
                failure == ServerFailure.AUTH_REQUIRED -> MediaServerStatus.SIGN_IN_REQUIRED
                failure == ServerFailure.UNREACHABLE -> MediaServerStatus.UNREACHABLE
                else -> MediaServerStatus.OK
            },
        )
    }
}
