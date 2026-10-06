package com.nuvio.app.core.bootstrap

import com.nuvio.app.core.account.AccountDataCleanerProvider
import com.nuvio.app.core.account.AccountDataStores
import com.nuvio.app.core.build.FeaturePolicy
import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.core.network.ServerAuthRequirement
import com.nuvio.app.core.network.ServerConfigurationRepository
import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.core.sync.ProfileSettingsSync
import com.nuvio.app.core.sync.SyncPlatformProvider
import com.nuvio.app.core.sync.TV_SYNC_PLATFORM
import com.nuvio.app.core.sync.TVOS_SYNC_PLATFORM
import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.core.ui.CardDepthStyleRepository
import com.nuvio.app.core.ui.PosterCardStyleRepository
import com.nuvio.app.features.addons.AddonProfileContext
import com.nuvio.app.features.addons.AddonProfileProvider
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.auth.ServerConnectionController
import com.nuvio.app.features.catalog.CatalogRepository
import com.nuvio.app.features.collection.CollectionMobileSettingsRepository
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.collection.CollectionSyncService
import com.nuvio.app.features.collection.FolderDetailRepository
import com.nuvio.app.features.debrid.DebridProviders
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaScreenSettingsRepository
import com.nuvio.app.features.downloads.DownloadsRepository
import com.nuvio.app.features.home.HomeCatalogSettingsRepository
import com.nuvio.app.features.home.HomeRepository
import com.nuvio.app.features.library.LibraryDisplaySettingsRepository
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.mdblist.MdbListSettingsRepository
import com.nuvio.app.features.notifications.EpisodeReleaseNotificationsRepository
import com.nuvio.app.features.player.PlayerLaunchStore
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.player.SubtitleRepository
import com.nuvio.app.features.profiles.AvatarRepository
import com.nuvio.app.features.profiles.MAX_PROFILES
import com.nuvio.app.features.profiles.ProfileLifecycleCoordinator
import com.nuvio.app.features.profiles.ProfileLifecycleProvider
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.search.SearchHistoryRepository
import com.nuvio.app.features.search.SearchRepository
import com.nuvio.app.features.settings.ThemeSettingsRepository
import com.nuvio.app.features.settings.ThemeSettingsStoreProvider
import com.nuvio.app.features.settings.TvOsThemeSettingsStore
import com.nuvio.app.features.streams.StreamBadgeSettingsRepository
import com.nuvio.app.features.streams.StreamContextStore
import com.nuvio.app.features.streams.StreamLaunchStore
import com.nuvio.app.features.streams.StreamsRepository
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.trakt.TraktAuthRepository
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.features.upcoming.UpcomingEpisodesRepository
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watchprogress.ContinueWatchingEnrichmentCache
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesRepository
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import com.nuvio.app.features.watchprogress.WatchProgressSourceCoordinator
import co.touchlab.kermit.Logger
import kotlinx.coroutines.CancellationException
import platform.Foundation.NSUserDefaults

/**
 * tvOS-side install block for the shared provider seams.
 *
 * The phone app wires these seams in `composeApp`'s `App()` (see the `.install()` / `.provider =`
 * block there), which the tvOS target never runs — so without this call every seam falls back to
 * its default (single primary profile, id 1) and nothing the user does is profile-scoped or
 * persisted per profile. Calling [installTvOsSharedProviders] once at NuvioTV startup backs the
 * profile seams with the real (already-migrated) [ProfileRepository], so any storage keyed through
 * `core.storage.ProfileScopedKey` follows the active profile. This is the foundation the later
 * tvOS feature areas build on: Profiles, Library/Collections, Settings persistence, and Trakt.
 *
 * Scope note — only seams whose backing lives in `:shared` are wired here:
 *  - [ActiveProfileProvider] and [AddonProfileProvider] → real [ProfileRepository]  ✅ wired below.
 *  - `core.i18n` StringProvider → left null; the shared helpers already return English fallbacks,
 *    which is correct for tvOS until localization is ported.
 *  - `core.build.FeaturePolicyProvider` → `DefaultFeaturePolicy` is the tvOS baseline; this
 *    installer wraps it to flip `customServerConnectionsEnabled` (self-hosted servers), and
 *    `installTvOsPlugins()` wraps again for `pluginsEnabled`. Each wrap delegates to whatever
 *    policy is current, so the overrides compose.
 *  - `core.account.AccountDataCleanerProvider` → left no-op: its real backing
 *    (`LocalAccountDataCleaner`) is a composeApp god-object not reachable from `:shared`. It only
 *    matters for full account sign-out wipes, which tvOS doesn't offer yet.
 *  - The remaining Compose-coupled seams (Toast, Theme/NativeTab, Downloads, Notifications,
 *    PluginSync, external-subtitle cache, cloud-poster, etc.) stay on their defaults until their
 *    features land on tvOS.
 *
 * Idempotent; safe to call more than once.
 */
fun installTvOsSharedProviders() {
    // FIRST, before any other seam: allow self-hosted servers on tvOS. ServerConfigurationRepository
    // reads this flag when it first loads the persisted selection, and SupabaseProvider.client /
    // SupabaseEndpointConfig / avatarStorageUrl all read that repository — if anything below
    // touched them before this flip, a saved custom server would silently fall back to the
    // official backend until the next launch. Delegation keeps every other flag on its current
    // value (same pattern as installTvOsPlugins()).
    val basePolicy = FeaturePolicyProvider.policy
    FeaturePolicyProvider.policy = object : FeaturePolicy by basePolicy {
        override val customServerConnectionsEnabled: Boolean = true
    }

    // Active profile id → real ProfileRepository. `core.storage.ProfileScopedKey` reads this, so
    // persisted per-profile data (watch progress, library, collections, settings) is keyed to the
    // active profile instead of the hard-coded default id 1.
    ActiveProfileProvider.provider = ActiveProfileIdProvider { ProfileRepository.activeProfileId }

    // Addon profile context → real ProfileRepository, so installed add-on sets can be
    // profile-scoped (mirrors composeApp's ProfileRepositoryAddonProfileContext).
    AddonProfileProvider.context = TvOsAddonProfileContext

    // Fan out profile switches to the per-profile repositories tvOS uses. The phone app does this
    // via composeApp's ProfileLifecycleCoordinatorAdapter (~24 repos); tvOS only needs the ones it
    // actually reads. Without this, switching profiles leaves stale data (continue watching,
    // library, addons) from the previous profile on screen.
    ProfileLifecycleProvider.coordinator = TvOsProfileLifecycleCoordinator

    // Platform-scoped settings sync: the Nuvio Cloud API keeps a separate settings blob per
    // platform (p_platform). BUG-20: this app must NOT identify as "tv" — upstream's Nuvio
    // Android TV app writes that same scope with a different schema, and the two clients kept
    // full-blob-replacing each other's settings on every launch (Android lost its TMDB
    // "Enable on Modern Home Screen" + settings-appearance keys; NuvioTV got card depth /
    // poster style flipped back). "tvos" is ours alone; the legacy "tv" blob is read once as a
    // migration seed if "tvos" has no blob yet, and never written.
    SyncPlatformProvider.platform = TVOS_SYNC_PLATFORM
    SyncPlatformProvider.legacySettingsPlatforms = listOf(TV_SYNC_PLATFORM)

    // DEB-1: list Real-Debrid (API key; no device sign-in) and resolve its add-on links, instead of
    // ignoring an RD key synced from another device. See DebridProviders.platformVisibleProviderIds.
    DebridProviders.platformVisibleProviderIds = setOf(DebridProviders.REAL_DEBRID_ID)

    // Theme persistence: the shared default ThemeSettingsStore is a no-op (theme would reset every
    // launch). The tvOS adapter persists to NSUserDefaults (profile-scoped keys) and defaults to
    // CRIMSON — the app's launch look. Installed before any ThemeSettingsRepository.ensureLoaded().
    ThemeSettingsStoreProvider.store = TvOsThemeSettingsStore

    // Account-data cleaner: AuthRepository.signOut()/session-invalidation call this seam to wipe
    // local state. The default is a no-op, which on tvOS would let guest-mode data (keyed by
    // profile id, NOT user id) bleed into a signed-in account — and then sync UP to the cloud.
    // Mirrors composeApp's LocalAccountDataCleaner minus the flavor-bound/composeApp-only repos
    // (PluginRepository, P2pSettingsRepository) that tvOS doesn't ship.
    AccountDataCleanerProvider.cleaner = TvOsAccountDataCleaner

    // Self-hosted server discovery: a TV can sign in with QR (tv_login) alone, so accept servers
    // that advertise tv_login even without email+password (upstream's phone default requires
    // email+password). Then surface which backend this launch is pinned to — the persisted
    // selection was loaded by ServerConfigurationRepository on first access (after the policy
    // flip above), so this log line is also the "did the custom server survive the relaunch"
    // breadcrumb.
    ServerConnectionController.authRequirement = ServerAuthRequirement.EmailPasswordOrTvLogin
    ServerConfigurationRepository.active.value.let { server ->
        Logger.withTag("TvOsProviderInstaller").i {
            "Active server: ${if (server.isCustom) "custom" else "official"} ${server.displayHost}" +
                " (tvLogin=${server.capabilities.tvLogin}, emailPassword=${server.capabilities.emailPasswordAuth})"
        }
    }

    // Push settings changes to the per-platform ("tv") cloud blob — debrid/TMDB/MDBList keys,
    // subtitle style, poster style, theme, etc. composeApp starts this in App(); without it every
    // tvOS-set key stays local-only, so the sign-out wipe loses them and the next sign-in's pull
    // REPLACES local settings with the (empty) server blob. With it, sign-in restores everything.
    ProfileSettingsSync.startObserving()

    // Fork: tvOS now edits collection filters locally (the TMDB filter editor), so local changes
    // must PUSH to the per-profile collections blob — pulls already persist with sync=false.
    // Auth-gated inside (no-op for guests/anonymous), debounced like the settings push.
    CollectionSyncService.startObserving()

    // Tracking providers (Trakt today) → TrackingProviderRegistry. The sync spine
    // (WatchedRepository / WatchProgressRepository / LibraryRepository / SyncManager) resolves the
    // active watch-progress + library source through the registry, so nothing tracker-backed
    // resolves until the providers are registered. Each of those repositories also calls
    // `ensureTrackingProvidersRegistered()` defensively, but registering once at startup keeps the
    // very first `effectiveWatchProgressSource(...)` from seeing an empty registry and silently
    // falling back to NUVIO_SYNC.
    ensureTrackingProvidersRegistered()

    // Restore any previously-persisted profiles + active selection from NSUserDefaults before the
    // repositories read the active profile id. No-op on a fresh install (no stored payload yet);
    // wrapped defensively so a malformed cache can never crash startup.
    runCatching { ProfileRepository.loadCachedProfiles() }

    // The settings observers started above may already have loaded TraktSettingsRepository under
    // the default profile 1; if the restored active profile differs, reload so the coordinator
    // below (and everything after it) sees the restored profile's tracking-source settings —
    // tvOS has no onProfilesCached hook to do this, and for guests no cloud pull corrects it.
    TraktSettingsRepository.onProfileChanged()

    // BUG-75: arm this AFTER profile restore, so its first emitted context carries the restored
    // profile id instead of the default profile 1. Mobile only arms this for guests
    // (HomeScreen.kt:129); tvOS's sync path armed it too late (after the first full pull's
    // refreshActiveSource step), so guests here never got it at all.
    WatchProgressSourceCoordinator.ensureStarted()
}

/**
 * tvOS account-data wipe (guest→account transitions and sign-out). Two layers, mirroring
 * composeApp's `LocalAccountDataCleaner`:
 *  1. In-memory/repo state via each shared repository's `clearLocalState()`/`clear()`/`reset()`.
 *  2. NSUserDefaults keys for ALL profile slots (repo-level clears only touch the active profile's
 *     `ProfileScopedKey`s), driven entirely by `core.account.AccountDataStores` — the same registry
 *     composeApp's `PlatformLocalAccountDataCleaner.ios` reads, so the two Apple wipes can no
 *     longer drift. Both iterate 1..MAX_PROFILES.
 *
 * Adding a persisted store means adding a line to [AccountDataStores.all], NOT editing this file.
 */
private object TvOsAccountDataCleaner : com.nuvio.app.core.account.AccountDataCleaner {

    override fun wipe() {
        // FIRST, before any repository below is cleared: cancel the coordinator's observe job.
        // It watches auth/profile/settings state, and AuthRepository still reports the outgoing
        // account through most of this wipe — left running, the clears below can trigger an
        // automatic old-account refresh that races the wipe. Re-armed at the very end.
        WatchProgressSourceCoordinator.clearLocalState()

        // 0) tvOS-only extras installed from tvosMain (plugins today).
        TvOsExtraLifecycleHooks.onClearLocalState()

        // 1) Repo/in-memory state (active profile scope).
        ProfileRepository.clearInMemory()
        // The avatar catalog is server-scoped: without this, a server switch kept the previous
        // server's catalog in memory and the profile screens 404'd its filenames against the new
        // server. Persisted payload is step 2's job (registry entry "AvatarStorage").
        AvatarRepository.clearLocalState()
        AddonRepository.clearLocalState()
        HomeRepository.clear()
        HomeCatalogSettingsRepository.clearLocalState()
        MetaScreenSettingsRepository.clearLocalState()
        LibraryRepository.clearLocalState()
        LibraryDisplaySettingsRepository.clearLocalState()
        WatchProgressRepository.clearLocalState()
        WatchedRepository.clearLocalState()
        ContinueWatchingPreferencesRepository.clearLocalState()
        EpisodeReleaseNotificationsRepository.clearLocalState()
        // Home "Upcoming" row: in-memory per-show cache only (no persisted store, hence no
        // AccountDataStores entry) — cleared here so the next account never sees this one's shows.
        UpcomingEpisodesRepository.clearLocalState()
        CollectionMobileSettingsRepository.clearLocalState()
        CollectionRepository.clearLocalState()
        // UX-14 (beta.12, Codex gate 2): FolderDetailRepository now RETAINS state across screen
        // covers (detach() replaced clear() in the tvOS pop path), so the account wipe is the
        // teardown that guarantees the next profile can never hit initialize()'s same-key
        // early-return against the previous profile's cached folder items.
        FolderDetailRepository.clear()
        ThemeSettingsRepository.clearLocalState()
        PosterCardStyleRepository.clearLocalState()
        CardDepthStyleRepository.clearLocalState()
        TraktAuthRepository.clearLocalState()
        TraktSettingsRepository.clearLocalState()
        // Provider-neutral fan-out to every registered tracking provider (Trakt, Simkl, …).
        // NOTE: this only resets IN-MEMORY state — TrackingProfileStore.clearLocalState does not
        // erase persisted payloads (removeStoredProfile does). The actual on-disk erasure happens
        // in steps 2 and 3 below, so any new provider must ALSO get an entry in
        // AccountDataStores.all. Hand-maintaining that key list here is what let Simkl's auth
        // token and sync snapshot survive a wipe.
        TrackingProviderRegistry.clearLocalState()
        PlayerSettingsRepository.clearLocalState()
        StreamBadgeSettingsRepository.clearLocalState()
        CatalogRepository.clear()
        StreamsRepository.clear()
        MetaDetailsRepository.clear()
        SearchRepository.reset()
        SubtitleRepository.clear()
        PlayerLaunchStore.clear()
        StreamLaunchStore.clear()
        StreamContextStore.clear()
        // In-memory sync bookkeeping is account-scoped too: cascades into
        // ProviderCredentialSync.clearAccountState(), whose legacy-migration stash is keyed by
        // profile ID only — left alive, a stash staged before sign-out could seed the NEXT
        // account's same-numbered profile with the previous account's credentials (Codex round
        // 13; the Compose cleaner already does this). This also CANCELS the settings-push
        // observer; it is re-armed at the very end of this wipe (see below).
        // (WatchProgressSourceCoordinator.clearLocalState() runs at the very top of this wipe —
        // its observe job must die before the repository clears above, not merely before this.)
        ProfileSettingsSync.clearAccountState()

        // 2) Persisted keys for every profile slot, from the shared registry.
        val defaults = NSUserDefaults.standardUserDefaults

        AccountDataStores.applePlainKeys().forEach(defaults::removeObjectForKey)

        val profileIndexedPrefixes = AccountDataStores.appleProfileIndexedPrefixes()
        val profileScopedBaseKeys = AccountDataStores.appleProfileScopedBases()
        (1..MAX_PROFILES).forEach { profileId ->
            profileIndexedPrefixes.forEach { prefix ->
                defaults.removeObjectForKey("$prefix$profileId")
            }
            profileScopedBaseKeys.forEach { baseKey ->
                defaults.removeObjectForKey("${baseKey}_$profileId")
            }
        }

        // Keys that embed runtime data (content-id hashes, manifest URLs, debrid provider ids)
        // cannot be enumerated, so they are swept by prefix. This also clears legacy defaults
        // values left by pre-migration builds for stores that are file-backed today
        // (stream_link_*, cw_enrichment_cache_*, plugins_state_*).
        val dynamicPrefixes = AccountDataStores.appleDynamicPrefixes()
        for (key in defaults.dictionaryRepresentation().keys) {
            val keyString = key as? String ?: continue
            if (dynamicPrefixes.any { keyString.startsWith(it) }) {
                defaults.removeObjectForKey(keyString)
            }
        }

        // 3) File-backed payload stores (PayloadFileStore) — the defaults-key removals above only
        // cover values left behind by pre-migration builds.
        com.nuvio.app.core.storage.AppleFilePayloadStores.deleteAll()

        // 4) Re-arm settings-push observation for the NEXT account. clearAccountState() above
        // cancelled it, and no sign-in path on tvOS restarts it (pre-existing gap: after a
        // sign-out → sign-in, settings pushes were dead until relaunch; the server-switch flow
        // hits the same path). Safe to arm this early: pushes stay gated on an authenticated,
        // non-anonymous AuthRepository state, and startObserving() is idempotent.
        ProfileSettingsSync.startObserving()

        // Re-arm for the next account: clearLocalState() above bumped the coordinator's lifecycle
        // generation, so ensureStarted() here binds the new generation instead of leaving it unarmed.
        WatchProgressSourceCoordinator.ensureStarted()
    }
}

/**
 * tvOS fan-out for profile-lifecycle events. `ProfileRepository.selectProfile()` calls
 * [onProfileSelected]; each target repository reloads its data for the new profile (mirrors the
 * subset of composeApp's adapter that applies to the screens tvOS ships today).
 */
/**
 * Extension points for tvOS-only source sets. appleMain compiles for iOS too (where these hooks
 * stay as no-ops), so appleMain code can't reference tvosMain classes directly — tvosMain
 * installers (e.g. `installTvOsPlugins()`) assign these instead, and the cleaner/coordinator
 * below invoke them alongside the statically-known repos.
 */
object TvOsExtraLifecycleHooks {
    @kotlin.concurrent.Volatile
    var onProfileChanged: (Int) -> Unit = {}

    @kotlin.concurrent.Volatile
    var onClearLocalState: () -> Unit = {}
}

private object TvOsProfileLifecycleCoordinator : ProfileLifecycleCoordinator {
    private val log = Logger.withTag("TvOsProfileLifecycle")

    /**
     * Runs one fan-out step so a throw degrades that repository instead of killing the app.
     *
     * This whole fan-out runs on the CALLER'S thread, which for a profile tap is the Swift main
     * thread (`ProfilesViewModel.select` → `ProfileRepository.selectProfile`). A Kotlin exception
     * escaping into Swift there is not catchable on the Swift side — it reaches the Kotlin/Native
     * unhandled-exception hook and aborts the process. Because the fan-out is the same every time,
     * any one throwing repository turns into "the app force-closes every time I pick my profile"
     * (beta.1 tester report, and again after beta.3's QR sign-in put far more testers on the
     * signed-in path where the profile-scoped stores actually have content to load).
     *
     * The step name is logged before the call so a crash report or console log names the culprit
     * even if a step fails in a way this cannot contain.
     */
    private inline fun step(name: String, block: () -> Unit) {
        try {
            block()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.e(error) { "Profile-select step '$name' failed; continuing with the remaining steps" }
        }
    }

    override fun onProfileSelected(profileIndex: Int) {
        log.i { "Profile selected: $profileIndex — running fan-out" }
        // BUG-25: this list must mirror composeApp's ProfileLifecycleCoordinatorAdapter for every
        // repository tvOS uses — it had drifted to an early subset, so profile-scoped settings
        // repos NOT listed here (poster style being the reported one) kept the state loaded at
        // app boot, BEFORE the profile gate resolved the real profile id. Result: every write
        // persisted correctly under the selected profile's key while reads/renders stayed on the
        // boot-time (usually empty) row — "the option does nothing" for any profile whose id
        // differs from the boot default. The cloud-sync pull normally papers over this by calling
        // onProfileChanged() after applying a remote blob, but only presence-gated per feature —
        // a blob missing the feature key (e.g. one seeded from the BUG-20-mauled legacy "tv"
        // namespace) leaves the stale state in place for the whole session.
        step("tvOsExtras") { TvOsExtraLifecycleHooks.onProfileChanged(profileIndex) }
        step("watched") { WatchedRepository.onProfileChanged(profileIndex) }
        step("traktSettings") { TraktSettingsRepository.onProfileChanged() }
        step("traktAuth") { TraktAuthRepository.onProfileChanged(profileIndex) }
        step("library") { LibraryRepository.onProfileChanged(profileIndex) }
        step("libraryDisplaySettings") { LibraryDisplaySettingsRepository.onProfileChanged() }
        step("watchProgress") { WatchProgressRepository.onProfileChanged(profileIndex) }
        step("addons") { AddonRepository.onProfileChanged(profileIndex) }
        step("theme") { ThemeSettingsRepository.onProfileChanged() }
        step("posterCardStyle") { PosterCardStyleRepository.onProfileChanged() }
        step("cardDepthStyle") { CardDepthStyleRepository.onProfileChanged() }
        step("playerSettings") { PlayerSettingsRepository.onProfileChanged() }
        step("streamBadges") { StreamBadgeSettingsRepository.onProfileChanged() }
        step("homeCatalogSettings") { HomeCatalogSettingsRepository.onProfileChanged() }
        step("home") { HomeRepository.clear() }
        // H1 (BUG-47/UX-13) made the See All grid's pop RETAIN CatalogRepository state (detach()
        // instead of clear()) so a detail round trip restores position. That retention must not
        // survive a profile switch: without this step the next profile opening the same
        // CatalogTarget hits load()'s same-request early-return and sees the previous profile's
        // items (Codex round 3).
        step("catalog") { CatalogRepository.clear() }
        step("metaScreenSettings") { MetaScreenSettingsRepository.onProfileChanged() }
        step("continueWatchingPreferences") { ContinueWatchingPreferencesRepository.onProfileChanged() }
        step("continueWatchingEnrichment") { ContinueWatchingEnrichmentCache.onProfileChanged() }
        step("episodeReleaseAlerts") { EpisodeReleaseNotificationsRepository.onProfileChanged() }
        step("upcomingEpisodes") { UpcomingEpisodesRepository.onProfileChanged() }
        step("tmdbSettings") { TmdbSettingsRepository.onProfileChanged() }
        step("mdbListSettings") { MdbListSettingsRepository.onProfileChanged() }
        step("searchHistory") { SearchHistoryRepository.onProfileChanged() }
        step("search") { SearchRepository.reset() }
        step("collections") { CollectionRepository.onProfileChanged() }
        // UX-14 (beta.12) made the folder grid's pop RETAIN FolderDetailRepository state
        // (detach() instead of clear()) so backing out of a title restores position — the exact
        // H1/UX-13 shape the catalog step above covers, with the exact same profile-boundary
        // hole (Codex gate 2 round 3): two profiles sharing collection/folder ids would let
        // initialize()'s same-key early-return show the previous profile's items.
        step("folderDetail") { FolderDetailRepository.clear() }
        step("collectionMobileSettings") { CollectionMobileSettingsRepository.onProfileChanged() }
        step("downloads") { DownloadsRepository.onProfileChanged() }
        // Debrid keys/settings are profile-scoped too (tvOS-specific step; upstream keeps debrid
        // out of its adapter) — without this a guest profile switch (no cloud pull) would keep
        // the previous profile's keys in memory.
        step("debridSettings") { DebridSettingsRepository.onProfileChanged() }
        // Upstream 1854dfc3 (profile-switch race): LAST, once every repository above has reloaded
        // the new profile — re-baselines the settings-blob observer and the provider-credential
        // sync so this reload is not mistaken for a local edit and pushed over the new profile.
        step("profileSettingsSync") { ProfileSettingsSync.onProfileChanged() }
        log.i { "Profile-select fan-out complete for profile $profileIndex" }
    }

    override fun onProfilesCached() {}
}

/**
 * [AddonProfileContext] backed by the shared [ProfileRepository]. Kept private to this file and
 * given a tvOS-specific name so it does not collide with composeApp's
 * `ProfileRepositoryAddonProfileContext` (same seam, different module) when both are present in the
 * iOS framework build.
 */
private object TvOsAddonProfileContext : AddonProfileContext {
    override val activeProfileId: Int
        get() = ProfileRepository.activeProfileId

    override val activeProfileIndex: Int?
        get() = ProfileRepository.state.value.activeProfile?.profileIndex

    override val usesPrimaryAddons: Boolean
        get() = ProfileRepository.state.value.activeProfile?.usesPrimaryAddons == true
}
