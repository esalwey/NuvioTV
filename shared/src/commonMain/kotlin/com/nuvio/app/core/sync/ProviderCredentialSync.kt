package com.nuvio.app.core.sync

import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.features.debrid.DebridProviders
import com.nuvio.app.features.debrid.DebridSettings
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.mdblist.MdbListSettings
import com.nuvio.app.features.mdblist.MdbListSettingsRepository
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.player.PlayerSettingsUiState
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tmdb.TmdbSettings
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlin.concurrent.Volatile
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private const val PROVIDER_CREDENTIAL_PUSH_DEBOUNCE_MS = 500L

private data class ProviderCredentialScope(
    val userId: String,
    val profileId: Int,
)

/**
 * Cross-client sync for provider API-key credentials (TMDB, MDBList, every debrid provider,
 * AnimeSkip client id, IntroDB API key).
 *
 * These used to ride the general [ProfileSettingsSync] blob, which does a whole-blob
 * signature diff: a device with an empty key set could blank a good key set on another device.
 * This object owns them instead, keyed per provider, so a remote row only ever replaces the one
 * credential it carries. [ProfileSettingsCredentialPolicy] keeps the same keys out of the
 * settings blob on both the push and the apply side.
 *
 * Since upstream 1854dfc3 the pull is authoritative: a provider with no remote row is cleared
 * locally (except the device-local BACKEND_UNSUPPORTED_PROVIDERS), a sync never pushes before it
 * pulls unless an earlier push failed or a local edit is still in the observer's debounce window,
 * and only legacy-blob credentials are seeded. A failed push is retried in-session only (the next
 * sync); it is not persisted across launches.
 *
 * Persists nothing of its own — the snapshot maps below are in-memory bookkeeping, and the
 * credentials themselves live in the existing per-feature storages (already covered by
 * `core.account.AccountDataStores`).
 */
object ProviderCredentialSync {
    // Fork: uncaughtCoroutineLogger — an exception escaping this scope on Kotlin/Native reaches
    // the unhandled-exception hook and aborts the process.
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("ProviderCredentialSync"),
    )
    private val log = Logger.withTag("ProviderCredentialSync")
    private val syncMutex = Mutex()
    private val stateLock = SynchronizedObject()
    private val observedSnapshots = mutableMapOf<Int, ProviderCredentialSnapshot>()
    private val baselineSnapshots = mutableMapOf<ProviderCredentialScope, ProviderCredentialSnapshot>()
    private val pendingScopes = mutableSetOf<ProviderCredentialScope>()

    /**
     * Legacy-blob migration stash (Codex rounds 4+7): credential values found in a pre-split
     * remote settings blob, keyed profileId → storage key. Staged by ProfileSettingsSync during
     * blob apply and consumed by [syncFromRemote], which applies a staged value ONLY where the
     * provider has no remote row and the local slot is blank — so provider rows (including
     * clear-tombstones) always beat the blob, and a staged value can never masquerade as a
     * local edit that pushes over another device's state.
     */
    private val legacyBlobCredentials = mutableMapOf<Int, Map<String, String>>()
    private var observeJob: Job? = null

    /**
     * Storage key (as it appears in a legacy settings blob) → snapshot provider id. The debrid
     * spellings are NOT mechanical ("debrid_real_debrid_api_key" ↔ "realdebrid"), so this map is
     * explicit and mirrors `ProfileSettingsCredentialPolicy.profileCredentialKeys`.
     */
    /**
     * Providers the Nuvio backend refuses in `sync_push_provider_credentials` /
     * `sync_seed_provider_credentials` payloads. The RPC validates the WHOLE snapshot and rejects
     * the entire call over one unknown provider (Postgres 22023 "Unsupported provider credential:
     * debrid:alldebrid", observed live 2026-08-08 on the beta.11 device pass — every push from a
     * device holding an AllDebrid key failed, so nothing synced at all). AllDebrid is a fork-only
     * provider (FEAT-6); until the backend learns it, its credential stays device-local. Filtered
     * at the serialization boundary only: local snapshots still carry it, so change detection and
     * `applySnapshot` are untouched (a remote snapshot can never contain it, and apply only writes
     * providers present in the payload, so the local key is never blanked).
     */
    private val BACKEND_UNSUPPORTED_PROVIDERS = setOf(
        ProviderCredentialIds.debrid(DebridProviders.ALLDEBRID_ID),
    )

    private val legacyStorageKeyToProvider = mapOf(
        "tmdb_api_key" to ProviderCredentialIds.TMDB,
        "mdblist_api_key" to ProviderCredentialIds.MDBLIST,
        "animeskip_client_id" to ProviderCredentialIds.ANIMESKIP,
        "introdb_api_key" to ProviderCredentialIds.INTRODB,
        "debrid_torbox_api_key" to ProviderCredentialIds.debrid(DebridProviders.TORBOX_ID),
        "debrid_premiumize_api_key" to ProviderCredentialIds.debrid(DebridProviders.PREMIUMIZE_ID),
        "debrid_real_debrid_api_key" to ProviderCredentialIds.debrid(DebridProviders.REAL_DEBRID_ID),
        "debrid_alldebrid_api_key" to ProviderCredentialIds.debrid(DebridProviders.ALLDEBRID_ID),
    )

    fun stageLegacyBlobCredentials(profileId: Int, values: Map<String, String>) {
        val nonBlank = values.filterValues(String::isNotBlank)
        if (nonBlank.isEmpty()) return
        synchronized(stateLock) {
            legacyBlobCredentials[profileId] = legacyBlobCredentials[profileId].orEmpty() + nonBlank
        }
        log.d { "Staged ${nonBlank.size} legacy blob credential(s) for profile $profileId" }
    }

    // Fork: @Volatile — read from the observer coroutine while the sync coroutine writes it.
    @Volatile
    private var isApplyingRemote = false

    @OptIn(FlowPreview::class)
    fun startObserving() {
        if (observeJob?.isActive == true) return
        ensureRepositoriesLoaded()
        observeJob = scope.launch {
            observeCredentialSnapshots()
                .distinctUntilChanged()
                .debounce(PROVIDER_CREDENTIAL_PUSH_DEBOUNCE_MS)
                .collect(::handleLocalSnapshot)
        }
    }

    fun clearAccountState() {
        observeJob?.cancel()
        observeJob = null
        synchronized(stateLock) {
            observedSnapshots.clear()
            baselineSnapshots.clear()
            pendingScopes.clear()
            legacyBlobCredentials.clear()
        }
    }

    /**
     * Upstream 1854dfc3 (profile-switch race): re-baselines the newly active profile the moment
     * the profile fan-out has reloaded the credential repositories. Without it the switch itself
     * read as a local edit: the debounced observer could push a half-reloaded snapshot (one
     * repository already on the new profile, another still on the old one) over the new profile's
     * rows. Called from [ProfileSettingsSync.onProfileChanged], the last step of the fan-out.
     */
    internal fun onProfileChanged() {
        if (observeJob?.isActive != true) return
        ensureRepositoriesLoaded()
        val profileId = ProfileRepository.activeProfileId
        // currentSnapshot() check()s the active profile around its reads; a switch racing this
        // call must not throw into the caller's (Swift main-thread) fan-out.
        val snapshot = runCatching { currentSnapshot(profileId) }.getOrNull() ?: return
        val credentialScope = currentScope(profileId)
        synchronized(stateLock) {
            observedSnapshots[profileId] = snapshot
            if (credentialScope != null) {
                baselineSnapshots[credentialScope] = snapshot
            }
        }
    }

    suspend fun syncFromRemote(profileId: Int): Boolean = syncMutex.withLock {
        ensureRepositoriesLoaded()
        val credentialScope = currentScope(profileId) ?: return@withLock false
        try {
            val localSnapshot = currentSnapshot(profileId)
            // Upstream 1854dfc3 ("prevent automatic pulls from restoring deleted data"): an
            // automatic sync no longer pushes the local snapshot before pulling whenever it merely
            // differs from the baseline. The push serializes EVERY provider, so a device that had
            // drifted (a profile switch's reload was enough, see onProfileChanged) rewrote all rows
            // with its stale values and resurrected keys removed on another device. Local edits
            // reach the server through the observer's push (handleLocalSnapshot) instead.
            // Fork-only, kept: a push that FAILED (pendingScopes) is retried here before the pull,
            // or the authoritative pull below would erase the user's unsent edit. The same goes for
            // an edit the observer has not handled yet (saved less than
            // PROVIDER_CREDENTIAL_PUSH_DEBOUNCE_MS ago): the pull would overwrite it, and its
            // debounced emission would then be dropped as stale by handleLocalSnapshot — a key the
            // user had just saved would silently go back to the old one.
            val shouldPush = synchronized(stateLock) {
                credentialScope in pendingScopes || hasUnhandledLocalEdit(profileId, credentialScope, localSnapshot)
            }
            if (shouldPush) {
                pushSnapshot(localSnapshot)
                synchronized(stateLock) {
                    observedSnapshots[profileId] = localSnapshot
                    baselineSnapshots[credentialScope] = localSnapshot
                    pendingScopes.remove(credentialScope)
                }
            }

            // Perf (upstream 67b865a7, "seed only missing provider credentials"): pull FIRST, so
            // the seed below can be skipped entirely when nothing is missing remotely — the
            // seed RPC is insert-if-absent, so calling it when every seedable provider already
            // has a remote row is a wasted round-trip.
            val rows = pullRows(profileId)

            // Legacy-blob migration (see [legacyBlobCredentials]) — since upstream 1854dfc3 the
            // ONLY thing that is seeded. Seeding the plain local snapshot recreated a row for every
            // local key that had none, i.e. brought back keys removed on another device, and the
            // pull is authoritative now (mergeRemote clears a provider without a row). The staged
            // providers ride the SEED, whose RPC is insert-if-absent: a provider that already has a
            // row — including a blank clear-tombstone — is untouched, while one without a row gets
            // created carrying the migrated value (this device's key when it has one, else the
            // legacy value), applied locally this round through `voidFill` below. Never merged into
            // localSnapshot itself, so a staged value can't masquerade as a local edit (Codex
            // rounds 7–9). Stash keys are STORAGE keys ("debrid_torbox_api_key"), snapshot
            // providers are ids ("debrid:torbox") — translated via [legacyStorageKeyToProvider].
            // PEEK, don't consume: the stash may be these credentials' only surviving copy (the
            // legacy blob rewrite waits on us), so it must outlive a failed/cancelled seed —
            // consumed only in the success bookkeeping below (Codex round 10).
            val staged = synchronized(stateLock) { legacyBlobCredentials[profileId] }.orEmpty()
            val stagedByProvider = staged.entries.mapNotNull { (storageKey, value) ->
                legacyStorageKeyToProvider[storageKey]?.let { it to value }
            }.toMap()
            // Seed only NON-BLANK values: seeding blank rows would mint authoritative tombstones
            // out of nothing (Codex round 14). Blanks still travel on the explicit PUSH path, so an
            // intentional clear remains a tombstone.
            val seedPayload = localSnapshot.copy(
                values = localSnapshot.values.mapNotNull { slot ->
                    // Backend-refused providers can't be seeded; `unsupportedStaged` applies them.
                    if (slot.provider in BACKEND_UNSUPPORTED_PROVIDERS) return@mapNotNull null
                    val legacy = stagedByProvider[slot.provider] ?: return@mapNotNull null
                    val value = slot.value.ifBlank { legacy }
                    if (value.isBlank()) null else slot.copy(value = value)
                },
            )
            // shouldSeedProviderCredentials gates on the payload that would actually be sent
            // (post legacy-fill, post blank-filter), not the raw local snapshot — a provider
            // already present remotely never needs re-seeding even if other local slots are blank.
            // Because the pull now precedes the seed, values the seed just created are NOT in
            // `rows` — capture them so the merge below can apply them locally this round (the
            // success bookkeeping consumes the stash, so waiting for the next pull would leave a
            // freshly migrated credential inert for a whole sync round). Only providers with NO
            // remote row qualify: a provider that has a row — including a blank tombstone — was
            // untouched by the insert-if-absent seed, and the tombstone must keep winning.
            val remoteProviders = rows.mapTo(mutableSetOf()) { it.provider.lowercase() }
            var seededByProvider = emptyMap<String, String>()
            if (seedPayload.values.isNotEmpty() && shouldSeedProviderCredentials(seedPayload, rows)) {
                if (stagedByProvider.isNotEmpty()) {
                    log.i { "Seeding ${stagedByProvider.size} legacy blob credential(s) for profile $profileId (insert-if-absent)" }
                }
                seedSnapshot(seedPayload)
                seededByProvider = seedPayload.values
                    .filter { it.provider.lowercase() !in remoteProviders }
                    .associate { it.provider to it.value }
            }
            requireCurrentScope(credentialScope)
            val remoteSnapshot = localSnapshot.mergeRemote(
                rows = rows,
                deviceLocalProviders = BACKEND_UNSUPPORTED_PROVIDERS,
            )
            // Staged credentials for BACKEND_UNSUPPORTED_PROVIDERS never ride the seed (filtered
            // from every outbound payload), so no provider row exists for the pull to return —
            // yet the success bookkeeping below consumes the stash and sanitizes the legacy blob,
            // which held the only copy. Apply them LOCALLY instead, folded into the snapshot
            // `applySnapshot` writes (so the write happens under `isApplyingRemote` and the
            // baselines below include the value — no spurious follow-up push). Void-fill only,
            // mirroring the seed's insert-if-absent semantics: a real local credential wins over
            // a staged legacy one (Codex review, 2026-08-08 device-pass session).
            val unsupportedStaged = stagedByProvider.filterKeys { it in BACKEND_UNSUPPORTED_PROVIDERS }
            // Both maps void-fill only: just-seeded values (rows pulled pre-seed can't contain
            // them) and unsupported-provider staged values (no row will ever exist). Unsupported
            // wins on overlap — its value never rode the seed, so the stash is its only copy.
            val voidFill = seededByProvider + unsupportedStaged
            val mergedSnapshot = if (voidFill.isEmpty()) remoteSnapshot else remoteSnapshot.copy(
                values = remoteSnapshot.values.map { slot ->
                    val fill = voidFill[slot.provider]
                    if (!fill.isNullOrBlank() && slot.value.isBlank()) slot.copy(value = fill) else slot
                },
            )
            val applied = mergedSnapshot != localSnapshot
            if (applied) {
                isApplyingRemote = true
                try {
                    applySnapshot(mergedSnapshot, credentialScope)
                } finally {
                    isApplyingRemote = false
                }
            }
            requireCurrentScope(credentialScope)
            synchronized(stateLock) {
                observedSnapshots[profileId] = mergedSnapshot
                baselineSnapshots[credentialScope] = mergedSnapshot
                pendingScopes.remove(credentialScope)
                // Migration round-trip succeeded (seed-if-missing + pull, unsupported providers
                // applied locally above) — every staged value now lives in a provider row
                // (whether just seeded or already present remotely) or the local store, so the
                // stash can go and the legacy blob may be sanitized.
                legacyBlobCredentials.remove(profileId)
            }
            if (staged.isNotEmpty()) {
                ProfileSettingsSync.rewriteLegacyBlobSanitized(profileId)
            }
            log.d { "Synchronized ${mergedSnapshot.values.size} credentials for profile $profileId applied=$applied" }
            applied
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            AuthRepository.signOutIfSessionInvalid(error, "Provider credential sync")
            log.e(error) { "Provider credential sync failed for profile $profileId" }
            throw error
        }
    }

    private suspend fun seedSnapshot(snapshot: ProviderCredentialSnapshot) {
        SupabaseProvider.client.postgrest.rpc(
            function = "sync_seed_provider_credentials",
            parameters = credentialParams(snapshot),
        )
    }

    private suspend fun pushSnapshot(snapshot: ProviderCredentialSnapshot) {
        SupabaseProvider.client.postgrest.rpc(
            function = "sync_push_provider_credentials",
            parameters = credentialParams(snapshot),
        )
        log.d { "Pushed ${snapshot.values.size} credentials for profile ${snapshot.profileId}" }
    }

    private suspend fun pullRows(profileId: Int): List<SupabaseProviderCredential> {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
        }
        return SupabaseProvider.client.postgrest
            .rpc("sync_pull_provider_credentials", params)
            .decodeList()
    }

    private fun credentialParams(snapshot: ProviderCredentialSnapshot) = buildJsonObject {
        put("p_profile_id", snapshot.profileId)
        put("p_credentials", buildJsonArray {
            snapshot.values.forEach { credential ->
                if (credential.provider in BACKEND_UNSUPPORTED_PROVIDERS) return@forEach
                add(buildJsonObject {
                    put("provider", credential.provider)
                    put("credential_json", credential.credentialJson())
                })
            }
        })
        putSyncOriginClientId()
    }

    private fun observeCredentialSnapshots() = combine(
        ProfileRepository.state,
        DebridSettingsRepository.uiState,
        TmdbSettingsRepository.uiState,
        MdbListSettingsRepository.uiState,
        PlayerSettingsRepository.uiState,
    ) { _, debrid, tmdb, mdbList, player ->
        buildSnapshot(
            profileId = ProfileRepository.activeProfileId,
            debrid = debrid,
            tmdb = tmdb,
            mdbList = mdbList,
            player = player,
        )
    }

    private fun currentSnapshot(profileId: Int): ProviderCredentialSnapshot {
        check(ProfileRepository.activeProfileId == profileId)
        val snapshot = buildSnapshot(
            profileId = profileId,
            debrid = DebridSettingsRepository.snapshot(),
            tmdb = TmdbSettingsRepository.snapshot(),
            mdbList = MdbListSettingsRepository.snapshot(),
            player = PlayerSettingsRepository.uiState.value,
        )
        check(ProfileRepository.activeProfileId == profileId)
        return snapshot
    }

    private fun buildSnapshot(
        profileId: Int,
        debrid: DebridSettings,
        tmdb: TmdbSettings,
        mdbList: MdbListSettings,
        player: PlayerSettingsUiState,
    ): ProviderCredentialSnapshot = ProviderCredentialSnapshot(
        profileId = profileId,
        values = buildList {
            DebridProviders.all().forEach { provider ->
                add(
                    ProviderCredentialValue(
                        provider = ProviderCredentialIds.debrid(provider.id),
                        field = PROVIDER_API_KEY_FIELD,
                        value = debrid.apiKeyFor(provider.id).trim(),
                    ),
                )
            }
            add(ProviderCredentialValue(ProviderCredentialIds.TMDB, PROVIDER_API_KEY_FIELD, tmdb.apiKey.trim()))
            add(ProviderCredentialValue(ProviderCredentialIds.MDBLIST, PROVIDER_API_KEY_FIELD, mdbList.apiKey.trim()))
            add(
                ProviderCredentialValue(
                    ProviderCredentialIds.ANIMESKIP,
                    PROVIDER_CLIENT_ID_FIELD,
                    player.animeSkipClientId.trim(),
                ),
            )
            add(
                ProviderCredentialValue(
                    ProviderCredentialIds.INTRODB,
                    PROVIDER_API_KEY_FIELD,
                    player.introDbApiKey.trim(),
                ),
            )
        },
    )

    private suspend fun applySnapshot(
        snapshot: ProviderCredentialSnapshot,
        expectedScope: ProviderCredentialScope,
    ) {
        snapshot.values.forEach { credential ->
            requireCurrentScope(expectedScope)
            when {
                credential.provider.startsWith("debrid:") -> {
                    DebridSettingsRepository.setProviderApiKey(
                        credential.provider.substringAfter("debrid:"),
                        credential.value,
                    )
                }
                credential.provider == ProviderCredentialIds.TMDB -> {
                    TmdbSettingsRepository.setApiKey(credential.value)
                }
                credential.provider == ProviderCredentialIds.MDBLIST -> {
                    MdbListSettingsRepository.setApiKey(credential.value)
                }
                credential.provider == ProviderCredentialIds.ANIMESKIP -> {
                    PlayerSettingsRepository.setAnimeSkipClientId(credential.value)
                }
                credential.provider == ProviderCredentialIds.INTRODB -> {
                    PlayerSettingsRepository.setIntroDbApiKey(credential.value)
                }
            }
        }
    }

    private suspend fun handleLocalSnapshot(snapshot: ProviderCredentialSnapshot) {
        if (isApplyingRemote) return
        syncMutex.withLock {
            // Upstream 1854dfc3: a debounced emission can describe a state that is already gone
            // (another profile, or a transitional mix mid profile fan-out), so only a snapshot that
            // still matches the live repositories may be pushed. runCatching: currentSnapshot()
            // check()s the active profile, and a throw here would end the observer for good.
            if (ProfileRepository.activeProfileId != snapshot.profileId) return@withLock
            val live = runCatching { currentSnapshot(snapshot.profileId) }.getOrNull() ?: return@withLock
            if (snapshot != live) return@withLock
            val previous = synchronized(stateLock) {
                observedSnapshots.put(snapshot.profileId, snapshot)
            }
            val credentialScope = currentScope(snapshot.profileId) ?: return@withLock
            if (previous == null) {
                synchronized(stateLock) {
                    if (credentialScope !in baselineSnapshots) {
                        baselineSnapshots[credentialScope] = snapshot
                    }
                }
                return@withLock
            }
            // Compare only what a push can carry: BACKEND_UNSUPPORTED_PROVIDERS are device-local
            // by construction, so an edit touching ONLY them must not trigger a push — under
            // upstream's push-before-pull, a stale device pushing its whole (unchanged-remote)
            // snapshot over newer remote keys is exactly the overwrite race, widened to fire off
            // a credential that never even syncs (Codex round 2, 2026-08-08 device-pass session).
            if (previous.syncableSubset() == snapshot.syncableSubset()) return@withLock
            val baseline = synchronized(stateLock) {
                baselineSnapshots.getOrPut(credentialScope) { previous }
            }
            if (baseline.syncableSubset() == snapshot.syncableSubset()) return@withLock

            try {
                pushSnapshot(snapshot)
                synchronized(stateLock) {
                    baselineSnapshots[credentialScope] = snapshot
                    pendingScopes.remove(credentialScope)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                synchronized(stateLock) {
                    pendingScopes.add(credentialScope)
                }
                AuthRepository.signOutIfSessionInvalid(error, "Provider credential push")
                log.e(error) { "Failed to push provider credentials for profile ${snapshot.profileId}" }
            }
        }
    }

    /**
     * Whether [live] holds a local edit the observer has not handled yet (it is still in the
     * debounce window). The observer records every snapshot it handles, and remote applies and
     * profile switches ([onProfileChanged]) re-baseline it, so a syncable difference from the last
     * observed snapshot that is ALSO a difference from the last pushed baseline is a real, unsent
     * edit — not the drift upstream 1854dfc3 stopped pushing. Before the observer's first emission
     * there is nothing to compare with, and nothing to flush. Caller holds [stateLock].
     */
    private fun hasUnhandledLocalEdit(
        profileId: Int,
        credentialScope: ProviderCredentialScope,
        live: ProviderCredentialSnapshot,
    ): Boolean {
        if (observeJob?.isActive != true) return false
        val observed = observedSnapshots[profileId] ?: return false
        val liveSyncable = live.syncableSubset()
        if (observed.syncableSubset() == liveSyncable) return false
        val baseline = baselineSnapshots[credentialScope] ?: observed
        return baseline.syncableSubset() != liveSyncable
    }

    /**
     * The snapshot minus [BACKEND_UNSUPPORTED_PROVIDERS] — i.e. exactly what a push/seed payload
     * can carry after [credentialParams] filtering. Dirty/baseline comparisons use this so a
     * device-local-only edit never fires a network push; the STORED snapshots keep the full value
     * list (the local-only credential still participates in apply/merge bookkeeping).
     */
    private fun ProviderCredentialSnapshot.syncableSubset(): ProviderCredentialSnapshot =
        copy(values = values.filter { it.provider !in BACKEND_UNSUPPORTED_PROVIDERS })

    private fun currentScope(profileId: Int): ProviderCredentialScope? {
        val state = AuthRepository.state.value as? AuthState.Authenticated ?: return null
        if (state.isAnonymous || ProfileRepository.activeProfileId != profileId) return null
        return ProviderCredentialScope(state.userId, profileId)
    }

    private fun requireCurrentScope(expected: ProviderCredentialScope) {
        if (currentScope(expected.profileId) != expected) {
            throw CancellationException("Provider credential sync target changed")
        }
    }

    private fun ensureRepositoriesLoaded() {
        DebridSettingsRepository.ensureLoaded()
        TmdbSettingsRepository.ensureLoaded()
        MdbListSettingsRepository.ensureLoaded()
        PlayerSettingsRepository.ensureLoaded()
    }
}
