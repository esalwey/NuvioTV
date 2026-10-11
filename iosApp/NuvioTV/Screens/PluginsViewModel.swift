import Combine
import Foundation
import SharedCore

/// Drives the Settings "Plugins" section. Backed by the tvOS `PluginRepository` (tvosMain port
/// of mobile's JS plugin stack — QuickJS runtime). Plugin repositories arrive via cloud sync
/// from the mobile app (SyncManager → PluginSyncProvider); v1 is sync-only, so this exposes the
/// master switch and per-scraper toggles but no on-TV repo URL entry.
///
/// Repositories can also be installed on the TV: by manifest URL, or by the short code that
/// cutt.ly redirects to one (typing a URL with the remote is slow). Each provider can be run on a
/// fixed sample title to see what it returns (`testScraper`).
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

    /// Installs a repository by manifest URL, or by short code (resolved through its cutt.ly
    /// redirect first). The shared repo normalizes the URL and appends /manifest.json. Also pushes
    /// to the account so other devices pick it up.
    func addRepository(_ rawUrl: String) {
        let input = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isInstalling else { return }
        isInstalling = true
        statusMessage = nil
        guard PluginRepositoryInput.shared.isShortCode(input: input) else {
            install(url: input)
            return
        }
        Task { @MainActor in
            guard let resolved = await PluginShortCodeResolver.resolve(code: input) else {
                self.isInstalling = false
                self.statusMessage = String(localized: "Couldn't find a repository for the code \(input).")
                return
            }
            self.install(url: resolved)
        }
    }

    private func install(url: String) {
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

    // MARK: - Provider test

    /// The last test report of each provider, by scraper id (kept while the page is open).
    @Published private(set) var testReports: [String: PluginTestReport] = [:]
    /// The provider being tested; one test runs at a time.
    @Published private(set) var testingScraperId: String?
    /// Why a test could not run at all (the report itself carries a provider's own failure).
    @Published private(set) var testFailure: String?

    /// Runs `scraper` on the fixed sample (a movie, or S1E1 for a series-only provider) through the
    /// same runtime the stream list uses, and keeps the report. The runtime gives up after 60 s.
    func testScraper(_ scraper: PluginScraper) {
        guard testingScraperId == nil else { return }
        testingScraperId = scraper.id
        testFailure = nil
        PluginRepository.shared.runScraperTest(scraperId: scraper.id) { [weak self] report, error in
            Task { @MainActor in
                guard let self else { return }
                self.testingScraperId = nil
                if let report {
                    self.testReports[scraper.id] = report
                } else {
                    self.testFailure = error?.localizedDescription
                        ?? String(localized: "The test could not run.")
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
