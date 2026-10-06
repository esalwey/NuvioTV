package com.nuvio.app.features.tracking

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.sync.CachedSharedSettings
import com.nuvio.app.core.sync.SettingsPullToken
import com.nuvio.app.core.sync.TRACKING_SOURCE_SHARED_SYNC_PLATFORM
import com.nuvio.app.core.sync.currentSettingsPullToken
import com.nuvio.app.core.sync.mergeSharedSettingsJson
import com.nuvio.app.core.sync.putSyncOriginClientId
import com.nuvio.app.features.library.LibrarySourceMode
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.trakt.normalizeTraktContinueWatchingDaysCap
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlin.concurrent.Volatile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
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

private const val PUSH_DEBOUNCE_MS = 1500L

private val trackingSourceJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

@Serializable
data class SyncTrackingSourcePayload(
    @SerialName("watch_progress_source") val watchProgressSource: String? = null,
    @SerialName("library_source_mode") val librarySourceMode: String? = null,
    @SerialName("continue_watching_days_cap") val continueWatchingDaysCap: Int? = null,
)

@Serializable
private data class SupabaseTrackingSourceSettingsBlob(
    @SerialName("profile_id") val profileId: Int = 0,
    @SerialName("settings_json") val settingsJson: JsonObject? = null,
)

internal data class TrackingSourceSelection(
    val watchProgressSource: WatchProgressSource,
    val librarySourceMode: LibrarySourceMode,
    val continueWatchingDaysCap: Int,
)

/**
 * Presence-gated decode: only the keys the writing client actually modelled override [local]. A
 * client on an older schema omits a key entirely, and absence must mean "not modelled" rather than
 * "reset to the default". A key that IS present but malformed resolves through the storage
 * decoders' own fallbacks. Returns null when [settingsJson] is not this payload's shape at all.
 */
internal fun decodeTrackingSourceSelectionPreservingLocal(
    settingsJson: JsonObject,
    local: TrackingSourceSelection,
): TrackingSourceSelection? = runCatching {
    val decoded = trackingSourceJson.decodeFromJsonElement(SyncTrackingSourcePayload.serializer(), settingsJson)
    TrackingSourceSelection(
        watchProgressSource = decoded.watchProgressSource
            ?.let { WatchProgressSource.fromStorage(it) }
            ?: local.watchProgressSource,
        librarySourceMode = decoded.librarySourceMode
            ?.let { librarySourceModeFromStorage(it) }
            ?: local.librarySourceMode,
        continueWatchingDaysCap = decoded.continueWatchingDaysCap
            ?.let { normalizeTraktContinueWatchingDaysCap(it) }
            ?: local.continueWatchingDaysCap,
    )
}.getOrNull()

/**
 * BUG-75: syncs the tracking source preferences under one namespace every platform reads and
 * writes, so switching Trakt→Simkl on the phone reaches the TV.
 *
 * Migration / compatibility:
 * - The platform-scoped profile blob still carries `trakt_settings_payload`, and still applies
 *   first in [com.nuvio.app.core.sync.runOrderedProfileSync]. This service's step runs immediately
 *   after it, so a present shared value always wins over the platform-scoped one.
 * - KNOWN mixed-version limitation, deliberate: once the shared namespace exists, an edit made on
 *   an OLD client (which writes only its platform blob) applies transiently during each full sync
 *   and is then overwritten by the shared value — it does not migrate into the shared namespace.
 *   Auto-promoting it was rejected because the promotion signal ("the platform blob moved the
 *   selection") is indistinguishable from a fresh install reading a stale platform blob, and that
 *   case would revert the whole account's setting; true ordering would need timestamps old clients
 *   will never write. The loss is transient (ends when that platform's clients update), and any
 *   edit on an updated client propagates everywhere.
 * - Two clients seeding an absent shared blob simultaneously is likewise resolved last-writer-wins;
 *   both seeds are the clients' own current selections, so the loser's next local change re-pushes.
 */
object TrackingSourceSettingsSyncService {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("TrackingSourceSettingsSync"))
    private val log = Logger.withTag("TrackingSourceSettingsSyncService")

    @Volatile
    var isSyncingFromRemote: Boolean = false

    private var observeJob: Job? = null

    @Volatile
    private var completedInitialPull: SettingsPullToken? = null

    @Volatile
    private var cachedSharedSettings: CachedSharedSettings? = null

    // Selection snapshot taken by the ordered sync BEFORE the ProfileSettings step applies the
    // platform blob. If the shared-namespace pull then fails, the blob's possibly-stale values
    // are already live — restoring this snapshot returns every downstream consumer (library pull,
    // resumed coordinator transitions) to the last-known-good selection until the retry.
    @Volatile
    private var preSyncSelection: Pair<Int, TrackingSourceSelection>? = null

    fun snapshotSelectionBeforePlatformApply(profileId: Int) {
        TrackingSettingsRepository.ensureLoaded()
        preSyncSelection = profileId to currentSelection()
    }

    fun restoreSelectionAfterFailedPull(profileId: Int) {
        val snapshot = preSyncSelection?.takeIf { it.first == profileId } ?: return
        preSyncSelection = null
        // A user edit made since the snapshot is newer truth than the snapshot — never restore
        // over it (the pull's local-wins path owns pushing it on the retry).
        val hasUnreconciledEdit =
            TraktSettingsRepository.userTrackingEditCount(profileId) != (editCountsReconciled[profileId] ?: 0)
        if (hasUnreconciledEdit) return
        applyRemoteSelection(snapshot.second)
        log.i { "restoreSelectionAfterFailedPull — restored pre-sync tracking selection after failed shared pull" }
    }

    // Per-profile user-edit counts that a completed pull has reconciled with the server (pushed,
    // or confirmed none pending). A profile whose live count differs from its reconciled count has
    // an edit the server has not seen — the pull keeps local and pushes instead of applying remote
    // over it. Counts are session-scoped, start at zero, and are wiped with the account, so the
    // zero default is always a sound baseline. This one comparison covers every window: an edit
    // whose debounced emission has not fired yet, one recorded before the pull began, and one
    // landing mid-RPC.
    @Volatile
    private var editCountsReconciled: Map<Int, Int> = emptyMap()

    // Last push that failed in transit, scoped to the token it was for — profile B's pull must
    // never retry (or be diverted by) profile A's owed push. In-memory only: within the session
    // every later pull and emission under the same token retries it; a process death before that
    // loses only the *push* — the edit itself is persisted locally, so a stale remote can still
    // win after a restart that follows a failed push. Accepted residual — fixing it would mean
    // persisting a dirty flag, i.e. rebuilding the outbox this service replaced.
    @Volatile
    private var failedPush: FailedPush? = null

    private data class FailedPush(
        val token: SettingsPullToken,
        val selection: TrackingSourceSelection,
    )

    suspend fun pullFromServer(profileId: Int) {
        val pullToken = currentSettingsPullToken(profileId) ?: return
        TrackingSettingsRepository.ensureLoaded()
        val localSelection = currentSelection()
        // A fetch failure propagates so runOrderedProfileSync records this step as failed and the
        // full pull is retried, instead of the sync being stamped fresh with the shared selection
        // silently unapplied.
        val remoteJson = fetchRemoteSettingsJson(profileId)
        // The account or active profile can change while the RPC is in flight (tvOS sign-out does
        // not cancel an active SyncManager pull before wiping). Everything below reads or writes
        // ACTIVE-scoped state, so a stale token must abandon the pull here.
        if (currentSettingsPullToken() != pullToken) {
            log.i { "pullFromServer — pull token changed mid-fetch; abandoning" }
            return
        }
        cachedSharedSettings = CachedSharedSettings(
            token = pullToken,
            settingsJson = remoteJson ?: buildJsonObject { },
        )

        if (remoteJson == null) {
            // Seed: nothing under the shared namespace yet, so this client's current selection
            // becomes its first value — otherwise the namespace stays empty until someone
            // changes a setting, and a TV that never changes one never publishes anything.
            log.i { "pullFromServer — no remote tracking source settings found; seeding from local" }
            // Count captured BEFORE the selection is read: an edit landing between the two is
            // then pushed but left dirty (harmlessly re-pushed later) instead of the reverse,
            // where it would be falsely reconciled and lost. Same rule at every push site.
            val seedCount = TraktSettingsRepository.userTrackingEditCount(profileId)
            val seeded = pushToRemote(pullToken, currentSelection())
            markInitialPullComplete(pullToken)
            if (seeded) reconcileEditCount(pullToken.profileId, seedCount)
            if (!seeded) error("seeding the shared tracking source namespace failed")
            return
        }

        // A *user* edit the server has not seen wins over the remote value: the profile's live
        // edit count differing from its reconciled count means an unpushed edit exists (whether
        // its debounced emission has fired or not, and whether it landed before or during this
        // RPC), and a failed push for this token is likewise still owed. Profile-switch reloads
        // deliberately do not count — they move the selection without moving the edit count, so
        // for those the remote value is the newer truth and applies below.
        // The edit record is read ONCE — its count and selection are a consistent pair, so the
        // count we reconcile is exactly the count of the selection we push (an edit landing after
        // this read stays dirty for the next pull).
        val edit = TraktSettingsRepository.lastUserTrackingEdit(profileId)
        val liveCount = edit?.count ?: 0
        val hasUnreconciledEdit = liveCount != (editCountsReconciled[profileId] ?: 0)
        val owedPush = failedPush?.takeIf { it.token == pullToken }
        if (hasUnreconciledEdit || owedPush != null) {
            log.i { "pullFromServer — local tracking source edit raced the initial pull; keeping local and pushing" }
            markInitialPullComplete(pullToken)
            // Push the edit AS THE USER MADE IT, not the live selection: the ProfileSettings step
            // that just ran can have overwritten the live state with an older platform blob, and
            // pushing that would launder the stale value through the shared namespace. Restoring
            // it locally first also undoes that transient platform clobber for the UI.
            val editSelection = edit?.selection?.takeIf { hasUnreconciledEdit }
                ?: owedPush?.selection
                ?: currentSelection()
            applyRemoteSelection(editSelection)
            if (!pushToRemote(pullToken, editSelection)) {
                error("pushing the raced local tracking source edit failed")
            }
            reconcileEditCount(pullToken.profileId, liveCount)
            return
        }

        // Decode AFTER the local-edit check above: a local edit must be able to push (and thereby
        // repair) even a malformed remote blob. With no edit pending, a malformed blob fails the
        // step — marking it successful would leave the stale platform selection active and
        // suppress the retry that a recorded failure earns.
        val remoteSelection = decodeTrackingSourceSelectionPreservingLocal(remoteJson, localSelection)
            ?: error("failed to parse remote tracking source settings")

        applyRemoteSelection(remoteSelection)
        log.i { "pullFromServer — applied remote tracking source settings" }
        markInitialPullComplete(pullToken)
        // An edit can land between the liveCount read above and the apply — the apply would have
        // overwritten it, and its debounced emission may be superseded by the apply's own. Re-check
        // and restore-and-push the edit if so; otherwise reconcile the checked count (never the
        // live one, so an edit landing after this check stays dirty for the next pull).
        val postApplyEdit = TraktSettingsRepository.lastUserTrackingEdit(profileId)
        if ((postApplyEdit?.count ?: 0) != liveCount) {
            log.i { "pullFromServer — local tracking source edit raced the remote apply; restoring and pushing" }
            val editSelection = postApplyEdit?.selection ?: currentSelection()
            applyRemoteSelection(editSelection)
            if (!pushToRemote(pullToken, editSelection)) {
                error("pushing the tracking source edit that raced the remote apply failed")
            }
            reconcileEditCount(pullToken.profileId, postApplyEdit?.count ?: 0)
            return
        }
        reconcileEditCount(pullToken.profileId, liveCount)
    }

    @OptIn(FlowPreview::class)
    fun startObserving() {
        if (observeJob?.isActive == true) return
        TrackingSettingsRepository.ensureLoaded()
        observeJob = scope.launch {
            TraktSettingsRepository.uiState
                .map { state ->
                    TrackingSourceSelection(
                        watchProgressSource = state.watchProgressSource,
                        librarySourceMode = state.librarySourceMode,
                        continueWatchingDaysCap = state.continueWatchingDaysCap,
                    )
                }
                .distinctUntilChanged()
                .drop(1)
                .debounce(PUSH_DEBOUNCE_MS)
                .collect { selection ->
                    val token = currentSettingsPullToken() ?: return@collect
                    // Pushing before the pull lands would publish this device's stale selection
                    // over the account's newer one. Skipping is safe for edits too: any user edit
                    // is counted synchronously at its setter, and the pull keeps-and-pushes local
                    // whenever the count is ahead of what it last reconciled.
                    if (!hasCompletedInitialPull(token)) {
                        log.d { "push — skipped before initial tracking source pull completed" }
                        return@collect
                    }
                    if (isSyncingFromRemote) return@collect
                    // Provenance gate: only an unreconciled user edit or an owed failed push may
                    // publish. Every other emission — a remote apply's echo, or the ProfileSettings
                    // step transiently applying a stale platform blob while a shared pull is still
                    // in flight — carries nothing user-made and must never reach the namespace.
                    val owed = failedPush?.takeIf { it.token == token }
                    // The edit record is read ONCE for a consistent count+selection pair: the
                    // count reconciled below is exactly the count of the selection pushed, so an
                    // edit landing after this read stays dirty and re-emits its own push.
                    val edit = TraktSettingsRepository.lastUserTrackingEdit(token.profileId)
                    val hasUnreconciledEdit = (edit?.count ?: 0) != (editCountsReconciled[token.profileId] ?: 0)
                    if (owed == null && !hasUnreconciledEdit) return@collect
                    // The payload is the edit AS THE USER MADE IT (or the owed push), never the
                    // raw emission — a stale platform reload can be the latest emission while the
                    // user's edit is what is actually owed. Restore it locally too, in case that
                    // reload clobbered the visible state.
                    val payload = edit?.selection?.takeIf { hasUnreconciledEdit }
                        ?: owed?.selection
                        ?: selection
                    val pushCount = edit?.count ?: 0
                    if (payload != selection) applyRemoteSelection(payload)
                    if (payload == cachedRemoteSelection(token)) {
                        // Already what the server holds — reconcile without a redundant push.
                        reconcileEditCount(token.profileId, pushCount)
                        if (failedPush?.token == token) failedPush = null
                        return@collect
                    }
                    if (pushToRemote(token, payload)) {
                        reconcileEditCount(token.profileId, pushCount)
                    }
                }
        }
    }

    fun clearAccountState() {
        observeJob?.cancel()
        observeJob = null
        completedInitialPull = null
        cachedSharedSettings = null
        failedPush = null
        editCountsReconciled = emptyMap()
        preSyncSelection = null
    }

    private suspend fun pushToRemote(token: SettingsPullToken, selection: TrackingSourceSelection): Boolean =
        runCatching {
            val jsonElement = mergedSharedPayloadJson(token, selection)

            val params = buildJsonObject {
                put("p_profile_id", token.profileId)
                put("p_platform", TRACKING_SOURCE_SHARED_SYNC_PLATFORM)
                put("p_settings_json", jsonElement)
                putSyncOriginClientId()
            }
            SupabaseProvider.client.postgrest.rpc("sync_push_profile_settings_blob", params)
            cachedSharedSettings = CachedSharedSettings(token = token, settingsJson = jsonElement)
            if (failedPush?.token == token) failedPush = null
            log.d { "pushToRemote — success" }
        }.fold(
            onSuccess = { true },
            onFailure = { e ->
                if (e is kotlinx.coroutines.CancellationException) throw e
                // Keep the selection owed: the next pull retries it (local-wins branch), and any
                // later emission bypasses the echo skip while this is set.
                failedPush = FailedPush(token, selection)
                log.e(e) { "pushToRemote — FAILED" }
                false
            },
        )

    private fun hasCompletedInitialPull(token: SettingsPullToken): Boolean =
        completedInitialPull == token

    private fun markInitialPullComplete(token: SettingsPullToken) {
        completedInitialPull = token
    }

    // Only ever advances, and only to a count captured BEFORE the push it reconciles — an edit
    // that lands during a push stays dirty rather than being silently absorbed.
    private fun reconcileEditCount(profileId: Int, count: Int) {
        val current = editCountsReconciled[profileId] ?: 0
        if (count > current) {
            editCountsReconciled = editCountsReconciled + (profileId to count)
        }
    }

    private fun currentSelection(): TrackingSourceSelection {
        val state = TrackingSettingsRepository.uiState.value
        return TrackingSourceSelection(
            watchProgressSource = state.watchProgressSource,
            librarySourceMode = state.librarySourceMode,
            continueWatchingDaysCap = state.continueWatchingDaysCap,
        )
    }

    private fun applyRemoteSelection(selection: TrackingSourceSelection) {
        isSyncingFromRemote = true
        try {
            TraktSettingsRepository.applyFromRemoteSync(
                watchProgressSource = selection.watchProgressSource,
                librarySourceMode = selection.librarySourceMode,
                continueWatchingDaysCap = selection.continueWatchingDaysCap,
            )
        } finally {
            isSyncingFromRemote = false
        }
    }

    private suspend fun fetchRemoteSettingsJson(profileId: Int): JsonObject? {
        val params = buildJsonObject {
            put("p_profile_id", profileId)
            put("p_platform", TRACKING_SOURCE_SHARED_SYNC_PLATFORM)
        }
        val result = SupabaseProvider.client.postgrest.rpc("sync_pull_profile_settings_blob", params)
        return result.decodeList<SupabaseTrackingSourceSettingsBlob>().firstOrNull()?.settingsJson
    }

    private fun cachedRemoteSelection(token: SettingsPullToken): TrackingSourceSelection? {
        val cached = cachedSharedSettings?.takeIf { it.token == token }?.settingsJson ?: return null
        val decoded = runCatching {
            trackingSourceJson.decodeFromJsonElement(SyncTrackingSourcePayload.serializer(), cached)
        }.getOrNull() ?: return null
        val watchProgressSource = decoded.watchProgressSource ?: return null
        val librarySourceMode = decoded.librarySourceMode ?: return null
        val continueWatchingDaysCap = decoded.continueWatchingDaysCap ?: return null
        return TrackingSourceSelection(
            watchProgressSource = WatchProgressSource.fromStorage(watchProgressSource),
            librarySourceMode = librarySourceModeFromStorage(librarySourceMode),
            continueWatchingDaysCap = normalizeTraktContinueWatchingDaysCap(continueWatchingDaysCap),
        )
    }

    private fun mergedSharedPayloadJson(
        token: SettingsPullToken,
        selection: TrackingSourceSelection,
    ): JsonObject {
        val localJson = trackingSourceJson.encodeToJsonElement(
            SyncTrackingSourcePayload.serializer(),
            SyncTrackingSourcePayload(
                watchProgressSource = selection.watchProgressSource.name,
                librarySourceMode = selection.librarySourceMode.name,
                continueWatchingDaysCap = selection.continueWatchingDaysCap,
            ),
        ).jsonObject
        val remoteJson = cachedSharedSettings
            ?.takeIf { cached -> cached.token == token }
            ?.settingsJson
        return mergeSharedSettingsJson(remoteJson = remoteJson, localJson = localJson)
    }
}
