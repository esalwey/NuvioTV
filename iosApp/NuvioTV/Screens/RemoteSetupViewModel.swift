import Combine
import CoreImage
import Foundation
import SharedCore
import UIKit

/// Drives the "Remote Setup" section in Settings: runs `RemoteSetupServer`, feeds it a live
/// snapshot of addons / Home rows / key presence, surfaces incoming proposals as a confirm
/// alert, and — on confirm — applies the proposed state through the shared repos.
///
/// Nothing a browser sends is applied without an explicit confirmation on the TV.
@MainActor
final class RemoteSetupViewModel: ObservableObject {
    /// `http://<ip>:<port>` once the server is listening; nil while stopped.
    @Published private(set) var serverURL: String?
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var startFailed = false
    /// Non-nil while a browser proposal awaits the user's decision (drives the alert).
    @Published var pendingChange: RemoteSetupServer.PendingChange?
    @Published private(set) var pendingSummary: String = ""

    var isRunning: Bool { serverURL != nil }

    /// True between `start()` and the server's bind completion. Blocks re-entrant starts so a
    /// Retry tap can't stack a second attempt (and a second set of watchers) on an unresolved
    /// one (ME-002).
    private var isStarting = false
    /// Bumped by `start()` and `stop()`; a bind completion from a superseded attempt is ignored
    /// so it can't republish the URL/QR after the user pressed Stop (HI-002/ME-002).
    private var startAttempt = 0

    private let server = RemoteSetupServer()
    private var addonWatcher: FlowWatcher?
    private var rowWatcher: FlowWatcher?
    private var tmdbWatcher: FlowWatcher?
    private var mdbListWatcher: FlowWatcher?
    private var badgeWatcher: FlowWatcher?

    // Cached snapshots (updated by the watchers, read when building state JSON + applying diffs).
    private var addons: [ManagedAddon] = []
    private var rows: [HomeCatalogSettingsItem] = []
    private var tmdbKeySet = false
    private var mdbListKeySet = false
    /// Source URLs of currently imported stream badge packs (shown read-only on the web page).
    private var badgePackUrls: [String] = []

    // MARK: - Lifecycle

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        startFailed = false
        startAttempt += 1
        let attempt = startAttempt

        server.onChangeProposed = { [weak self] change in
            Task { @MainActor in
                guard let self else { return }
                self.pendingSummary = self.summarize(change.proposal)
                self.pendingChange = change
            }
        }
        server.start { [weak self] port in
            Task { @MainActor in
                guard let self, attempt == self.startAttempt else { return }
                self.isStarting = false
                guard let port, let ip = DeviceIpAddress.current(),
                      let token = self.server.sessionToken else {
                    // Bind failed or no LAN address: tear the half-started server down so a
                    // Retry begins from a clean slate (ME-002).
                    self.server.stop()
                    self.startFailed = true
                    return
                }
                // Only now that the listener is actually ready: keep the TV awake (if tvOS idles
                // into the screensaver the app suspends and the server dies mid-edit) and start
                // feeding state. On failure the idle timer was never touched (ME-002).
                UIApplication.shared.isIdleTimerDisabled = true
                self.installWatchers()
                // The token is part of the URL — scanning the QR (or typing the short URL) is
                // what authorizes the browser session (HI-001).
                let url = "http://\(ip):\(port)/?t=\(token)"
                self.serverURL = url
                self.qrImage = Self.makeQrImage(from: url)
            }
        }
    }

    func stop() {
        startAttempt += 1
        isStarting = false
        startFailed = false
        UIApplication.shared.isIdleTimerDisabled = false
        server.stop()
        serverURL = nil
        qrImage = nil
        pendingChange = nil
        cancelWatchers()
    }

    private func installWatchers() {
        cancelWatchers()
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            self.addons = state.addons
            self.pushState()
        }
        rowWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? HomeCatalogSettingsUiState else { return }
            self.rows = state.items
            self.pushState()
        }
        tmdbWatcher = FlowWatcherKt.watch(TmdbSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? TmdbSettings else { return }
            self.tmdbKeySet = state.hasApiKey
            self.pushState()
        }
        mdbListWatcher = FlowWatcherKt.watch(MdbListSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MdbListSettings else { return }
            self.mdbListKeySet = state.hasApiKey
            self.pushState()
        }
        badgeWatcher = FlowWatcherKt.watch(StreamBadgeSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? StreamBadgeSettingsUiState else { return }
            self.badgePackUrls = state.rules.imports.map(\.sourceUrl)
            self.pushState()
        }
        AddonRepository.shared.initialize()
        TmdbSettingsRepository.shared.ensureLoaded()
        MdbListSettingsRepository.shared.ensureLoaded()
        StreamBadgeSettingsRepository.shared.ensureLoaded()
    }

    private func cancelWatchers() {
        addonWatcher?.cancel()
        rowWatcher?.cancel()
        tmdbWatcher?.cancel()
        mdbListWatcher?.cancel()
        badgeWatcher?.cancel()
        addonWatcher = nil
        rowWatcher = nil
        tmdbWatcher = nil
        mdbListWatcher = nil
        badgeWatcher = nil
    }

    // MARK: - Confirm / reject

    func confirmPending() {
        guard let change = pendingChange else { return }
        apply(change.proposal)
        server.confirm(id: change.id)
        pendingChange = nil
    }

    func rejectPending() {
        guard let change = pendingChange else { return }
        server.reject(id: change.id)
        pendingChange = nil
    }

    // MARK: - State snapshot → server

    private struct StateAddon: Encodable {
        let url: String
        let name: String
        let description: String
        let enabled: Bool
    }
    private struct StateRow: Encodable {
        let key: String
        let title: String
        let enabled: Bool
        let isCollection: Bool
    }
    private struct StateSnapshot: Encodable {
        let deviceName: String
        let addons: [StateAddon]
        let rows: [StateRow]
        let tmdbKeySet: Bool
        let mdblistKeySet: Bool
        let badgePacks: [String]
    }

    private func pushState() {
        let snapshot = StateSnapshot(
            deviceName: UIDevice.current.name,
            addons: addons.map {
                StateAddon(
                    url: $0.manifestUrl,
                    name: $0.displayTitle,
                    description: $0.manifest?.description_ ?? "",
                    enabled: $0.enabled
                )
            },
            rows: rows.map {
                StateRow(
                    key: $0.key,
                    title: $0.displayTitle,
                    enabled: $0.enabled,
                    isCollection: $0.isCollection
                )
            },
            tmdbKeySet: tmdbKeySet,
            mdblistKeySet: mdbListKeySet,
            badgePacks: badgePackUrls
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            server.updateState(data)
        }
    }

    // MARK: - Applying a confirmed proposal

    private func apply(_ proposal: RemoteSetupServer.Proposal) {
        applyAddons(proposal)
        applyRows(proposal)
        if let key = proposal.tmdbKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            TmdbSettingsRepository.shared.setApiKey(value: key)
            TmdbSettingsRepository.shared.setEnabled(value: true)
        }
        if let key = proposal.mdblistKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            MdbListSettingsRepository.shared.setApiKey(value: key)
            MdbListSettingsRepository.shared.setEnabled(value: true)
        }
        // Badge pack imports (async fetch+parse; the badge watcher refreshes the page state as
        // each one lands). Already-imported URLs are re-fetched/updated by the shared repo.
        for url in proposal.badgeUrls ?? [] {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            StreamBadgeSettingsRepository.shared.importStreamBadgeRulesFromUrl(url: trimmed) { _, _ in }
        }
    }

    private func applyAddons(_ proposal: RemoteSetupServer.Proposal) {
        guard let proposed = proposal.addons else { return }
        let repo = AddonRepository.shared
        // ADD-2: every add-on edit is a no-op on a profile that uses the main profile's add-ons;
        // the confirm alert already said so (see `summarize`).
        guard !repo.isManagedByPrimaryProfile() else { return }
        let currentUrls = addons.map(\.manifestUrl)
        let proposedUrls = proposed.map(\.url)

        // 1. Removals (synchronous repo mutations).
        for url in currentUrls where !proposedUrls.contains(url) {
            repo.removeAddon(manifestUrl: url)
        }

        // 2. Enabled flips + reordering, simulated over the post-removal list. Repo indices track
        //    the simulation because removeAddon/moveAddon mutate the list synchronously.
        var simulated = currentUrls.filter { proposedUrls.contains($0) }
        for entry in proposed {
            guard let enabled = entry.enabled,
                  let existing = addons.first(where: { $0.manifestUrl == entry.url }),
                  existing.enabled != enabled
            else { continue }
            repo.setAddonEnabled(manifestUrl: entry.url, enabled: enabled)
        }
        let desired = proposedUrls.filter { simulated.contains($0) }
        for targetIndex in desired.indices {
            guard let fromIndex = simulated.firstIndex(of: desired[targetIndex]),
                  fromIndex != targetIndex
            else { continue }
            repo.moveAddon(fromIndex: Int32(fromIndex), toIndex: Int32(targetIndex))
            simulated.remove(at: fromIndex)
            simulated.insert(desired[targetIndex], at: targetIndex)
        }

        // 3. Installs (async manifest fetch; appended by the repo when they resolve).
        for entry in proposed where !currentUrls.contains(entry.url) {
            repo.addAddon(rawUrl: entry.url) { _, _ in }
        }
    }

    private func applyRows(_ proposal: RemoteSetupServer.Proposal) {
        let repo = HomeCatalogSettingsRepository.shared

        if let disabledKeys = proposal.disabledRowKeys {
            let disabled = Set(disabledKeys)
            for row in rows {
                let shouldBeEnabled = !disabled.contains(row.key)
                if row.enabled != shouldBeEnabled {
                    repo.setEnabled(key: row.key, enabled: shouldBeEnabled)
                }
            }
        }

        if let order = proposal.rowOrder {
            var simulated = rows.map(\.key)
            let desired = order.filter { simulated.contains($0) }
            for targetIndex in desired.indices {
                guard let fromIndex = simulated.firstIndex(of: desired[targetIndex]),
                      fromIndex != targetIndex
                else { continue }
                repo.moveByIndex(fromIndex: Int32(fromIndex), toIndex: Int32(targetIndex))
                simulated.remove(at: fromIndex)
                simulated.insert(desired[targetIndex], at: targetIndex)
            }
        }
    }

    // MARK: - Alert summary

    private func summarize(_ proposal: RemoteSetupServer.Proposal) -> String {
        var parts: [String] = []

        if let proposed = proposal.addons {
            let currentUrls = Set(addons.map(\.manifestUrl))
            let proposedUrls = Set(proposed.map(\.url))
            let added = proposedUrls.subtracting(currentUrls).count
            let removed = currentUrls.subtracting(proposedUrls).count
            let orderChanged = proposed.map(\.url).filter { currentUrls.contains($0) }
                != addons.map(\.manifestUrl).filter { proposedUrls.contains($0) }
            let togglesChanged = proposed.contains { entry in
                guard let enabled = entry.enabled,
                      let existing = addons.first(where: { $0.manifestUrl == entry.url })
                else { return false }
                return existing.enabled != enabled
            }
            if AddonRepository.shared.isManagedByPrimaryProfile() {
                // ADD-2: `applyAddons` skips them — say so instead of listing changes that won't happen.
                if added > 0 || removed > 0 || orderChanged || togglesChanged {
                    parts.append(String(localized: "add-on changes not applied (this profile uses the main profile\u{2019}s add-ons)"))
                }
            } else {
                if added > 0 { parts.append(String(localized: "\(added) add-on\(added == 1 ? "" : "s") installed")) }
                if removed > 0 { parts.append(String(localized: "\(removed) add-on\(removed == 1 ? "" : "s") removed")) }
                if orderChanged || togglesChanged { parts.append(String(localized: "add-on settings changed")) }
            }
        }

        if let order = proposal.rowOrder {
            let known = rows.map(\.key)
            let disabled = Set(proposal.disabledRowKeys ?? [])
            let orderChanged = order.filter { known.contains($0) } != known.filter { order.contains($0) }
            let togglesChanged = rows.contains { $0.enabled == disabled.contains($0.key) }
            if orderChanged || togglesChanged { parts.append(String(localized: "Home rows updated")) }
        }

        if proposal.tmdbKey?.isEmpty == false { parts.append(String(localized: "TMDB key set")) }
        if proposal.mdblistKey?.isEmpty == false { parts.append(String(localized: "MDBList key set")) }
        if let badgeCount = proposal.badgeUrls?.count, badgeCount > 0 {
            parts.append(String(localized: "\(badgeCount) badge pack\(badgeCount == 1 ? "" : "s") imported"))
        }

        return parts.isEmpty ? String(localized: "No changes detected.") : parts.joined(separator: " \u{00B7} ") + "."
    }

    // MARK: - QR

    private static func makeQrImage(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 14, y: 14))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    deinit {
        server.stop()
        addonWatcher?.cancel()
        rowWatcher?.cancel()
        tmdbWatcher?.cancel()
        mdbListWatcher?.cancel()
        badgeWatcher?.cancel()
    }
}
