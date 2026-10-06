package com.nuvio.app.core.sync

import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Shared plumbing for the services that sync one settings JSON blob per (user, profile) under a
// shared namespace — [com.nuvio.app.features.home.HomeCatalogSettingsSyncService] and
// [com.nuvio.app.features.tracking.TrackingSourceSettingsSyncService]. Each service keeps its own
// pull/push state machine; only the account/profile identity token, the cached-remote snapshot,
// and the push merge are identical by design and live here.

/**
 * Identity a pull ran under. State captured under a stale token (account or active profile
 * switched mid-flight) must not be applied or pushed.
 */
internal data class SettingsPullToken(
    val userId: String,
    val profileId: Int,
)

/**
 * Snapshot of the shared-namespace settings blob fetched during the most recent
 * [SettingsPullToken], kept so a service's push path can merge against it without issuing a
 * second remote fetch on every push (ported from upstream `f9c13a9b`). Invalidated implicitly: a
 * push under a stale token merges remote-less rather than reading data for the wrong account.
 *
 * Knowingly imperfect, upstream-faithful tradeoff (Codex 2026-08-24): the cache is refreshed on
 * pull and after each successful push, but another client writing an unknown-to-this-client field
 * BETWEEN this session's pull and a later push gets that field overwritten with the cached value
 * (the RPCs are replace-style). The pre-`f9c13a9b` fetch-before-every-push only shrank that race
 * window, never closed it, and upstream deliberately traded it for one fewer RPC per push —
 * diverging here would fork merge semantics from upstream's apps on the same account.
 */
internal data class CachedSharedSettings(
    val token: SettingsPullToken,
    val settingsJson: JsonObject,
)

internal fun currentSettingsPullToken(
    profileId: Int = ProfileRepository.activeProfileId,
): SettingsPullToken? {
    val authState = AuthRepository.state.value
    if (authState !is AuthState.Authenticated || authState.isAnonymous) return null
    return SettingsPullToken(
        userId = authState.userId,
        profileId = profileId,
    )
}

/**
 * Pure merge of the shared-namespace remote blob with this client's local payload: remote entries
 * first, local overwrites on key collision — so unknown remote fields survive a push. Kept
 * top-level so it is unit-testable without touching the services' network/auth state.
 */
internal fun mergeSharedSettingsJson(
    remoteJson: JsonObject?,
    localJson: JsonObject,
): JsonObject = buildJsonObject {
    remoteJson?.forEach { (key, value) -> put(key, value) }
    localJson.forEach { (key, value) -> put(key, value) }
}
