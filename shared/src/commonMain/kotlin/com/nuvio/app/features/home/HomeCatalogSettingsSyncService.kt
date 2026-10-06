package com.nuvio.app.features.home

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.sync.CachedSharedSettings
import com.nuvio.app.core.sync.HOME_CATALOG_SHARED_SYNC_PLATFORM
import com.nuvio.app.core.sync.SettingsPullToken
import com.nuvio.app.core.sync.currentSettingsPullToken
import com.nuvio.app.core.sync.mergeSharedSettingsJson
import com.nuvio.app.core.sync.putSyncOriginClientId
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlin.concurrent.Volatile
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

@Serializable
data class SyncCatalogItem(
    @SerialName("addon_id") val addonId: String,
    val type: String,
    @SerialName("catalog_id") val catalogId: String,
    val enabled: Boolean = true,
    val order: Int = 0,
    @SerialName("custom_title") val customTitle: String = "",
    @SerialName("is_collection") val isCollection: Boolean = false,
    @SerialName("collection_id") val collectionId: String = "",
    val key: String = "",
)

@Serializable
data class SyncHomeCatalogPayload(
    @SerialName("show_catalog_type") val showCatalogType: Boolean = true,
    @SerialName("hide_unreleased_content") val hideUnreleasedContent: Boolean = false,
    @SerialName("hide_catalog_underline") val hideCatalogUnderline: Boolean = false,
    @SerialName("hide_discover") val hideDiscover: Boolean = false,
    val items: List<SyncCatalogItem> = emptyList(),
)

@Serializable
private data class SupabaseHomeCatalogSettingsBlob(
    @SerialName("profile_id") val profileId: Int = 1,
    @SerialName("settings_json") val settingsJson: JsonObject = buildJsonObject { },
)

private val homeCatalogJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

private const val HIDE_UNRELEASED_CONTENT_KEY = "hide_unreleased_content"
private const val SHOW_CATALOG_TYPE_KEY = "show_catalog_type"
private const val HIDE_CATALOG_UNDERLINE_KEY = "hide_catalog_underline"
private const val HIDE_DISCOVER_KEY = "hide_discover"

/**
 * Presence-gated decode: only the toggles the writing client actually modelled override
 * [localPayload]'s values — a client on an older schema omits a key entirely, and absence must
 * mean "not modelled" rather than "reset to the default". Returns null when [settingsJson] is not
 * this payload's shape at all; the caller turns that into a failed sync step. Kept top-level (not
 * a member) so it is unit-testable without touching [HomeCatalogSettingsSyncService]'s
 * network/auth state.
 */
internal fun decodeHomeCatalogPayloadPreservingLocalDefaults(
    settingsJson: JsonObject,
    localPayload: SyncHomeCatalogPayload,
): SyncHomeCatalogPayload? = runCatching {
    val decoded = homeCatalogJson.decodeFromJsonElement(SyncHomeCatalogPayload.serializer(), settingsJson)
    decoded.copy(
        showCatalogType = if (settingsJson.containsKey(SHOW_CATALOG_TYPE_KEY)) {
            decoded.showCatalogType
        } else {
            localPayload.showCatalogType
        },
        hideUnreleasedContent = if (settingsJson.containsKey(HIDE_UNRELEASED_CONTENT_KEY)) {
            decoded.hideUnreleasedContent
        } else {
            localPayload.hideUnreleasedContent
        },
        hideCatalogUnderline = if (settingsJson.containsKey(HIDE_CATALOG_UNDERLINE_KEY)) {
            decoded.hideCatalogUnderline
        } else {
            localPayload.hideCatalogUnderline
        },
        hideDiscover = if (settingsJson.containsKey(HIDE_DISCOVER_KEY)) {
            decoded.hideDiscover
        } else {
            localPayload.hideDiscover
        },
    )
}.getOrNull()

object HomeCatalogSettingsSyncService {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("HomeCatalogSettingsSync"))
    private val log = Logger.withTag("HomeCatalogSettingsSyncService")

    @Volatile
    var isSyncingFromRemote: Boolean = false

    private var pushJob: Job? = null

    @Volatile
    private var completedInitialPull: SettingsPullToken? = null

    @Volatile
    private var cachedSharedSettings: CachedSharedSettings? = null

    // Token of a local edit whose push was skipped because the initial pull for that token had
    // not completed. Consumed by pullFromServer's malformed-blob branch, which lets the edit win
    // and repair the blob; cleared once a pull for the token completes. Session-scoped like
    // [completedInitialPull]; the token's userId keeps it inert across account switches — but NOT
    // across a sign-out/sign-in of the SAME account, where the (userId, profileId) token is
    // reconstructed identically. See [clearAccountState].
    @Volatile
    private var localEditAwaitingInitialPull: SettingsPullToken? = null

    // Set when triggerPush() is skipped because the initial pull hasn't settled yet — a genuine
    // local edit made in that window must still be pushed once it does, or it is silently lost
    // until some unrelated setting changes (these pushes fire per-edit, not via a
    // distinctUntilChanged flow, so there is no later re-emission to catch it). No payload is
    // carried (unlike ProfileSettingsSync.pendingGatedPushSignature) because pushToRemote()
    // exports HomeCatalogSettingsRepository's CURRENT state at push time — but the owing
    // IDENTITIES must be: a bare flag (or a single token slot) lets one profile's settle or a
    // later edit under another profile consume/overwrite a different profile's owed edit (Codex
    // 2026-08-29 P2 rounds 1-2), losing it to the next remote-wins pull. Per-token debts, guarded
    // by [pendingLock]; a debt is removed only when its own push SUCCEEDS and re-added on any
    // failure or identity change, so it survives until honored or the account state is wiped.
    private val pendingLock = SynchronizedObject()
    private val pendingGatedPushTokens = mutableSetOf<SettingsPullToken>()

    private fun recordPendingGatedPush(token: SettingsPullToken) {
        synchronized(pendingLock) { pendingGatedPushTokens.add(token) }
    }

    private fun consumePendingGatedPush(token: SettingsPullToken): Boolean =
        synchronized(pendingLock) { pendingGatedPushTokens.remove(token) }

    suspend fun pullFromServer(profileId: Int) {
        val pullToken = currentSettingsPullToken(profileId) ?: return
        val localPayload = HomeCatalogSettingsRepository.exportToSyncPayload()
        // A fetch failure propagates so runOrderedProfileSync records this step as failed and
        // the full pull is retried, instead of the sync being stamped fresh with the remote
        // catalog settings silently unapplied (same rule as TrackingSourceSettingsSyncService).
        val remoteBlob = fetchRemoteBlob(profileId)
        cachedSharedSettings = CachedSharedSettings(
            token = pullToken,
            settingsJson = remoteBlob?.settingsJson ?: buildJsonObject { },
        )

        if (remoteBlob == null) {
            log.i { "pullFromServer — no remote home catalog settings found; preserving local" }
            markInitialPullComplete(pullToken)
            return
        }

        val remotePayload = decodeHomeCatalogPayloadPreservingLocalDefaults(remoteBlob.settingsJson, localPayload)
        if (remotePayload == null) {
            // Same rule as TrackingSourceSettingsSyncService: with no local edit pending, a
            // malformed blob fails the step — marking it successful would leave the stale local
            // settings active and suppress the retry that a recorded failure earns. A local edit
            // that raced the incomplete initial pull may instead win and repair the blob: its
            // push re-encodes every payload key over the malformed values. Without that escape
            // the step would wedge, because pushes stay gated on this pull completing and
            // nothing on this device could ever rewrite the blob.
            if (localEditAwaitingInitialPull != pullToken) {
                error("failed to parse remote home catalog settings")
            }
            log.w { "pullFromServer — remote home catalog settings malformed; repairing from the raced local edit" }
            // localEditAwaitingInitialPull and this token's pending debt are always recorded
            // together by the same triggerPush() skip, so the owed push this repair satisfies
            // (via the direct pushToRemote() below) is this same edit's — consume it here so
            // markInitialPullComplete()'s retry doesn't also schedule a redundant duplicate push.
            consumePendingGatedPush(pullToken)
            markInitialPullComplete(pullToken)
            if (!pushToRemote(pullToken)) {
                // Keep the edit owed so the retried step attempts the repair again.
                localEditAwaitingInitialPull = pullToken
                error("pushing the raced local home catalog edit over the malformed remote blob failed")
            }
            return
        }

        if (remotePayload.items.isEmpty()) {
            log.i { "pullFromServer — remote has empty items, preserving local catalog order" }
            applyRemotePayload(remotePayload)
            markInitialPullComplete(pullToken)
            return
        }

        applyRemotePayload(remotePayload)
        log.i { "pullFromServer — applied ${remotePayload.items.size} items from remote" }
        markInitialPullComplete(pullToken)
    }

    fun triggerPush() {
        val requestedToken = currentSettingsPullToken()
        if (requestedToken == null || !hasCompletedInitialPull(requestedToken)) {
            // Every call here is a genuine local mutation (applyFromRemote never triggers a
            // push), so a skip means a local edit raced the incomplete initial pull — remember
            // it so that pull can repair a malformed remote blob with it. Deliberately NOT
            // edit-wins overall: unlike the tracking-source twin, a well-formed remote payload
            // still applies over the raced edit (home's pull is remote-wins).
            if (requestedToken != null) {
                localEditAwaitingInitialPull = requestedToken
                // Remembered, not dropped: this edit is owed a push once the pull settles — see
                // maybeRetryGatedPush() (ProfileSettingsSync race lesson P2;
                // docs/addon-wipe-investigation-2026-08-28.md).
                recordPendingGatedPush(requestedToken)
                // Re-check AFTER recording (ProfileSettingsSync race lesson P2, round 6/7): the
                // settling pull can land between the gate read above and the flag being set —
                // markInitialPullComplete()'s own retry would then have found no flag yet to
                // consume. Either that settle sees the flag, or this re-check sees the settle;
                // maybeRetryGatedPush() consumes the flag before scheduling, so both firing is a
                // harmless no-op on the second call, never a double push.
                if (hasCompletedInitialPull(requestedToken)) {
                    maybeRetryGatedPush(requestedToken)
                } else {
                    log.d { "triggerPush — skipped before initial home catalog pull completed" }
                }
            } else {
                log.d { "triggerPush — skipped before initial home catalog pull completed" }
            }
            return
        }
        pushJob?.cancel()
        pushJob = scope.launch {
            delay(500)
            if (isSyncingFromRemote) return@launch
            if (currentSettingsPullToken() != requestedToken) return@launch
            pushToRemote(requestedToken)
        }
    }

    fun clearAccountState() {
        // Wipe-hole fix: completedInitialPull and localEditAwaitingInitialPull are
        // SettingsPullToken (userId, profileId)-keyed, but signing out then back in as the SAME
        // user/profile reconstructs an IDENTICAL token — so leaving these set would satisfy the
        // gate over freshly-emptied local state, and the next local edit would full-replace-push
        // an emptied item list over the account's remote blob
        // (docs/addon-wipe-investigation-2026-08-28.md). cachedSharedSettings is likewise a stale
        // snapshot of the previous account's remote state. pushJob is cancelled for the same
        // reason: a debounced push scheduled just before the wipe would otherwise still pass its
        // token-equality check post re-sign-in (same token) and fire with whatever
        // HomeCatalogSettingsRepository holds by the time it runs. Mirrors
        // TrackingSourceSettingsSyncService.clearAccountState().
        pushJob?.cancel()
        pushJob = null
        completedInitialPull = null
        cachedSharedSettings = null
        localEditAwaitingInitialPull = null
        synchronized(pendingLock) { pendingGatedPushTokens.clear() }
    }

    private suspend fun pushToRemote(token: SettingsPullToken): Boolean =
        runCatching {
            val payload = HomeCatalogSettingsRepository.exportToSyncPayload()
            val jsonElement = mergedSharedPayloadJson(token, payload)

            val params = buildJsonObject {
                put("p_profile_id", token.profileId)
                put("p_platform", HOME_CATALOG_SHARED_SYNC_PLATFORM)
                put("p_settings_json", jsonElement)
                putSyncOriginClientId()
            }
            SupabaseProvider.client.postgrest.rpc("sync_push_home_catalog_settings", params)
            cachedSharedSettings = CachedSharedSettings(token = token, settingsJson = jsonElement)
            log.d { "pushToRemote — success" }
        }.fold(
            onSuccess = { true },
            onFailure = { e ->
                if (e is kotlinx.coroutines.CancellationException) throw e
                log.e(e) { "pushToRemote — FAILED" }
                false
            },
        )

    private fun hasCompletedInitialPull(token: SettingsPullToken): Boolean =
        completedInitialPull == token

    /// Settles the gate with the identity the pull STARTED under — and only if that identity is
    /// still current on BOTH axes: currentSettingsPullToken() reads the live user AND the live
    /// active profile, so a mid-pull account switch or profile switch (pullFromServer suspends
    /// across the RPC) can never settle a namespace that was not the one pulled. [token] itself is
    /// always the value captured at the top of pullFromServer, before its first suspension — this
    /// only re-validates it is still live at mark time (mirrors
    /// ProfileSettingsSync.markInitialPullComplete, Codex 2026-08-28 P1).
    private fun markInitialPullComplete(token: SettingsPullToken) {
        if (token != currentSettingsPullToken()) {
            log.d { "settle skipped — identity changed mid-pull (profile ${token.profileId})" }
            return
        }
        completedInitialPull = token
        if (localEditAwaitingInitialPull == token) localEditAwaitingInitialPull = null
        maybeRetryGatedPush(token)
    }

    /// If triggerPush() skipped a push before this settled, push now that it's safe.
    /// pushToRemote() exports the CURRENT HomeCatalogSettingsRepository state, so no payload needs
    /// to be carried across the wait — only the fact that one is owed, and by WHOM (see
    /// [pendingGatedPushTokens]): a debt is consumed only by its own identity's settle, so
    /// another profile's settle can never eat a different profile's edit.
    private fun maybeRetryGatedPush(token: SettingsPullToken) {
        if (!consumePendingGatedPush(token)) return
        pushJob?.cancel()
        pushJob = scope.launch {
            try {
                runDeferredGatedPush(token)
            } catch (error: CancellationException) {
                // The shared pushJob slot means ANOTHER token's retry (or a newer debounced push)
                // can cancel this one after its debt was already consumed (Codex 2026-08-29 P2
                // round 3) — put the debt back so the token's next settle retries it. A token
                // re-added after clearAccountState's cancel is harmless: its gate requires the
                // same identity to settle again, and the push then exports post-wipe state.
                recordPendingGatedPush(token)
                throw error
            }
        }
    }

    private suspend fun runDeferredGatedPush(token: SettingsPullToken) {
        // The identity can change in the gap between this settling pull and this launched
        // block actually running — pin to the settled token and revalidate it is still live
        // before pushing, or a profile switched to mid-gap would be pushed unpulled
        // (ProfileSettingsSync race lesson P1, round 6). The debt goes BACK on the books in
        // that case: it belongs to the token, and the token's next settled pull retries it.
        if (currentSettingsPullToken() != token) {
            log.d { "deferred push deferred again — identity changed before it ran (profile ${token.profileId})" }
            recordPendingGatedPush(token)
            return
        }
        // A failed owed push must stay owed (Codex 2026-08-29 P2): re-record so the NEXT
        // settled pull for this identity retries it — without this, a transient network
        // failure here loses the edit until some unrelated mutation pushes again.
        if (!pushToRemote(token)) {
            recordPendingGatedPush(token)
        }
    }

    private fun applyRemotePayload(
        payload: SyncHomeCatalogPayload,
    ) {
        isSyncingFromRemote = true
        try {
            HomeCatalogSettingsRepository.applyFromRemote(payload)
        } finally {
            isSyncingFromRemote = false
        }
    }

    private suspend fun fetchRemoteBlob(
        profileId: Int,
    ): SupabaseHomeCatalogSettingsBlob? {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
            put("p_platform", HOME_CATALOG_SHARED_SYNC_PLATFORM)
        }
        val result = SupabaseProvider.client.postgrest.rpc("sync_pull_home_catalog_settings", params)
        return result.decodeList<SupabaseHomeCatalogSettingsBlob>().firstOrNull()
    }

    private fun mergedSharedPayloadJson(
        token: SettingsPullToken,
        payload: SyncHomeCatalogPayload,
    ): JsonObject {
        val localJson = homeCatalogJson.encodeToJsonElement(SyncHomeCatalogPayload.serializer(), payload).jsonObject
        val remoteJson = cachedSharedSettings
            ?.takeIf { cached -> cached.token == token }
            ?.settingsJson
        return mergeSharedSettingsJson(remoteJson = remoteJson, localJson = localJson)
    }
}
