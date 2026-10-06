package com.nuvio.app.core.sync

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

internal const val PROFILE_PLAYER_SETTINGS_FEATURE = "player_settings"
internal const val PROFILE_DEBRID_SETTINGS_FEATURE = "debrid_settings"
internal const val PROFILE_TMDB_SETTINGS_FEATURE = "tmdb_settings"
internal const val PROFILE_MDBLIST_SETTINGS_FEATURE = "mdblist_settings"

/**
 * Credential keys that must NEVER ride the general profile-settings blob: they are owned by
 * [ProviderCredentialSync], which merges them per-provider instead of clobbering the whole set.
 *
 * The key spellings are transcribed from the storage `actual`s (`PlayerSettingsStorage`,
 * `DebridSettingsStorage`, `TmdbSettingsStorage`, `MdbListSettingsStorage`) — not inferred.
 *
 * Fork divergence: upstream registers three debrid providers (torbox/premiumize/realdebrid); this
 * fork also ships AllDebrid, whose `debrid_alldebrid_api_key` is exported by
 * `DebridSettingsStorage.exportToSyncPayload()` via `DebridProviders.all()`. It must be stripped
 * here too, or an AllDebrid key would still travel (and be clobbered) inside the settings blob.
 */
private val profileCredentialKeys = mapOf(
    PROFILE_PLAYER_SETTINGS_FEATURE to setOf(
        "animeskip_client_id",
        "introdb_api_key",
    ),
    PROFILE_DEBRID_SETTINGS_FEATURE to setOf(
        "debrid_torbox_api_key",
        "debrid_premiumize_api_key",
        "debrid_real_debrid_api_key",
        "debrid_alldebrid_api_key",
    ),
    PROFILE_TMDB_SETTINGS_FEATURE to setOf("tmdb_api_key"),
    PROFILE_MDBLIST_SETTINGS_FEATURE to setOf("mdblist_api_key"),
)

internal fun withoutProfileCredentials(feature: String, payload: JsonObject): JsonObject {
    val keys = profileCredentialKeys[feature].orEmpty()
    if (keys.isEmpty() || payload.keys.none(keys::contains)) return payload
    return JsonObject(payload.filterKeys { it !in keys })
}

internal fun preservingLocalProfileCredentials(
    feature: String,
    remotePayload: JsonObject,
    localPayload: JsonObject,
): JsonObject {
    val keys = profileCredentialKeys[feature].orEmpty()
    if (keys.isEmpty()) return remotePayload
    val merged = remotePayload.toMutableMap()
    keys.forEach { key ->
        val localValue = localPayload[key]?.takeUnless(::isBlankCredential)
        if (localValue != null) {
            // A present local credential always survives a remote blob apply — the whole point
            // of the split is that the blob can never clobber it.
            merged[key] = localValue
        } else {
            // Local absent/blank: STRIP the legacy remote value from the applied payload. It is
            // NOT lost — [extractLegacyCredentials] stages it with ProviderCredentialSync, which
            // applies it only where no provider row exists (Codex rounds 4+7: importing it here
            // made the credential observer treat it as a local edit and push it, resurrecting
            // deliberately-cleared credentials over their provider-row tombstones).
            merged.remove(key)
        }
    }
    return JsonObject(merged)
}

/**
 * The non-blank credential values a legacy (pre-split) remote blob still carries for [feature],
 * keyed by storage key. Staged with `ProviderCredentialSync.stageLegacyBlobCredentials` so the
 * migration path applies them ONLY where the per-provider store has no row and local has no
 * value — provider rows (including clear-tombstones) always win over the blob.
 */
internal fun extractLegacyCredentials(feature: String, remotePayload: JsonObject): Map<String, String> {
    val keys = profileCredentialKeys[feature].orEmpty()
    if (keys.isEmpty()) return emptyMap()
    return keys.mapNotNull { key ->
        remotePayload[key]
            ?.let(::credentialContent)
            ?.takeUnless(String::isBlank)
            ?.let { key to it }
    }.toMap()
}

/**
 * Copies [legacyPayload]'s non-blank credential keys (original elements, unmodified) back into a
 * sanitized [feature] payload. Used ONLY by the BUG-20 legacy-namespace seed: the first blob
 * written to this client's own namespace must still CARRY the legacy credentials, because it
 * becomes their only remote copy the moment later pulls stop consulting the legacy namespace —
 * a sanitized seed + a crash before the provider rows land would orphan them permanently
 * (Codex round 11). The standard pull → stage → seed-rows → sanitized-rewrite pipeline then
 * migrates and strips them with its own crash-safety.
 */
internal fun restoringLegacyCredentials(
    feature: String,
    sanitizedPayload: JsonObject,
    legacyPayload: JsonObject,
): JsonObject {
    val keys = profileCredentialKeys[feature].orEmpty()
    if (keys.isEmpty()) return sanitizedPayload
    val merged = sanitizedPayload.toMutableMap()
    keys.forEach { key ->
        legacyPayload[key]
            ?.takeUnless(::isBlankCredential)
            ?.let { merged[key] = it }
    }
    return JsonObject(merged)
}

/**
 * A credential slot that exists but holds no usable value ("" or whitespace).
 *
 * The storage exporters encode every synced value as a typed wrapper object —
 * `{"type":"string","value":"..."}` (see `encodeSyncString`) — NOT as a bare primitive, so the
 * wrapper's inner `value` is what decides blankness (Codex round 5: a primitive-only check read
 * every real credential as blank and inverted the local-wins invariant). The bare-primitive
 * branch stays as a defensive fallback for hand-written or legacy payloads.
 */
private fun isBlankCredential(value: kotlinx.serialization.json.JsonElement): Boolean =
    credentialContent(value).isNullOrBlank()

/** Unwraps a credential slot's string content from either encoding, or null if not a string. */
private fun credentialContent(value: kotlinx.serialization.json.JsonElement): String? = when (value) {
    is JsonPrimitive -> value.contentOrNull
    is JsonObject -> (value["value"] as? JsonPrimitive)?.contentOrNull
    else -> null
}
