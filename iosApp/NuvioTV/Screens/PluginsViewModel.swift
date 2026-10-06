import Combine
import Foundation
import SharedCore

/// Drives the Settings "Plugins" section. Backed by the tvOS `PluginRepository` (tvosMain port
/// of mobile's JS plugin stack — QuickJS runtime). Plugin repositories arrive via cloud sync
/// from the mobile app (SyncManager → PluginSyncProvider); v1 is sync-only, so this exposes the
/// master switch and per-scraper toggles but no on-TV repo URL entry.
@MainActor
final class PluginsViewModel: ObservableObject {
    @Published private(set) var pluginsEnabled = true
    @Published private(set) var repositories: [PluginRepositoryItem] = []
    @Published private(set) var scrapers: [PluginScraper] = []

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(PluginRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PluginsUiState else { return }
            self.pluginsEnabled = state.pluginsEnabled
            self.repositories = state.repositories
            self.scrapers = state.scrapers
        }
        PluginRepository.shared.initialize()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func setPluginsEnabled(_ enabled: Bool) {
        PluginRepository.shared.setPluginsEnabled(enabled: enabled)
    }

    func toggleScraper(_ scraper: PluginScraper, _ enabled: Bool) {
        PluginRepository.shared.toggleScraper(scraperId: scraper.id, enabled: enabled)
    }

    func refreshAll() {
        PluginRepository.shared.refreshAll()
    }

    @Published private(set) var isInstalling = false
    @Published private(set) var statusMessage: String?

    /// Installs a repository by manifest URL (the shared repo normalizes and appends
    /// /manifest.json). Also pushes to the account so other devices pick it up.
    func addRepository(_ rawUrl: String) {
        let url = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isInstalling = true
        statusMessage = nil
        PluginRepository.shared.addRepository(rawUrl: url) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                self.isInstalling = false
                if let error {
                    self.statusMessage = String(localized: "Couldn't install: \(error.localizedDescription)")
                } else if let failure = result as? AddPluginRepositoryResultError {
                    self.statusMessage = String(localized: "Couldn't install: \(failure.message)")
                } else if let success = result as? AddPluginRepositoryResultSuccess {
                    self.statusMessage = String(localized: "Installed \(success.repository.name).")
                } else {
                    self.statusMessage = String(localized: "Couldn't install that URL.")
                }
            }
        }
    }

    func removeRepository(_ repo: PluginRepositoryItem) {
        PluginRepository.shared.removeRepository(manifestUrl: repo.manifestUrl)
    }

    /// Scrapers grouped under their repository, preserving repo order.
    func scrapers(in repo: PluginRepositoryItem) -> [PluginScraper] {
        scrapers.filter { $0.repositoryUrl == repo.manifestUrl }
    }

    deinit {
        watcher?.cancel()
    }
}
