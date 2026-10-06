package com.nuvio.app.features.trakt

import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.sync.putSyncOriginClientId
import com.nuvio.app.features.profiles.ProfileRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

private const val TRAKT_PROVIDER = "trakt"

@Serializable
private data class ProviderCredentialRow(
    val provider: String,
    @SerialName("credential_json") val credentialJson: JsonObject,
    @SerialName("updated_at") val updatedAt: String? = null,
)

/**
 * FORK NOTE (Trakt API-client ownership guard): Trakt tokens are bound to the OAuth client
 * (`TraktConfig.CLIENT_ID`) that minted them; this fork's tvOS build uses its own registration
 * while other devices may run the official client id. Upstream removed cross-device credential
 * push/pull entirely (rejected-refresh invalidation instead), which also removes the historic
 * fork failure mode of adopting a foreign token (2026-07-07: TV bricked by the phone's synced
 * token). What remains is `deleteRemote`, called when OUR refresh token is rejected or the user
 * disconnects — the guard below keeps it from deleting a leftover remote row minted by a
 * DIFFERENT client (an old official-app push that an old phone build may still pull).
 */
object TraktCredentialSync {
    private val log = Logger.withTag("TraktCredentialSync")
    private val mutex = Mutex()

    private enum class RemoteOwnership { NoRow, Ours, Foreign }

    private suspend fun remoteOwnership(profileId: Int): RemoteOwnership {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
        }
        val result = SupabaseProvider.client.postgrest.rpc("sync_pull_provider_credentials", params)
        val rows = result.decodeList<ProviderCredentialRow>()
        val row = rows.firstOrNull { it.provider.equals(TRAKT_PROVIDER, ignoreCase = true) }
            ?: return RemoteOwnership.NoRow
        val rowClientId = row.credentialJson.stringValue("api_client_id")
        return if (rowClientId == TraktConfig.CLIENT_ID) RemoteOwnership.Ours else RemoteOwnership.Foreign
    }

    suspend fun deleteRemote(profileId: Int = ProfileRepository.activeProfileId): Boolean =
        mutex.withLock {
            val authState = AuthRepository.state.value
            if (authState !is AuthState.Authenticated || authState.isAnonymous) return@withLock false

            runCatching {
                // Fork guard: never delete a remote row minted by another Trakt API client.
                if (remoteOwnership(profileId) == RemoteOwnership.Foreign) {
                    log.i { "Skipping Trakt credential delete; remote row belongs to another API client" }
                    return@runCatching false
                }
                val params = buildJsonObject {
                    put("p_profile_id", profileId)
                    put("p_provider", TRAKT_PROVIDER)
                    putSyncOriginClientId()
                }
                SupabaseProvider.client.postgrest.rpc("sync_delete_provider_credentials", params)
                true
            }.getOrElse { error ->
                log.e(error) { "deleteRemote(profileId=$profileId) failed" }
                false
            }
        }
}

private fun JsonObject.stringValue(key: String): String? =
    this[key]?.jsonPrimitive?.contentOrNull
