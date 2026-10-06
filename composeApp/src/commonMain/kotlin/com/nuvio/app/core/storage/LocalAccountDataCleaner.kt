package com.nuvio.app.core.storage

import com.nuvio.app.core.build.AppFeaturePolicy
import com.nuvio.app.core.sync.SyncManager
import com.nuvio.app.core.sync.ProfileSettingsSync
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.catalog.CatalogRepository
import com.nuvio.app.features.collection.CollectionMobileSettingsRepository
import com.nuvio.app.features.collection.CollectionRepository
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.details.MetaScreenSettingsRepository
import com.nuvio.app.features.home.HomeCatalogSettingsRepository
import com.nuvio.app.features.home.HomeRepository
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.library.LibraryDisplaySettingsRepository
import com.nuvio.app.features.notifications.EpisodeReleaseNotificationsRepository
import com.nuvio.app.features.player.PlayerLaunchStore
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.p2p.P2pSettingsRepository
import com.nuvio.app.features.plugins.PluginRepository
import com.nuvio.app.features.player.SubtitleRepository
import com.nuvio.app.features.profiles.AvatarRepository
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.search.SearchRepository
import com.nuvio.app.features.settings.ThemeSettingsRepository
import com.nuvio.app.features.streams.StreamContextStore
import com.nuvio.app.features.streams.StreamBadgeSettingsRepository
import com.nuvio.app.features.streams.StreamLaunchStore
import com.nuvio.app.features.streams.StreamsRepository
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.trakt.TraktAuthRepository
import com.nuvio.app.features.trakt.TraktSettingsRepository
import com.nuvio.app.core.ui.CardDepthStyleRepository
import com.nuvio.app.core.ui.PosterCardStyleRepository
import com.nuvio.app.features.watchprogress.ContinueWatchingPreferencesRepository
import com.nuvio.app.features.watchprogress.ContinueWatchingEnrichmentCache
import com.nuvio.app.features.watchprogress.WatchProgressRepository
import com.nuvio.app.features.watchprogress.WatchProgressSourceCoordinator
import com.nuvio.app.features.watched.WatchedRepository

internal object LocalAccountDataCleaner {
    fun wipe() {
        SyncManager.cancelAccountSync()
        WatchProgressSourceCoordinator.clearLocalState()
        ProfileSettingsSync.clearAccountState()
        ContinueWatchingEnrichmentCache.clearLocalState()
        WatchProgressRepository.clearLocalState()
        WatchedRepository.clearLocalState()
        LibraryRepository.runAccountStorageWipe {
            PlatformLocalAccountDataCleaner.wipe()
        }

        ProfileRepository.clearInMemory()
        // Server-scoped catalog: a server switch must not keep serving the previous server's
        // avatar filenames (persisted payload is wiped via the AccountDataStores registry).
        AvatarRepository.clearLocalState()
        AddonRepository.clearLocalState()
        if (AppFeaturePolicy.pluginsEnabled) {
            PluginRepository.clearLocalState()
        }
        HomeRepository.clear()
        HomeCatalogSettingsRepository.clearLocalState()
        MetaScreenSettingsRepository.clearLocalState()
        LibraryRepository.clearLocalState()
        LibraryDisplaySettingsRepository.clearLocalState()
        ContinueWatchingPreferencesRepository.clearLocalState()
        EpisodeReleaseNotificationsRepository.clearLocalState()
        CollectionMobileSettingsRepository.clearLocalState()
        CollectionRepository.clearLocalState()
        ThemeSettingsRepository.clearLocalState()
        PosterCardStyleRepository.clearLocalState()
        CardDepthStyleRepository.clearLocalState()
        TraktAuthRepository.clearLocalState()
        TraktSettingsRepository.clearLocalState()
        // Provider-neutral fan-out to every registered tracking provider (Trakt, Simkl, …). The
        // two explicit Trakt calls above stay: they clear repository state the registry does not
        // own. Without this, Simkl's in-memory auth/sync state survived sign-out on the phone —
        // tvOS's TvOsAccountDataCleaner has always called it.
        // NOTE: this only resets IN-MEMORY state — TrackingProfileStore.clearLocalState does not
        // erase persisted payloads. On-disk erasure is PlatformLocalAccountDataCleaner's job,
        // driven by core.account.AccountDataStores.
        TrackingProviderRegistry.clearLocalState()
        PlayerSettingsRepository.clearLocalState()
        StreamBadgeSettingsRepository.clearLocalState()
        P2pSettingsRepository.clearLocalState()
        CatalogRepository.clear()
        StreamsRepository.clear()
        MetaDetailsRepository.clear()
        SearchRepository.reset()
        SubtitleRepository.clear()
        PlayerLaunchStore.clear()
        StreamLaunchStore.clear()
        StreamContextStore.clear()
    }
}

internal expect object PlatformLocalAccountDataCleaner {
    fun wipe()
}
