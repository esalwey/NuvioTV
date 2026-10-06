package com.nuvio.app.features.addons

import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.sync.putSyncOriginClientId
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put

@Serializable
private data class AddonRow(
    val url: String,
    val name: String? = null,
    val enabled: Boolean = true,
    @SerialName("sort_order") val sortOrder: Int = 0,
)

@Serializable
private data class AddonPushItem(
    val url: String,
    val name: String = "",
    val enabled: Boolean = true,
    @SerialName("sort_order") val sortOrder: Int = 0,
)

private const val ADDON_PUSH_DEBOUNCE_MS = 500L

object AddonRepository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("AddonRepository"))
    private val log = Logger.withTag("AddonRepository")
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val _uiState = MutableStateFlow(AddonsUiState())
    val uiState: StateFlow<AddonsUiState> = _uiState.asStateFlow()

    private val bootstrap = AddonBootstrapState()
    // Fork: hydration flag for the push guard below (shouldBlockUnhydratedAddonPush). Upstream
    // 1854dfc3 dropped its `pulledFromServer` together with the empty-server migration branch it
    // gated; here it only ever answered "has this profile's list been pulled yet", so it stays.
    private var pulledFromServer = false
    // Fork (ADD-1 follow-up to upstream 1854dfc3): whether this profile's add-on list is already
    // KNOWN to this device — it has been non-empty AND in step with the account here: a pull
    // applied a non-empty server list, or a push of a non-empty list succeeded. Persisted per
    // profile (AddonStorage.saveAddonListKnown, wiped at sign-out). Null until the session's first
    // bootstrap step reads it back (initialize() or a pull that wins that race). A signed-in
    // account whose list is known is never re-seeded with the default add-on: an empty server list
    // there means the user removed every add-on (here or on another device), and the seed's push
    // would bring one back over that deletion. A list that only ever existed locally — a seed that
    // never reached the server (offline, failed push), or an empty first pull — does NOT count, so
    // a fresh account whose seed did not land is seeded again next launch. See seedingAllowed().
    private var addonListKnown: Boolean? = null
    private var currentProfileId: Int = 1
    private val activeRefreshJobs = mutableMapOf<String, Job>()
    private val pushJobsByProfile = mutableMapOf<Int, Job>()

    // Observable mirror of the bootstrap guard so consumers that can outrun bootstrap (the player's
    // subtitle fetch) can wait for the local addon list instead of snapshotting an empty state.
    // Both live in [AddonBootstrapState] so no completion path can set one without the other.
    val initializedState: StateFlow<Boolean> = bootstrap.initializedState

    // Flips true when a server pull has SETTLED (applied, found-nothing, or failed with a real
    // error — not cancelled). The default-addon seed and the push guard below both key off the
    // distinction between "the server said" and "we never asked": seeding or full-replace-pushing
    // before the first settle is what wiped a tester's account addons (see
    // docs/addon-wipe-investigation-2026-08-28.md).
    private val _serverPullSettled = MutableStateFlow(false)
    val serverPullSettled: StateFlow<Boolean> = _serverPullSettled.asStateFlow()

    fun initialize() {
        val effectiveProfileId = resolveEffectiveProfileId(AddonProfileProvider.context.activeProfileId)
        if (bootstrap.initialized) return
        bootstrap.begin()
        currentProfileId = effectiveProfileId
        rememberStoredAddonList()
        log.d { "initialize() — loading local addons for profile $currentProfileId" }

        val storedUrls = dedupeManifestUrls(AddonStorage.loadInstalledAddonUrls(currentProfileId))
        val enabledByUrl = loadLocalEnabledStates()
        log.d { "initialize() — local addon count: ${storedUrls.size}" }
        if (storedUrls.isEmpty()) {
            // Nothing stored locally, but bootstrap HAS run: publish that fact so watchers can tell
            // this settled empty state from the initial one they saw before initialize().
            _uiState.update { it.copy(isInitialized = true) }
            bootstrap.complete()
            return
        }

        val existingByUrl = _uiState.value.addons.associateBy(ManagedAddon::manifestUrl)
        _uiState.value = AddonsUiState(
            addons = storedUrls.map { manifestUrl ->
                existingByUrl[manifestUrl].toPendingAddon(
                    manifestUrl = manifestUrl,
                    enabled = enabledByUrl[manifestUrl],
                )
            },
            isInitialized = true,
        )

        storedUrls.forEach { manifestUrl ->
            val existing = existingByUrl[manifestUrl]
            val addon = _uiState.value.addons.firstOrNull { it.manifestUrl == manifestUrl }
            if (addon?.enabled == true && (existing == null || (addon.manifest == null && !addon.isRefreshing))) {
                refreshAddon(manifestUrl)
            }
        }
        bootstrap.complete()
    }

    fun onProfileChanged(profileId: Int) {
        val effectiveProfileId = resolveEffectiveProfileId(profileId)
        if (effectiveProfileId == currentProfileId && bootstrap.initialized) return
        cancelActiveRefreshes()
        currentProfileId = effectiveProfileId
        bootstrap.reset()
        pulledFromServer = false
        addonListKnown = null
        _serverPullSettled.value = false
        _uiState.value = AddonsUiState()
    }

    fun clearLocalState() {
        cancelActiveRefreshes()
        pushJobsByProfile.values.forEach(Job::cancel)
        pushJobsByProfile.clear()
        currentProfileId = 1
        bootstrap.reset()
        pulledFromServer = false
        addonListKnown = null
        _serverPullSettled.value = false
        _uiState.value = AddonsUiState()
    }

    suspend fun pullFromServer(profileId: Int) {
        var settled = true
        try {
            currentProfileId = resolveEffectiveProfileId(profileId)
            rememberStoredAddonList()
            log.i { "pullFromServer() — profileId=$profileId, initialized=${bootstrap.initialized}, pulledFromServer=$pulledFromServer" }
            runCatching {
                val rows = SupabaseProvider.client.postgrest
                    .from("addons")
                    .select {
                        filter { eq("profile_id", currentProfileId) }
                        order("sort_order", Order.ASCENDING)
                    }
                    .decodeList<AddonRow>()

                val rowsByUrl = linkedMapOf<String, AddonRow>()
                rows.forEach { row ->
                    val manifestUrl = normalizeServerManifestUrl(row.url)
                    if (!rowsByUrl.containsKey(manifestUrl)) {
                        rowsByUrl[manifestUrl] = row.copy(url = manifestUrl)
                    }
                }

                val urls = rowsByUrl.keys.toList()
                log.i { "pullFromServer() — server returned ${rows.size} addons" }
                urls.forEachIndexed { i, u -> log.d { "  server[$i]: $u" } }

                // Upstream 1854dfc3 ("prevent automatic pulls from restoring deleted data"): the
                // server list is authoritative, an EMPTY one included. Two branches used to treat an
                // empty list as a fluke instead — the first pull of each launch re-pushed the local
                // list to the server ("migrating local addons"), later pulls restored it locally —
                // so removing every add-on on the phone or the web was undone by the next Apple TV
                // launch (ADD-1). Both are gone; an empty list now clears this profile like any
                // other server list replaces it. A signed-in account can no longer push a local list
                // it never pulled (shouldBlockUnhydratedAddonPush below), so nothing needs migrating.
                if (urls.isEmpty() && _uiState.value.addons.isNotEmpty()) {
                    log.i { "pullFromServer() — server list is empty; clearing ${_uiState.value.addons.size} local addons for profile $currentProfileId" }
                }

                val existingByUrl = _uiState.value.addons.associateBy(ManagedAddon::manifestUrl)
                _uiState.value = AddonsUiState(
                    addons = urls.map { url ->
                        val row = rowsByUrl[url]
                        existingByUrl[url].toPendingAddon(
                            manifestUrl = url,
                            userSetName = row?.name?.takeIf { it.isNotBlank() },
                            enabled = row?.enabled,
                        )
                    },
                    // The server's list IS a settled bootstrap for this profile, so the published
                    // state says so too — a pull that wins the race with initialize() must not
                    // leave watchers thinking bootstrap never happened.
                    isInitialized = true,
                )
                // ADD-1: a non-empty list straight from the account — known from now on (persist()
                // records it). An empty one leaves the marker as it was.
                if (urls.isNotEmpty()) addonListKnown = true
                persist()
                urls.forEach { url ->
                    val existing = existingByUrl[url]
                    val addon = _uiState.value.addons.firstOrNull { it.manifestUrl == url }
                    if (addon?.enabled == true && (existing == null || (addon.manifest == null && !addon.isRefreshing))) {
                        refreshAddon(url)
                    }
                }
                pulledFromServer = true
                bootstrap.complete()
                log.i { "pullFromServer() — applied ${urls.size} addons to state" }
            }.onFailure { e ->
                // runCatching captures cancellation too; without this rethrow the outer handler
                // below never sees it, and a pull cancelled by a profile switch would mark the
                // NEW profile's gate settled (finally runs after onProfileChanged's reset).
                if (e is CancellationException) throw e
                log.e(e) { "pullFromServer() — FAILED" }
            }
        } catch (error: CancellationException) {
            settled = false
            throw error
        } finally {
            // Signals a settle on every completion path except cancellation (an applied list and
            // a real failure alike). A
            // cancelled pull (e.g. profile switched away mid-flight) must NOT count as settled:
            // the seed/push guards below need to keep waiting for a pull that actually finishes.
            if (settled) _serverPullSettled.value = true
        }
    }

    suspend fun awaitManifestsLoaded() {
        if (_uiState.value.addons.isEmpty()) return
        uiState.first { state ->
            state.addons.isEmpty() ||
                state.addons.any { it.manifest != null } ||
                state.addons.none { it.isRefreshing }
        }
    }

    suspend fun addAddon(rawUrl: String): AddAddonResult {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) {
            return AddAddonResult.Error(resourceString("This profile uses primary addons.", StringKey.profile_primary_addons_required))
        }
        log.i { "addAddon() — rawUrl=$rawUrl" }
        val manifestUrl = try {
            normalizeManifestUrl(rawUrl)
        } catch (error: IllegalArgumentException) {
            return AddAddonResult.Error(error.message ?: resourceString("Enter a valid addon URL", StringKey.addon_invalid_url))
        }

        if (_uiState.value.addons.any { it.manifestUrl == manifestUrl }) {
            return AddAddonResult.Error(resourceString("That addon is already installed.", StringKey.addon_already_installed))
        }

        val manifest = try {
            withContext(Dispatchers.Default) {
                val payload = fetchAddonResponseText(manifestUrl)
                AddonManifestParser.parse(
                    manifestUrl = manifestUrl,
                    payload = payload,
                )
            }
        } catch (error: Throwable) {
            return AddAddonResult.Error(error.message ?: resourceString("Unable to load manifest", StringKey.addon_load_manifest_failed))
        }

        _uiState.update { current ->
            current.copy(
                addons = current.addons + ManagedAddon(
                    manifestUrl = manifestUrl,
                    manifest = manifest,
                    isRefreshing = false,
                    errorMessage = null,
                ),
            )
        }
        persist()
        pushToServer()
        return AddAddonResult.Success(manifest)
    }

    fun removeAddon(manifestUrl: String) {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) return
        log.i { "removeAddon() — $manifestUrl" }
        var changed = false
        _uiState.update { current ->
            val updatedAddons = current.addons.filterNot { it.manifestUrl == manifestUrl }
            changed = updatedAddons.size != current.addons.size
            if (changed) current.copy(addons = updatedAddons) else current
        }
        if (!changed) return
        persist()
        pushToServer()
    }

    fun moveAddon(fromIndex: Int, toIndex: Int) {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) return
        var changed = false
        _uiState.update { current ->
            val addons = current.addons
            if (
                fromIndex !in addons.indices ||
                toIndex !in addons.indices ||
                fromIndex == toIndex
            ) {
                return@update current
            }

            val reordered = addons.toMutableList()
            val movingAddon = reordered.removeAt(fromIndex)
            reordered.add(toIndex, movingAddon)
            changed = true
            current.copy(addons = reordered)
        }
        if (!changed) return
        persist()
        pushToServer()
    }

    fun setAddonEnabled(manifestUrl: String, enabled: Boolean) {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) return
        var shouldRefresh = false
        var changed = false
        _uiState.update { current ->
            current.copy(
                addons = current.addons.map { addon ->
                    if (addon.manifestUrl != manifestUrl || addon.enabled == enabled) {
                        addon
                    } else {
                        changed = true
                        shouldRefresh = enabled && addon.manifest == null && !addon.isRefreshing
                        addon.copy(enabled = enabled)
                    }
                },
            )
        }
        if (!changed) return
        persist()
        pushToServer()
        if (shouldRefresh) {
            refreshAddon(manifestUrl)
        }
    }

    fun refreshAll() {
        _uiState.value.addons.filter { it.enabled }.distinctBy { it.manifestUrl }.forEach { addon ->
            refreshAddon(
                manifestUrl = addon.manifestUrl,
                forceRefresh = true,
            )
        }
    }

    fun refreshAddon(
        manifestUrl: String,
        forceRefresh: Boolean = false,
    ) {
        val existingJob = activeRefreshJobs[manifestUrl]
        if (existingJob?.isActive == true) return

        markRefreshing(manifestUrl)
        var refreshJob: Job? = null
        refreshJob = scope.launch {
            try {
                val result = runCatching {
                    val payload = fetchAddonResponseText(
                        url = manifestUrl,
                        forceRefresh = forceRefresh,
                    )
                    AddonManifestParser.parse(
                        manifestUrl = manifestUrl,
                        payload = payload,
                    )
                }

                _uiState.update { current ->
                    current.copy(
                        addons = current.addons.map { addon ->
                            if (addon.manifestUrl != manifestUrl) {
                                addon
                            } else {
                                result.fold(
                                    onSuccess = { manifest ->
                                        addon.copy(
                                            manifest = manifest,
                                            isRefreshing = false,
                                            errorMessage = null,
                                        )
                                    },
                                    onFailure = { error ->
                                        addon.copy(
                                            isRefreshing = false,
                                            errorMessage = error.message ?: resourceString("Unable to load manifest", StringKey.addon_load_manifest_failed),
                                        )
                                    },
                                )
                            }
                        },
                    )
                }
            } finally {
                if (activeRefreshJobs[manifestUrl] === refreshJob) {
                    activeRefreshJobs.remove(manifestUrl)
                }
            }
        }
        activeRefreshJobs[manifestUrl] = refreshJob
    }

    /// Whether the default-addon seed may run right now. Guests/signed-out sessions seed
    /// immediately (nothing to pull); a signed-in account must wait until the first server pull
    /// settles, so the seed can never race the pull and full-replace-push a nearly-empty list
    /// over the account (docs/addon-wipe-investigation-2026-08-28.md) — and it only seeds a list
    /// this device has never known (ADD-1: see `addonListKnown`).
    fun seedingAllowed(): Boolean =
        defaultAddonSeedingAllowed(
            authState = AuthRepository.state.value,
            serverPullSettled = _serverPullSettled.value,
            addonListKnown = addonListKnown ?: storedAddonListKnown(currentProfileId),
        )

    /// ADD-1: true once it is settled that the default-addon seed will NOT run for this profile
    /// session — a signed-in account, its first pull settled, and a list this device already knew.
    /// Home then treats the seed as done (the way it treats a failed seed) instead of holding its
    /// rows for one that never comes.
    fun defaultSeedDeclined(): Boolean {
        val authState = AuthRepository.state.value
        if (authState !is AuthState.Authenticated || authState.isAnonymous) return false
        if (!_serverPullSettled.value) return false
        return addonListKnown ?: storedAddonListKnown(currentProfileId)
    }

    /// ADD-2: whether the active profile is a secondary profile set to use the primary profile's
    /// add-ons. Install, remove, move and enable/disable are no-ops then (install reports it, the
    /// others return silently), so the Add-ons screen reads this to explain and lock its controls.
    fun isManagedByPrimaryProfile(): Boolean = isUsingPrimaryAddonsFromSecondaryProfile()

    private fun pushToServer() {
        if (isUsingPrimaryAddonsFromSecondaryProfile()) return
        if (shouldBlockUnhydratedAddonPush(AuthRepository.state.value, pulledFromServer)) {
            // Deliberate data-direction choice (Codex 2026-08-28 P2, declined): a mutation made
            // before this device has ever seen the account's list is non-authoritative — that is
            // the exact shape that wiped a tester's account (the Cinemeta seed). The pull's apply
            // wins over the pre-hydration edit, an empty account list included (upstream 1854dfc3
            // removed the branch that used to push the local list over an empty account).
            log.w { "pushToServer() — BLOCKED: signed-in account but the addon list was never hydrated from the server; a full-replace push composed from this state can wipe the account's addons" }
            return
        }
        val profileId = currentProfileId
        val addons = _uiState.value.addons
            .distinctBy { it.manifestUrl }
            .mapIndexed { index, addon ->
                AddonPushItem(
                    url = addon.manifestUrl,
                    name = addon.userSetName?.takeIf { it.isNotBlank() } ?: addon.manifest?.name ?: "",
                    enabled = addon.enabled,
                    sortOrder = index,
                )
            }
        pushJobsByProfile[profileId]?.cancel()
        var pushJob: Job? = null
        pushJob = scope.launch {
            try {
                delay(ADDON_PUSH_DEBOUNCE_MS)
                log.d { "pushToServer() — profileId=$profileId, pushing ${addons.size} addons" }
                val params = buildJsonObject {
                    put("p_profile_id", profileId)
                    put("p_addons", json.encodeToJsonElement(addons))
                    putSyncOriginClientId()
                }
                SupabaseProvider.client.postgrest.rpc("sync_push_addons", params)
                log.d { "pushToServer() — success" }
                // ADD-1: this non-empty list is now the account's — a later empty server list is
                // a deletion, not a fresh account (see addonListKnown).
                if (addons.isNotEmpty() && isActive) markAddonListKnown(profileId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                log.e(error) { "pushToServer() — FAILED" }
            } finally {
                if (pushJobsByProfile[profileId] === pushJob) {
                    pushJobsByProfile.remove(profileId)
                }
            }
        }
        pushJobsByProfile[profileId] = pushJob
    }

    private fun markRefreshing(manifestUrl: String) {
        _uiState.update { current ->
            current.copy(
                addons = current.addons.map { addon ->
                    if (addon.manifestUrl == manifestUrl) {
                        addon.copy(
                            isRefreshing = true,
                            errorMessage = null,
                        )
                    } else {
                        addon
                    }
                },
            )
        }
    }

    private fun persist() {
        // Read back BEFORE anything is written, so a device upgraded from a build without the
        // marker still judges its stored list by what the older build left (see
        // resolveStoredAddonListKnown); no-op once this session has done it.
        rememberStoredAddonList()
        val addons = _uiState.value.addons
        AddonStorage.saveInstalledAddonUrls(
            currentProfileId,
            dedupeManifestUrls(addons.map { it.manifestUrl }),
        )
        AddonStorage.saveAddonEnabledStates(
            currentProfileId,
            addons.associate { it.manifestUrl to it.enabled },
        )
        // ADD-1: written with every list so the next session reads the marker, not a guess.
        AddonStorage.saveAddonListKnown(currentProfileId, addonListKnown == true)
    }

    /// ADD-1: a non-empty list for [profileId] reached the server.
    private fun markAddonListKnown(profileId: Int) {
        if (profileId == currentProfileId) addonListKnown = true
        AddonStorage.saveAddonListKnown(profileId, true)
    }

    private fun loadLocalEnabledStates(): Map<String, Boolean> =
        AddonStorage.loadAddonEnabledStates(currentProfileId)
            .mapKeys { (url, _) -> ensureManifestSuffix(url) }

    /// Captures `addonListKnown` once per profile session, BEFORE anything this session persists
    /// (initialize(), pullFromServer() and persist() all call it first), so it reflects what an
    /// earlier session left on this device.
    private fun rememberStoredAddonList() {
        if (addonListKnown == null) {
            addonListKnown = storedAddonListKnown(currentProfileId)
        }
    }

    private fun storedAddonListKnown(profileId: Int): Boolean =
        resolveStoredAddonListKnown(
            marker = AddonStorage.loadAddonListKnown(profileId),
            storedUrls = AddonStorage.loadInstalledAddonUrls(profileId),
        )

    private fun cancelActiveRefreshes() {
        activeRefreshJobs.values.forEach(Job::cancel)
        activeRefreshJobs.clear()
    }

    private fun resolveEffectiveProfileId(profileId: Int): Int {
        val ctx = AddonProfileProvider.context
        return if (ctx.activeProfileIndex != null && ctx.activeProfileIndex != 1 && ctx.usesPrimaryAddons) 1 else profileId
    }

    private fun isUsingPrimaryAddonsFromSecondaryProfile(): Boolean {
        val ctx = AddonProfileProvider.context
        return ctx.activeProfileIndex != null && ctx.activeProfileIndex != 1 && ctx.usesPrimaryAddons
    }
}

private fun ManagedAddon?.toPendingAddon(
    manifestUrl: String,
    userSetName: String? = null,
    enabled: Boolean? = null,
): ManagedAddon =
    when {
        this == null -> ManagedAddon(
            manifestUrl = manifestUrl,
            isRefreshing = enabled ?: true,
            userSetName = userSetName,
            enabled = enabled ?: true,
        )
        manifest != null -> copy(
            manifestUrl = manifestUrl,
            isRefreshing = false,
            userSetName = userSetName ?: this.userSetName,
            enabled = enabled ?: this.enabled,
        )
        isRefreshing -> copy(
            manifestUrl = manifestUrl,
            userSetName = userSetName ?: this.userSetName,
            enabled = enabled ?: this.enabled,
        )
        else -> copy(
            manifestUrl = manifestUrl,
            isRefreshing = enabled ?: this.enabled,
            errorMessage = null,
            userSetName = userSetName ?: this.userSetName,
            enabled = enabled ?: this.enabled,
        )
    }

private fun dedupeManifestUrls(urls: List<String>): List<String> =
    urls.map(::ensureManifestSuffix).distinct()

private fun ensureManifestSuffix(url: String): String {
    val path = url.substringBefore("?").trimEnd('/')
    val query = url.substringAfter("?", "")
    val withSuffix = if (path.endsWith("/manifest.json")) path else "$path/manifest.json"
    return if (query.isEmpty()) withSuffix else "$withSuffix?$query"
}

/// Server rows can carry `stremio://` deep-link URLs (the website stores what the user pasted) —
/// unfetchable by the HTTP client, so the manifest never loads and the addon is silently inert.
/// Map to https and ensure the manifest suffix so server rows dedupe with app-added ones.
private fun normalizeServerManifestUrl(rawUrl: String): String {
    val trimmed = rawUrl.trim()
    val https = if (trimmed.startsWith("stremio://")) {
        "https://${trimmed.removePrefix("stremio://")}"
    } else {
        trimmed
    }
    return ensureManifestSuffix(https)
}

private fun normalizeManifestUrl(rawUrl: String): String {
    val trimmed = rawUrl.trim()
    require(trimmed.isNotEmpty()) { resourceString("Enter an addon URL.", StringKey.addons_error_enter_url) }

    val normalizedScheme = when {
        trimmed.startsWith("http://") || trimmed.startsWith("https://") -> trimmed
        trimmed.startsWith("stremio://") -> "https://${trimmed.removePrefix("stremio://")}"
        else -> "https://$trimmed"
    }

    val withoutFragment = normalizedScheme.substringBefore("#")
    val query = withoutFragment.substringAfter("?", "")
    val path = withoutFragment.substringBefore("?").trimEnd('/')
    val manifestPath = if (path.endsWith("/manifest.json")) {
        path
    } else {
        "$path/manifest.json"
    }

    return if (query.isEmpty()) manifestPath else "$manifestPath?$query"
}

/// A signed-in, non-anonymous account's addon list must never full-replace-push to the server
/// before at least one pull has hydrated `pulledFromServer` — otherwise a locally-seeded or
/// locally-mutated list (e.g. HomeViewModel's default Cinemeta seed on an empty local state) can
/// overwrite the account's real addon rows via `sync_push_addons`'s full-replace semantics. See
/// docs/addon-wipe-investigation-2026-08-28.md.
internal fun shouldBlockUnhydratedAddonPush(authState: AuthState, pulledFromServer: Boolean): Boolean =
    authState is AuthState.Authenticated && !authState.isAnonymous && !pulledFromServer

/// Guests and signed-out sessions have nothing to pull, so the default-addon seed may run as
/// soon as local state is known empty. A signed-in, non-anonymous account must instead wait for
/// the first server pull to settle, so the seed can't race the pull and get full-replace-pushed
/// over the account's real addon list. See docs/addon-wipe-investigation-2026-08-28.md.
///
/// [addonListKnown] (ADD-1): this device already knew the account's list for this profile. An
/// empty list is then the user's own doing — every add-on removed here or on another device — and
/// seeding (whose push reaches every device) would resurrect one of them, so only a list this
/// device has never known is seeded.
///
/// ADD-1: whether a profile's add-on list counts as known when a session starts. [marker] is what
/// earlier sessions recorded; null on a device upgraded from a build that never wrote it, where a
/// non-empty stored list counts — those builds pushed every local list to an empty account on
/// their first pull, so such a list did reach the server.
internal fun resolveStoredAddonListKnown(marker: Boolean?, storedUrls: List<String>): Boolean =
    marker ?: storedUrls.isNotEmpty()

internal fun defaultAddonSeedingAllowed(
    authState: AuthState,
    serverPullSettled: Boolean,
    addonListKnown: Boolean = false,
): Boolean =
    authState !is AuthState.Authenticated || authState.isAnonymous || (serverPullSettled && !addonListKnown)
