package com.nuvio.app.core.sync

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

internal const val PROVIDER_API_KEY_FIELD = "api_key"
internal const val PROVIDER_CLIENT_ID_FIELD = "client_id"

internal object ProviderCredentialIds {
    const val TMDB = "tmdb"
    const val MDBLIST = "mdblist"
    const val ANIMESKIP = "animeskip"
    const val INTRODB = "introdb"

    fun debrid(providerId: String): String = "debrid:$providerId"
}

internal data class ProviderCredentialValue(
    val provider: String,
    val field: String,
    val value: String,
) {
    fun credentialJson(): JsonObject = buildJsonObject {
        put(field, value.trim())
    }
}

internal data class ProviderCredentialSnapshot(
    val profileId: Int,
    val values: List<ProviderCredentialValue>,
) {
    init {
        require(values.map(ProviderCredentialValue::provider).distinct().size == values.size)
    }

    /**
     * Applies pulled provider rows over this snapshot.
     *
     * Upstream 1854dfc3 ("prevent automatic pulls from restoring deleted data"): the pull is
     * authoritative, so a provider with NO remote row is cleared locally — its key was removed
     * elsewhere (or never synced) — instead of keeping the local value, which the next
     * whole-snapshot push would have re-uploaded over the deletion.
     *
     * Fork: [deviceLocalProviders] are exempt. The backend refuses them outright (see
     * `ProviderCredentialSync.BACKEND_UNSUPPORTED_PROVIDERS`), so they can never have a row and
     * the local key is their only copy.
     */
    fun mergeRemote(
        rows: List<SupabaseProviderCredential>,
        deviceLocalProviders: Set<String> = emptySet(),
    ): ProviderCredentialSnapshot {
        val remoteByProvider = rows.associateBy { it.provider.lowercase() }
        return copy(
            values = values.map { local ->
                val remote = remoteByProvider[local.provider.lowercase()]
                    ?: return@map if (local.provider in deviceLocalProviders) local else local.copy(value = "")
                val element = remote.credentialJson[local.field] as? JsonPrimitive
                    ?: error("Invalid credential payload for ${local.provider}")
                val value = element.contentOrNull
                    ?: error("Invalid credential value for ${local.provider}")
                local.copy(value = value.trim())
            },
        )
    }
}

/**
 * Whether [snapshot] holds a provider that has no remote row yet. Fork-only since upstream
 * 1854dfc3 dropped the seed: `ProviderCredentialSync` now seeds ONLY credentials staged from a
 * legacy settings blob (the one-time pre-split migration), never the plain local snapshot.
 */
internal fun shouldSeedProviderCredentials(
    snapshot: ProviderCredentialSnapshot,
    rows: List<SupabaseProviderCredential>,
): Boolean {
    val remoteProviders = rows.mapTo(mutableSetOf()) { row -> row.provider.lowercase() }
    return snapshot.values.any { credential -> credential.provider.lowercase() !in remoteProviders }
}

@Serializable
internal data class SupabaseProviderCredential(
    val provider: String,
    @SerialName("credential_json") val credentialJson: JsonObject,
    @SerialName("updated_at") val updatedAt: String? = null,
)
