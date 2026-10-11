import Combine
import Foundation
import SharedCore

/// Backs the Startup and Cache rows of Settings > Advanced.
///
/// "Remember last profile" is the shared `ProfileRepository` flag (persisted with the profile list
/// and read at launch by `ContentView`, see `ProfileRepository.profileToResumeAtLaunch`). Only that
/// one flag is watched, so this model never reloads the profile list the way `ProfilesViewModel`
/// does when its picker opens.
@MainActor
final class AdvancedSettingsViewModel: ObservableObject {
    @Published private(set) var rememberLastProfile = false
    /// True once the Continue Watching cache was cleared during this visit to the pane.
    @Published private(set) var cacheCleared = false

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(ProfileRepository.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? ProfileState else { return }
            self.rememberLastProfile = state.rememberLastProfileEnabled
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func setRememberLastProfile(_ enabled: Bool) {
        ProfileRepository.shared.setRememberLastProfileEnabled(enabled: enabled)
    }

    /// Drops the active profile's cached Continue Watching enrichment (artwork, next-up and
    /// in-progress metadata) and re-reads watch progress from its source, the way the mobile app's
    /// Advanced page does. Watch progress and history themselves are untouched.
    func clearContinueWatchingCache() {
        let profileId = ProfileRepository.shared.activeProfileId
        ContinueWatchingEnrichmentCache.shared.clearAll(profileId: profileId)
        WatchProgressRepository.shared.clearLocalAndForceSnapshotRefreshFromServer(profileId: profileId) { _ in }
        cacheCleared = true
    }

    deinit { watcher?.cancel() }
}
