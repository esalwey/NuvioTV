package com.nuvio.app.core.sync

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.features.collection.CollectionMobileSettingsRepository
import com.nuvio.app.features.collection.CollectionMobileSettingsStorage
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.debrid.DebridSettingsStorage
import com.nuvio.app.features.details.MetaScreenSettingsStorage
import com.nuvio.app.features.details.MetaScreenSettingsRepository
import com.nuvio.app.features.home.HomeCatalogSettingsSyncService
import com.nuvio.app.features.mdblist.MdbListMetadataService
import com.nuvio.app.features.mdblist.MdbListSettingsStorage
import com.nuvio.app.features.mdblist.MdbListSettingsRepository
import com.nuvio.app.features.notifications.EpisodeReleaseNotificationsRepository
import com.nuvio.app.features.player.PlayerSettingsStorage
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.core.ui.CardDepthStyleRepository
import com.nuvio.app.core.ui.CardDepthStyleStorage
import com.nuvio.app.core.ui.PosterCardStyleRepository
import com.nuvio.app.core.ui.PosterCardStyleStorage
import com.nuvio.app.features.settings.ThemeSettingsStoreProvider
import com.nuvio.app.features.settings.ThemeSettingsRepository
import com.nuvio.app.features.streams.StreamBadgeSettingsRepository
import com.nuvio.app.features.streams.StreamBadgeSettingsStorage
import com.nuvio.app.features.tmdb.TmdbSettingsStorage
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.tracking.TrackingSourceSettingsSyncService
import com.nuvio.app.features.trakt.TraktCommentsStorage
import com.nuvio.app.features.trakt.TraktCommentsSettings
import com.nuvio.app.features.trakt.TraktSettingsStorage
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesStorage
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlin.concurrent.Volatile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put

private const val PUSH_DEBOUNCE_MS = 1500L

object ProfileSettingsSync {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("ProfileSettingsSync"))
    private val log = Logger.withTag("ProfileSettingsSync")
    private val syncMutex = Mutex()
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Volatile
    private var isApplyingRemoteBlob: Boolean = false

    @Volatile
    private var isServerSyncInFlight: Boolean = false

    @Volatile
    private var skipNextPushSignature: String? = null

    // Identity of the last SETTLED pull — "settled" meaning we definitively observed the remote
    // namespace for this (user, profile): applied a blob, found it matching, or found it provably
    // empty (incl. the legacy-seed path). A decode failure, a features-less blob, or a thrown
    // fetch is NOT settled: the namespace may hold data this client couldn't read, and the
    // observer's full-replace push must never be composed against unknown remote state — that is
    // the addon-wipe shape (docs/addon-wipe-investigation-2026-08-28.md). Mirrors
    // TrackingSourceSettingsSyncService.completedInitialPull.
    @Volatile
    private var completedInitialPull: SettingsPullToken? = null

    // Signature of an observer emission the settle gate skipped, kept so a user edit made
    // BEFORE the first pull settles is pushed right after it does (Codex 2026-08-28 P2) —
    // `distinctUntilChanged` would otherwise never re-emit it, leaving the edit local-only
    // until some unrelated setting changes.
    @Volatile
    private var pendingGatedPushSignature: String? = null

    // Identity of the most recent pull — used only to drop a stale `skipNextPushSignature` when
    // the (user, profile) changes between pulls (see the reset in `pull`).
    @Volatile
    private var lastPullToken: SettingsPullToken? = null

    private fun hasCompletedInitialPull(token: SettingsPullToken): Boolean =
        settingsPushAllowed(completedInitialPull, token)

    /// Settles the gate with the identity the pull STARTED under — and only if that identity is
    /// still current on BOTH axes: `currentSettingsPullToken()` reads the live user AND the live
    /// active profile, so a mid-pull account switch or profile switch (the pull suspends across
    /// RPCs) can never settle a namespace that was not the one pulled (Codex 2026-08-28 P1 ×2 —
    /// the first round compared against `token.profileId`, which masked profile switches).
    private fun markInitialPullComplete(token: SettingsPullToken) {
        if (token != currentSettingsPullToken()) {
            log.d { "settle skipped — identity changed mid-pull (profile ${token.profileId})" }
            return
        }
        completedInitialPull = token
        maybeRetryGatedPush(token)
    }

    /// If the gate skipped an emission before settling, push now that it is safe — unless the
    /// current state is exactly what the pull just applied (`skipNextPushSignature`), in which
    /// case the server already holds it and the owed push would be a redundant rewrite.
    ///
    /// Known, deliberate limit (Codex 2026-08-28 P2, declined): only the SIGNATURE is retained,
    /// so a pre-settle edit that the pull's remote apply then overwrites locally is not restored
    /// — the post-apply state matches the server and this returns without pushing. Restoring a
    /// captured pre-settle payload would be worse: that payload is mostly unhydrated defaults,
    /// and re-applying it post-settle is exactly the full-replace wipe this gate exists to stop.
    /// Doing this properly needs per-setter edit provenance (the
    /// TrackingSourceSettingsSyncService model) across all 17 repositories — out of scope. The
    /// window is the few seconds before the ordered sync's FIRST step settles, the loss is one
    /// visible-in-UI setting reverting to the account's value, and the pre-gate behavior for the
    /// same window was pushing the whole unhydrated blob over the account.
    private fun maybeRetryGatedPush(token: SettingsPullToken) {
        pendingGatedPushSignature ?: return
        pendingGatedPushSignature = null
        if (currentObservedStateSignature() == skipNextPushSignature) {
            // Consumed WITH the echo (Codex 2026-08-28 P2 round 7): left set, a later user edit
            // that restores exactly this state would have its emission mistaken for the old echo
            // by the observer's skip branch and never pushed.
            skipNextPushSignature = null
            return
        }
        // The launch runs after the settling pull releases syncMutex; the identity can change in
        // that gap, and pushCurrentProfileToRemote() exports whatever profile is active at push
        // time — so the push must be pinned to the settled token and revalidated under the mutex
        // (Codex 2026-08-28 P1 round 6), or a profile switched to mid-gap would be pushed unpulled.
        scope.launch { pushProfileToRemoteIfCurrent(token) }
    }

    /// pushCurrentProfileToRemote(), but only if the given settled identity is STILL the live
    /// (user, profile) once the mutex is held — the deferred-push path's guard against pushing a
    /// namespace that was never pulled.
    private suspend fun pushProfileToRemoteIfCurrent(token: SettingsPullToken): Boolean {
        ensureRepositoriesLoaded()
        return syncMutex.withLock {
            if (token != currentSettingsPullToken()) {
                log.d { "deferred push skipped — identity changed before it ran (profile ${token.profileId})" }
                return@withLock false
            }
            runCatching {
                pushToRemoteLocked(token.profileId, exportSettingsBlob())
                true
            }.onFailure { error ->
                log.e(error) { "deferred push for profile ${token.profileId} FAILED" }
            }.getOrDefault(false)
        }
    }

    private var observeJob: Job? = null

    fun startObserving() {
        if (observeJob?.isActive == true) return
        ensureRepositoriesLoaded()
        ProviderCredentialSync.startObserving()
        TrackingSourceSettingsSyncService.startObserving()
        observeLocalChangesAndPush()
    }

    fun clearAccountState() {
        observeJob?.cancel()
        observeJob = null
        skipNextPushSignature = null
        completedInitialPull = null
        pendingGatedPushSignature = null
        lastPullToken = null
        ProviderCredentialSync.clearAccountState()
        TrackingSourceSettingsSyncService.clearAccountState()
        HomeCatalogSettingsSyncService.clearAccountState()
    }

    /**
     * Upstream 1854dfc3 (profile-switch race). The profile fan-out has just reloaded every observed
     * repository from the new profile's storage; that reload is not a user edit, so its signature
     * becomes the skip signature. The fork's settle gate already holds a switch to a profile whose
     * pull has not settled yet; this covers a fan-out that lands while the gate is OPEN for the
     * selected identity (the active profile selected again), whose emission would otherwise push
     * local state over newer remote settings. A new identity's first pull resets the skip
     * signature (see `lastPullToken` in [pull]), so this never swallows a pull's echo.
     * Also re-baselines the provider credentials. Called last in the tvOS profile fan-out.
     */
    fun onProfileChanged() {
        if (observeJob?.isActive != true) return
        skipNextPushSignature = currentObservedStateSignature()
        ProviderCredentialSync.onProfileChanged()
    }

    suspend fun pull(profileId: Int): Boolean {
        ensureRepositoriesLoaded()
        return syncMutex.withLock {
            if (ProfileRepository.activeProfileId != profileId) {
                log.d { "pull(profileId=$profileId) — skipped because profile is no longer active" }
                return@withLock false
            }
            // The identity every settle in this pull is stamped with — captured BEFORE the first
            // suspension so a mid-pull account switch can never settle the new user's gate.
            val pullToken = currentSettingsPullToken(profileId) ?: run {
                log.d { "pull(profileId=$profileId) — skipped: no signed-in non-anonymous account" }
                return@withLock false
            }
            // A skip signature is only meaningful for the identity whose apply produced it: left
            // global, a stale value could (on an exact composite-signature collision) swallow a
            // DIFFERENT profile's deferred push in maybeRetryGatedPush (Codex 2026-08-28 P2
            // round 6). Dropping it on identity change is free — the old echo emission would
            // compute the new profile's signature and never match it anyway.
            if (lastPullToken != pullToken) {
                skipNextPushSignature = null
                lastPullToken = pullToken
            }
            isServerSyncInFlight = true
            try {
                val localBlob = exportSettingsBlob()
                if (ProfileRepository.activeProfileId != profileId) return@withLock false
                val localSignature = buildSignature(localBlob)

                val remoteJson = fetchRemoteSettingsJson(profileId, SyncPlatformProvider.platform)
                if (ProfileRepository.activeProfileId != profileId) return@withLock false

                if (remoteJson == null) {
                    // BUG-20: no blob under our own namespace yet — one-shot migration seed from
                    // the legacy scope(s) this client used to share with other apps.
                    return@withLock seedFromLegacyPlatformsLocked(profileId, pullToken)
                }

                isApplyingRemoteBlob = true
                try {
                    val remoteBlob = runCatching {
                        json.decodeFromJsonElement(MobileProfileSettingsBlob.serializer(), remoteJson)
                    }.getOrElse { error ->
                        log.e(error) { "pull(profileId=$profileId) — failed to decode remote settings blob" }
                        return@withLock false
                    }
                    // Compare CREDENTIAL-STRIPPED signatures: the local export is always
                    // sanitized now, so a legacy remote blob still carrying credentials would
                    // never compare equal and every foreground pull would re-apply everything +
                    // fan out onProfileChanged() with nothing changed (Codex round 6). BUT a
                    // legacy blob that matches on everything else must still APPLY once — that
                    // apply is the migration path that imports its credentials (see
                    // preservingLocalProfileCredentials) — so only the credential-free case may
                    // short-circuit.
                    val remoteSignature = buildSignature(withoutBlobCredentials(remoteBlob))
                    if (remoteSignature == localSignature && !blobCarriesCredentials(remoteBlob)) {
                        markInitialPullComplete(pullToken)
                        log.d { "pull(profileId=$profileId) — remote matches local" }
                        return@withLock false
                    }

                    if (ProfileRepository.activeProfileId != profileId) return@withLock false
                    if (!applyRemoteBlob(remoteBlob, remoteJson)) {
                        log.w { "pull(profileId=$profileId) — remote blob has no features object; preserving local" }
                        return@withLock false
                    }
                    skipNextPushSignature = currentObservedStateSignature()
                } finally {
                    isApplyingRemoteBlob = false
                }

                markInitialPullComplete(pullToken)
                log.i { "pull(profileId=$profileId) — applied remote settings blob" }
                true
            } catch (error: Exception) {
                log.e(error) { "pull(profileId=$profileId) — FAILED" }
                false
            } finally {
                isServerSyncInFlight = false
            }
        }
    }

    private suspend fun fetchRemoteSettingsJson(profileId: Int, platform: String): JsonObject? {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
            put("p_platform", platform)
        }
        val result = SupabaseProvider.client.postgrest.rpc("sync_pull_profile_settings_blob", params)
        return result.decodeList<SettingsBlobResponse>().firstOrNull()?.settingsJson
    }

    /**
     * BUG-20 migration: called (under [syncMutex]) when [SyncPlatformProvider.platform] has no
     * settings blob for this profile yet. Reads each legacy namespace once, applies the first
     * blob found (presence-gated — a foreign-schema blob must not reset settings it doesn't
     * carry), and immediately writes the seeded state to our OWN namespace so later pulls find
     * it there. The legacy scope is never written: other clients keep their blob untouched.
     */
    private suspend fun seedFromLegacyPlatformsLocked(profileId: Int, pullToken: SettingsPullToken): Boolean {
        // A legacy fetch that THREW is inconclusive — that namespace may hold a migratable blob we
        // simply couldn't reach, and settling anyway would let the observer create our own-platform
        // blob from defaults, after which pulls never consult the legacy namespace again and the
        // user's legacy settings are stranded (Codex 2026-08-28 P1). A blob that fetched fine but
        // is undecodable / features-less is NOT inconclusive: it is definitively unusable and will
        // be on every retry, so it must not hold the gate closed forever.
        var legacyLookupInconclusive = false
        for (legacyPlatform in SyncPlatformProvider.legacySettingsPlatforms) {
            val legacyJson = runCatching { fetchRemoteSettingsJson(profileId, legacyPlatform) }
                .getOrElse { error ->
                    log.e(error) { "pull(profileId=$profileId) — legacy '$legacyPlatform' fetch FAILED" }
                    legacyLookupInconclusive = true
                    null
                } ?: continue
            if (ProfileRepository.activeProfileId != profileId) return false

            val legacyBlob = runCatching {
                json.decodeFromJsonElement(MobileProfileSettingsBlob.serializer(), legacyJson)
            }.getOrElse { error ->
                log.e(error) { "pull(profileId=$profileId) — failed to decode legacy '$legacyPlatform' blob" }
                continue
            }

            isApplyingRemoteBlob = true
            try {
                if (!applyRemoteBlob(legacyBlob, legacyJson)) {
                    log.w { "pull(profileId=$profileId) — legacy '$legacyPlatform' blob has no features object; skipping" }
                    continue
                }
                skipNextPushSignature = currentObservedStateSignature()
            } finally {
                isApplyingRemoteBlob = false
            }

            // The seeded blob must keep the legacy blob's credentials (see
            // restoringLegacyCredentials): once this push lands, later pulls never consult the
            // legacy namespace again, so a credential-stripped seed would leave the in-memory
            // migration stash as their only copy — one process death away from losing them.
            val export = exportSettingsBlob()
            val seeded = export.copy(
                features = export.features.copy(
                    playerSettings = restoringLegacyCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, export.features.playerSettings, legacyBlob.features.playerSettings),
                    debridSettings = restoringLegacyCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, export.features.debridSettings, legacyBlob.features.debridSettings),
                    tmdbSettings = restoringLegacyCredentials(PROFILE_TMDB_SETTINGS_FEATURE, export.features.tmdbSettings, legacyBlob.features.tmdbSettings),
                    mdbListSettings = restoringLegacyCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, export.features.mdbListSettings, legacyBlob.features.mdbListSettings),
                ),
            )
            runCatching { pushToRemoteLocked(profileId, seeded) }
                .onFailure { error ->
                    // Seed push failed — settings applied locally; the next pull retries the
                    // migration (our namespace is still empty), which is safe to repeat.
                    log.e(error) { "pull(profileId=$profileId) — seed push to '${SyncPlatformProvider.platform}' FAILED" }
                }

            markInitialPullComplete(pullToken)
            log.i { "pull(profileId=$profileId) — seeded '${SyncPlatformProvider.platform}' settings from legacy '$legacyPlatform'" }
            return true
        }

        if (legacyLookupInconclusive) {
            log.w { "pull(profileId=$profileId) — legacy lookup inconclusive; gate stays closed, retried next sync" }
            return false
        }
        // Fresh-account case: no blob under our own namespace and none under any legacy
        // namespace either — this account's settings namespace is provably empty, not unread.
        // Without marking here a brand-new account could never pass the observer's gate and
        // would be unable to push settings for the very first time.
        markInitialPullComplete(pullToken)
        log.i { "pull(profileId=$profileId) — no remote settings blob found" }
        return false
    }

    suspend fun pushCurrentProfileToRemote(): Boolean {
        ensureRepositoriesLoaded()
        return syncMutex.withLock {
            runCatching {
                val profileId = ProfileRepository.activeProfileId
                val blob = exportSettingsBlob()
                if (ProfileRepository.activeProfileId != profileId) return@runCatching false
                pushToRemoteLocked(profileId, blob)
                true
            }.onFailure { error ->
                log.e(error) { "pushCurrentProfileToRemote() — FAILED" }
            }.getOrDefault(false)
        }
    }

    @OptIn(FlowPreview::class)
    private fun observeLocalChangesAndPush() {
        val signatureFlows = listOf(
            ThemeSettingsRepository.selectedTheme.map { "theme" },
            ThemeSettingsRepository.amoledEnabled.map { "amoled" },
            ThemeSettingsRepository.liquidGlassNativeTabBarEnabled.map { "liquid_glass_tab_bar" },
            ThemeSettingsRepository.navBarStyle.map { "nav_bar_style" },
            PosterCardStyleRepository.uiState.map { "poster_card_style" },
            CardDepthStyleRepository.uiState.map { "card_depth_style" },
            PlayerSettingsRepository.uiState.map { "player" },
            StreamBadgeSettingsRepository.uiState.map { "stream_badges" },
            DebridSettingsRepository.uiState.map { "debrid" },
            TmdbSettingsRepository.uiState.map { "tmdb" },
            MdbListSettingsRepository.uiState.map { "mdblist" },
            MetaScreenSettingsRepository.uiState.map { "meta" },
            CollectionMobileSettingsRepository.uiState.map { "collection_mobile_settings" },
            ContinueWatchingPreferencesRepository.uiState.map { "continue_watching" },
            TraktSettingsRepository.uiState.map { "trakt_settings" },
            TraktCommentsSettings.enabled.map { "trakt_comments" },
            EpisodeReleaseNotificationsRepository.uiState.map { "episode_release_alerts" },
        )

        observeJob = scope.launch {
            combine(signatureFlows) { currentObservedStateSignature() }
                // Upstream 1854dfc3: distinct BEFORE drop(1). The other way round, the first
                // emission after the initial one passed even when its signature was unchanged
                // (any repository re-publishing an identical state) and pushed the blob for nothing.
                .distinctUntilChanged()
                .drop(1)
                .debounce(PUSH_DEBOUNCE_MS)
                .collect { signature ->
                    val authState = AuthRepository.state.value
                    if (authState !is AuthState.Authenticated || authState.isAnonymous) return@collect
                    // Addon-wipe class guard (docs/addon-wipe-investigation-2026-08-28.md): the profile fan-out
                    // mutates these 17 flows automatically, so an emission arriving before this (user, profile)'s
                    // first settled pull would full-replace the account's blob with unhydrated local defaults.
                    val token = currentSettingsPullToken() ?: return@collect
                    if (!hasCompletedInitialPull(token)) {
                        // Remembered, not dropped: `distinctUntilChanged` never re-emits this
                        // signature, so a genuine pre-settle user edit is owed a push once the
                        // pull settles — see maybeRetryGatedPush().
                        pendingGatedPushSignature = signature
                        // Re-check AFTER recording (Codex 2026-08-28 P2 round 6): settling can
                        // race this collector between the gate read above and the record — the
                        // marker's retry would have found no pending yet. Either the marker sees
                        // the pending, or this re-check sees the settle; both firing just makes
                        // the second a no-op on the cleared pending. On a settled re-check the
                        // emission goes through the token-pinned retry, NOT the fall-through path
                        // below — the settling pull can still hold `isServerSyncInFlight`, whose
                        // bailout would drop the pending this branch just recorded (round 7).
                        if (hasCompletedInitialPull(token)) {
                            maybeRetryGatedPush(token)
                        } else {
                            log.d { "push — deferred until initial settings pull settles for profile ${token.profileId}" }
                        }
                        return@collect
                    }
                    if (isApplyingRemoteBlob || isServerSyncInFlight) return@collect
                    // Upstream 1854dfc3: a stale emission (the state moved on during the debounce,
                    // e.g. mid profile fan-out) is dropped — the newer state emits on its own.
                    if (signature != currentObservedStateSignature()) return@collect
                    if (signature == skipNextPushSignature) {
                        skipNextPushSignature = null
                        return@collect
                    }
                    pushCurrentProfileToRemote()
                }
        }
    }

    /**
     * One-time cleanup completing the legacy credential migration: rewrites a still
     * credential-bearing remote blob in sanitized form. Without it the carries-credentials
     * bypass in [pull] re-applies the whole blob (and fans out onProfileChanged()) on EVERY
     * foreground sync — `skipNextPushSignature` suppresses exactly the observer push that would
     * otherwise rewrite it (Codex round 9). Called by ProviderCredentialSync ONLY after the
     * staged legacy credentials have been successfully seeded into provider rows — rewriting any
     * earlier would delete the credentials' only remote copy while the seed can still fail
     * (Codex round 10). A failed rewrite is safe: the next pull re-applies + re-stages from the
     * unchanged blob, the (insert-if-absent) re-seed no-ops, and the rewrite is retried.
     */
    internal suspend fun rewriteLegacyBlobSanitized(profileId: Int) {
        syncMutex.withLock {
            if (ProfileRepository.activeProfileId != profileId) return@withLock
            runCatching { pushToRemoteLocked(profileId, exportSettingsBlob()) }
                .onFailure { error ->
                    log.w(error) { "rewriteLegacyBlobSanitized(profileId=$profileId) failed — next pull retries" }
                }
        }
    }

    private suspend fun pushToRemoteLocked(profileId: Int, blob: MobileProfileSettingsBlob) {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
            put("p_platform", SyncPlatformProvider.platform)
            put("p_settings_json", json.encodeToJsonElement(MobileProfileSettingsBlob.serializer(), blob))
            putSyncOriginClientId()
        }
        SupabaseProvider.client.postgrest.rpc("sync_push_profile_settings_blob", params)
        log.d { "pushToRemoteLocked(profileId=$profileId) — success" }
    }

    private fun exportSettingsBlob(): MobileProfileSettingsBlob {
        ensureRepositoriesLoaded()
        return MobileProfileSettingsBlob(
            features = MobileProfileSettingsFeatures(
                themeSettings = ThemeSettingsStoreProvider.store.exportToSyncPayload(),
                posterCardStyleSettingsPayload = PosterCardStyleStorage.loadPayload().orEmpty().trim(),
                cardDepthStyleSettingsPayload = CardDepthStyleStorage.loadPayload().orEmpty().trim(),
                // Provider credentials are stripped here and synced per-provider by
                // ProviderCredentialSync instead — a whole-blob push must never carry them.
                playerSettings = withoutProfileCredentials(
                    PROFILE_PLAYER_SETTINGS_FEATURE,
                    PlayerSettingsStorage.exportToSyncPayload(),
                ),
                streamBadgeSettings = StreamBadgeSettingsStorage.exportToSyncPayload(),
                debridSettings = withoutProfileCredentials(
                    PROFILE_DEBRID_SETTINGS_FEATURE,
                    DebridSettingsStorage.exportToSyncPayload(),
                ),
                tmdbSettings = withoutProfileCredentials(
                    PROFILE_TMDB_SETTINGS_FEATURE,
                    TmdbSettingsStorage.exportToSyncPayload(),
                ),
                mdbListSettings = withoutProfileCredentials(
                    PROFILE_MDBLIST_SETTINGS_FEATURE,
                    MdbListSettingsStorage.exportToSyncPayload(),
                ),
                metaScreenSettingsPayload = MetaScreenSettingsStorage.loadPayload().orEmpty().trim(),
                collectionMobileSettingsPayload = CollectionMobileSettingsStorage.loadPayload().orEmpty().trim(),
                continueWatchingSettingsPayload = ContinueWatchingPreferencesStorage.loadPayload().orEmpty().trim(),
                traktSettingsPayload = TraktSettingsStorage.loadPayload().orEmpty().trim(),
                traktCommentsSettings = TraktCommentsStorage.exportToSyncPayload(),
                notificationsSettings = NotificationsSettingsPayload(
                    episodeReleaseAlertsEnabled = EpisodeReleaseNotificationsRepository.uiState.value.isEnabled,
                ),
            ),
        )
    }

    /**
     * Applies [blob] to local storage, but only the feature blocks actually PRESENT in the raw
     * [remoteJson] (BUG-20): the decoded struct fills absent fields with empty defaults, and
     * blindly applying those wiped every setting the writing client's schema doesn't carry —
     * e.g. upstream's Android TV blob has no card-depth/poster-style payloads, so each of its
     * pushes reset them here. Absence now means "that client doesn't model this" and the local
     * value is preserved.
     *
     * @return false (nothing applied) when [remoteJson] carries no `features` object at all.
     */
    private fun applyRemoteBlob(blob: MobileProfileSettingsBlob, remoteJson: JsonObject): Boolean {
        val rawFeatures = remoteJson["features"] as? JsonObject ?: return false
        fun has(key: String) = rawFeatures.containsKey(key)

        // Legacy-blob credential migration (Codex rounds 4+7): a pre-split blob may still carry
        // credentials. They are STRIPPED from every payload applied below (see
        // preservingLocalProfileCredentials) and staged instead — ProviderCredentialSync applies
        // them only into true voids (no provider row, blank local), so a provider row's
        // clear-tombstone is never resurrected and the staged value never reads as a local edit.
        val legacy = extractLegacyCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, blob.features.playerSettings) +
            extractLegacyCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, blob.features.debridSettings) +
            extractLegacyCredentials(PROFILE_TMDB_SETTINGS_FEATURE, blob.features.tmdbSettings) +
            extractLegacyCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, blob.features.mdbListSettings)
        if (legacy.isNotEmpty()) {
            ProviderCredentialSync.stageLegacyBlobCredentials(ProfileRepository.activeProfileId, legacy)
        }

        if (has("theme_settings")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "theme_settings",
                current = ThemeSettingsStoreProvider.store.exportToSyncPayload(),
                incoming = blob.features.themeSettings,
                apply = { ThemeSettingsStoreProvider.store.replaceFromSyncPayload(blob.features.themeSettings) },
                notifyChanged = { ThemeSettingsRepository.onProfileChanged() },
            )
        }

        if (has("poster_card_style_settings_payload")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "poster_card_style_settings_payload",
                current = PosterCardStyleStorage.loadPayload().orEmpty().trim(),
                incoming = blob.features.posterCardStyleSettingsPayload.trim(),
                apply = { PosterCardStyleStorage.savePayload(blob.features.posterCardStyleSettingsPayload) },
                notifyChanged = { PosterCardStyleRepository.onProfileChanged() },
            )
        }

        if (has("card_depth_style_settings_payload")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "card_depth_style_settings_payload",
                current = CardDepthStyleStorage.loadPayload().orEmpty().trim(),
                incoming = blob.features.cardDepthStyleSettingsPayload.trim(),
                apply = { CardDepthStyleStorage.savePayload(blob.features.cardDepthStyleSettingsPayload) },
                notifyChanged = { CardDepthStyleRepository.onProfileChanged() },
            )
        }

        if (has("player_settings")) {
            // Credentials are owned by ProviderCredentialSync: snapshot the local values BEFORE
            // replaceFromSyncPayload() wipes this feature's keys, then re-assert them over the
            // remote payload. `introdb_api_key` is not part of exportToSyncPayload(), so it is
            // carried separately and written back explicitly.
            val localPlayerSettings = PlayerSettingsStorage.exportToSyncPayload()
            val localIntroDbApiKey = PlayerSettingsStorage.loadIntroDbApiKey()
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "player_settings",
                current = withoutProfileCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, localPlayerSettings),
                incoming = withoutProfileCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, blob.features.playerSettings),
                forceApply = blobCarriesFeatureCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, blob.features.playerSettings),
                apply = {
                    PlayerSettingsStorage.replaceFromSyncPayload(
                        preservingLocalProfileCredentials(
                            PROFILE_PLAYER_SETTINGS_FEATURE,
                            blob.features.playerSettings,
                            localPlayerSettings,
                        ),
                    )
                    // Blank local = "no credential" (same rule as preservingLocalProfileCredentials):
                    // re-saving a blank here would clobber an IntroDB key the replace just imported
                    // from a legacy remote blob — the one place that key can come back from on an
                    // upgraded fresh install (Codex round 6).
                    localIntroDbApiKey?.takeUnless(String::isBlank)?.let(PlayerSettingsStorage::saveIntroDbApiKey)
                },
                notifyChanged = { PlayerSettingsRepository.onProfileChanged() },
            )
        }

        if (has("stream_badge_settings")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "stream_badge_settings",
                current = StreamBadgeSettingsStorage.exportToSyncPayload(),
                incoming = blob.features.streamBadgeSettings,
                apply = { StreamBadgeSettingsStorage.replaceFromSyncPayload(blob.features.streamBadgeSettings) },
                notifyChanged = { StreamBadgeSettingsRepository.onProfileChanged() },
            )
        }

        if (has("debrid_settings")) {
            val localDebridSettings = DebridSettingsStorage.exportToSyncPayload()
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "debrid_settings",
                current = withoutProfileCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, localDebridSettings),
                incoming = withoutProfileCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, blob.features.debridSettings),
                forceApply = blobCarriesFeatureCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, blob.features.debridSettings),
                apply = {
                    DebridSettingsStorage.replaceFromSyncPayload(
                        preservingLocalProfileCredentials(
                            PROFILE_DEBRID_SETTINGS_FEATURE,
                            blob.features.debridSettings,
                            localDebridSettings,
                        ),
                    )
                },
                notifyChanged = { DebridSettingsRepository.onProfileChanged() },
            )
        }

        if (has("tmdb_settings")) {
            val localTmdbSettings = TmdbSettingsStorage.exportToSyncPayload()
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "tmdb_settings",
                current = withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, localTmdbSettings),
                incoming = withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, blob.features.tmdbSettings),
                forceApply = blobCarriesFeatureCredentials(PROFILE_TMDB_SETTINGS_FEATURE, blob.features.tmdbSettings),
                apply = {
                    TmdbSettingsStorage.replaceFromSyncPayload(
                        preservingLocalProfileCredentials(
                            PROFILE_TMDB_SETTINGS_FEATURE,
                            blob.features.tmdbSettings,
                            localTmdbSettings,
                        ),
                    )
                },
                notifyChanged = { TmdbSettingsRepository.onProfileChanged() },
            )
        }

        if (has("mdblist_settings")) {
            val localMdbListSettings = MdbListSettingsStorage.exportToSyncPayload()
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "mdblist_settings",
                current = withoutProfileCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, localMdbListSettings),
                incoming = withoutProfileCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, blob.features.mdbListSettings),
                forceApply = blobCarriesFeatureCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, blob.features.mdbListSettings),
                apply = {
                    MdbListSettingsStorage.replaceFromSyncPayload(
                        preservingLocalProfileCredentials(
                            PROFILE_MDBLIST_SETTINGS_FEATURE,
                            blob.features.mdbListSettings,
                            localMdbListSettings,
                        ),
                    )
                    MdbListMetadataService.clearCache()
                },
                notifyChanged = { MdbListSettingsRepository.onProfileChanged() },
            )
        }

        if (has("meta_screen_settings_payload")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "meta_screen_settings_payload",
                current = MetaScreenSettingsStorage.loadPayload().orEmpty().trim(),
                incoming = blob.features.metaScreenSettingsPayload.trim(),
                apply = { MetaScreenSettingsStorage.savePayload(blob.features.metaScreenSettingsPayload) },
                notifyChanged = { MetaScreenSettingsRepository.onProfileChanged() },
            )
        }

        if (has("collection_mobile_settings_payload")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "collection_mobile_settings_payload",
                current = CollectionMobileSettingsStorage.loadPayload().orEmpty().trim(),
                incoming = blob.features.collectionMobileSettingsPayload.trim(),
                apply = { CollectionMobileSettingsStorage.savePayload(blob.features.collectionMobileSettingsPayload) },
                notifyChanged = { CollectionMobileSettingsRepository.onProfileChanged() },
            )
        }

        if (has("continue_watching_settings_payload")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "continue_watching_settings_payload",
                current = ContinueWatchingPreferencesStorage.loadPayload().orEmpty().trim(),
                incoming = blob.features.continueWatchingSettingsPayload.trim(),
                apply = { ContinueWatchingPreferencesStorage.savePayload(blob.features.continueWatchingSettingsPayload) },
                notifyChanged = { ContinueWatchingPreferencesRepository.onProfileChanged() },
            )
        }

        if (has("trakt_settings_payload")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "trakt_settings_payload",
                current = TraktSettingsStorage.loadPayload().orEmpty().trim(),
                incoming = blob.features.traktSettingsPayload.trim(),
                apply = { TraktSettingsStorage.savePayload(blob.features.traktSettingsPayload) },
                notifyChanged = { TraktSettingsRepository.onProfileChanged() },
            )
        }

        if (has("trakt_comments_settings")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "trakt_comments_settings",
                current = TraktCommentsStorage.exportToSyncPayload(),
                incoming = blob.features.traktCommentsSettings,
                apply = { TraktCommentsStorage.replaceFromSyncPayload(blob.features.traktCommentsSettings) },
                notifyChanged = { TraktCommentsSettings.onProfileChanged() },
            )
        }

        if (has("notifications_settings")) {
            applyFeatureUnlessUnchanged(
                log = log,
                featureName = "notifications_settings",
                current = EpisodeReleaseNotificationsRepository.uiState.value.isEnabled,
                incoming = blob.features.notificationsSettings.episodeReleaseAlertsEnabled,
                apply = {
                    EpisodeReleaseNotificationsRepository.applyFromSyncEnabled(
                        blob.features.notificationsSettings.episodeReleaseAlertsEnabled,
                    )
                },
                notifyChanged = {},
            )
        }

        return true
    }

    private fun ensureRepositoriesLoaded() {
        ThemeSettingsRepository.ensureLoaded()
        PosterCardStyleRepository.ensureLoaded()
        CardDepthStyleRepository.ensureLoaded()
        PlayerSettingsRepository.ensureLoaded()
        StreamBadgeSettingsRepository.ensureLoaded()
        DebridSettingsRepository.ensureLoaded()
        TmdbSettingsRepository.ensureLoaded()
        MdbListSettingsRepository.ensureLoaded()
        MetaScreenSettingsRepository.ensureLoaded()
        CollectionMobileSettingsRepository.ensureLoaded()
        ContinueWatchingPreferencesRepository.ensureLoaded()
        TraktSettingsRepository.ensureLoaded()
        TraktCommentsSettings.ensureLoaded()
        EpisodeReleaseNotificationsRepository.ensureLoaded()
    }

    private fun buildSignature(blob: MobileProfileSettingsBlob): String =
        json.encodeToString(MobileProfileSettingsBlob.serializer(), blob)

    // The four credential-bearing features, stripped — for signature comparison only (the
    // unstripped blob must still be the one applied, or legacy credentials never migrate).
    private fun withoutBlobCredentials(blob: MobileProfileSettingsBlob): MobileProfileSettingsBlob =
        blob.copy(
            features = blob.features.copy(
                playerSettings = withoutProfileCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, blob.features.playerSettings),
                debridSettings = withoutProfileCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, blob.features.debridSettings),
                tmdbSettings = withoutProfileCredentials(PROFILE_TMDB_SETTINGS_FEATURE, blob.features.tmdbSettings),
                mdbListSettings = withoutProfileCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, blob.features.mdbListSettings),
            ),
        )

    private fun blobCarriesCredentials(blob: MobileProfileSettingsBlob): Boolean =
        blobCarriesFeatureCredentials(PROFILE_PLAYER_SETTINGS_FEATURE, blob.features.playerSettings) ||
            blobCarriesFeatureCredentials(PROFILE_DEBRID_SETTINGS_FEATURE, blob.features.debridSettings) ||
            blobCarriesFeatureCredentials(PROFILE_TMDB_SETTINGS_FEATURE, blob.features.tmdbSettings) ||
            blobCarriesFeatureCredentials(PROFILE_MDBLIST_SETTINGS_FEATURE, blob.features.mdbListSettings)

    /// Whether [payload] — one credential-bearing feature's raw JsonObject — still carries its
    /// credential key(s). Used both by [blobCarriesCredentials] (whole-blob) and by
    /// `applyRemoteBlob()`'s per-feature `forceApply` (a stripped-payload comparison can never
    /// detect "this incoming payload still needs its one-time credential migration applied").
    private fun blobCarriesFeatureCredentials(feature: String, payload: JsonObject): Boolean =
        payload != withoutProfileCredentials(feature, payload)

    private fun currentObservedStateSignature(): String = listOf(
        "theme=${ThemeSettingsRepository.selectedTheme.value.name}",
        "amoled=${ThemeSettingsRepository.amoledEnabled.value}",
        "liquid_glass_tab_bar=${ThemeSettingsRepository.liquidGlassNativeTabBarEnabled.value}",
        "nav_bar_style=${ThemeSettingsRepository.navBarStyle.value.key}",
        "poster_card_style=${PosterCardStyleRepository.uiState.value}",
        "card_depth_style=${CardDepthStyleRepository.uiState.value}",
        "player=${PlayerSettingsRepository.uiState.value}",
        "stream_badges=${StreamBadgeSettingsRepository.uiState.value}",
        "debrid=${DebridSettingsRepository.uiState.value}",
        "tmdb=${TmdbSettingsRepository.uiState.value}",
        "mdblist=${MdbListSettingsRepository.uiState.value}",
        "meta=${MetaScreenSettingsRepository.uiState.value}",
        "collection_mobile_settings=${CollectionMobileSettingsRepository.uiState.value}",
        "continue=${ContinueWatchingPreferencesRepository.uiState.value}",
        "trakt_settings=${TraktSettingsRepository.uiState.value}",
        "trakt_comments=${TraktCommentsSettings.enabled.value}",
        "episode_release_alerts=${EpisodeReleaseNotificationsRepository.uiState.value.isEnabled}",
    ).joinToString(separator = "||")

}

/**
 * H-1B-i no-op suppression: applies [incoming] over [current] and fires [notifyChanged] only when
 * they differ. Every `applyRemoteBlob()` block used to replace-and-fan-out unconditionally on
 * every foreground pull whose feature was PRESENT in the remote blob — including a pull whose
 * payload is byte-identical to what's already stored locally. On tvOS the whole SwiftUI view tree
 * is re-identified by `.id(appTheme.themeName)` on that fan-out (`onProfileChanged()` →
 * `objectWillChange`), so an identical pull minutes after launch caused a full, visible remount
 * (2026-08-22 tester report, doubled hero) — this is defense in depth at the source, alongside the
 * Swift-side guard landed separately.
 *
 * [current] and [incoming] MUST be the exact serialized shape a feature's own
 * `exportToSyncPayload()` produces (a raw [kotlinx.serialization.json.JsonObject] for theme, the
 * raw stored payload string for poster/card-depth) — never fields decoded out of that payload. A
 * writing client on a different schema (e.g. one that doesn't model a given key) still serializes
 * to a payload that differs at this raw level, so it correctly reads as "changed" and applies
 * exactly as before; only a truly byte-identical payload is suppressed.
 *
 * [forceApply] bypasses the comparison and always applies + notifies — for the four
 * credential-bearing features, [current]/[incoming] are the CREDENTIAL-STRIPPED payloads (an
 * unstripped compare would never suppress, since the two sides' credentials are usually already
 * equal or already absent from [current], making the comparison meaningless either way); a remote
 * payload that still carries credentials must still apply once (the migration-import path — see
 * `preservingLocalProfileCredentials`) even when the stripped settings themselves are unchanged.
 */
internal inline fun <T> applyFeatureUnlessUnchanged(
    log: Logger,
    featureName: String,
    current: T,
    incoming: T,
    forceApply: Boolean = false,
    apply: () -> Unit,
    notifyChanged: () -> Unit,
) {
    if (!forceApply && current == incoming) {
        log.d { "applyRemoteBlob() — '$featureName' payload unchanged; skipping replace + onProfileChanged() (no-op suppression)" }
        return
    }
    apply()
    notifyChanged()
}

@Serializable
private data class MobileProfileSettingsBlob(
    val version: Int = 3,
    val features: MobileProfileSettingsFeatures = MobileProfileSettingsFeatures(),
)

@Serializable
private data class MobileProfileSettingsFeatures(
    @SerialName("theme_settings") val themeSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("poster_card_style_settings_payload") val posterCardStyleSettingsPayload: String = "",
    @SerialName("card_depth_style_settings_payload") val cardDepthStyleSettingsPayload: String = "",
    @SerialName("player_settings") val playerSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("stream_badge_settings") val streamBadgeSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("debrid_settings") val debridSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("tmdb_settings") val tmdbSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("mdblist_settings") val mdbListSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("meta_screen_settings_payload") val metaScreenSettingsPayload: String = "",
    @SerialName("collection_mobile_settings_payload") val collectionMobileSettingsPayload: String = "",
    @SerialName("continue_watching_settings_payload") val continueWatchingSettingsPayload: String = "",
    @SerialName("trakt_settings_payload") val traktSettingsPayload: String = "",
    @SerialName("trakt_comments_settings") val traktCommentsSettings: JsonObject = JsonObject(emptyMap()),
    @SerialName("notifications_settings") val notificationsSettings: NotificationsSettingsPayload = NotificationsSettingsPayload(),
)

@Serializable
private data class NotificationsSettingsPayload(
    @SerialName("episode_release_alerts_enabled") val episodeReleaseAlertsEnabled: Boolean = false,
)

@Serializable
private data class SettingsBlobResponse(
    @SerialName("profile_id") val profileId: Int = 0,
    @SerialName("settings_json") val settingsJson: JsonObject? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

/// A settings push may only run when the CURRENT (user, profile) identity has a settled pull
/// recorded — non-null current token (authenticated, non-anonymous) matching the settled one.
internal fun settingsPushAllowed(
    settledToken: SettingsPullToken?,
    currentToken: SettingsPullToken?,
): Boolean = currentToken != null && settledToken == currentToken
