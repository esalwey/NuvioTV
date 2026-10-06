import Combine
import Foundation
import SharedCore

/// Manages installed addons: lists them, installs a new one by manifest URL, removes, and toggles
/// enabled. Backed by the shared `AddonRepository` (NSUserDefaults-persisted on tvOS).
@MainActor
final class AddonsViewModel: ObservableObject {
    @Published private(set) var addons: [ManagedAddon] = []
    @Published private(set) var statusMessage: String?
    /// Whether `statusMessage` reports a failure (drawn in red) rather than a success.
    @Published private(set) var statusIsError = false
    @Published private(set) var isInstalling = false
    /// ADD-2: the active (secondary) profile uses the main profile's add-ons. The shared repository
    /// then ignores install / remove / enable / disable, so the screen explains and locks them
    /// instead of looking broken.
    @Published private(set) var managedByPrimary = false
    /// The main profile's name, for the ADD-2 notice (nil when unknown).
    @Published private(set) var primaryProfileName: String?

    private var watcher: FlowWatcher?
    private var profileWatcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            self.addons = state.addons
            self.managedByPrimary = AddonRepository.shared.isManagedByPrimaryProfile()
        }
        profileWatcher = FlowWatcherKt.watch(ProfileRepository.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? ProfileState else { return }
            self.primaryProfileName = state.profiles.first(where: { $0.profileIndex == 1 })?.name
            self.managedByPrimary = AddonRepository.shared.isManagedByPrimaryProfile()
        }
        AddonRepository.shared.initialize()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        profileWatcher?.cancel()
        profileWatcher = nil
    }

    /// ADD-2 notice, naming the main profile when known.
    var managedByPrimaryMessage: String {
        if let name = primaryProfileName, !name.isEmpty {
            return String(localized: "This profile uses the add-ons of \(name). To install, remove or turn off an add-on, switch to \(name).")
        }
        return String(localized: "This profile uses the main profile\u{2019}s add-ons. To install, remove or turn off an add-on, switch to the main profile.")
    }

    /// ADD-3: `onInstalled` runs only once the add-on is actually installed, so the caller keeps
    /// the typed URL after a failure instead of making the user retype it on the Siri Remote.
    func install(_ rawUrl: String, onInstalled: @escaping () -> Void = {}) {
        let url = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        guard !managedByPrimary else {
            showStatus(managedByPrimaryMessage, isError: true)
            return
        }
        isInstalling = true
        statusMessage = nil

        AddonRepository.shared.addAddon(rawUrl: url) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.isInstalling = false
                if let error {
                    self.showStatus(String(localized: "Couldn't install: \(error.localizedDescription)"), isError: true)
                } else if let failure = result as? AddAddonResultError {
                    self.showStatus(String(localized: "Couldn't install: \(failure.message)"), isError: true)
                } else if let success = result as? AddAddonResultSuccess {
                    self.showStatus(String(localized: "Installed \(success.manifest.name)."), isError: false)
                    onInstalled()
                } else {
                    self.showStatus(String(localized: "Couldn't install that URL."), isError: true)
                }
            }
        }
    }

    func remove(_ addon: ManagedAddon) {
        guard !managedByPrimary else {
            showStatus(managedByPrimaryMessage, isError: true)
            return
        }
        AddonRepository.shared.removeAddon(manifestUrl: addon.manifestUrl)
    }

    func setEnabled(_ addon: ManagedAddon, _ enabled: Bool) {
        guard !managedByPrimary else {
            showStatus(managedByPrimaryMessage, isError: true)
            return
        }
        AddonRepository.shared.setAddonEnabled(manifestUrl: addon.manifestUrl, enabled: enabled)
    }

    /// ADD-3: re-fetch a manifest that failed to load (row context menu).
    func retry(_ addon: ManagedAddon) {
        AddonRepository.shared.refreshAddon(manifestUrl: addon.manifestUrl, forceRefresh: true)
    }

    /// Display name: manifest name once loaded, otherwise the add-on's host (never the full URL,
    /// which for configured add-ons can carry an API key).
    func displayName(_ addon: ManagedAddon) -> String {
        if let name = addon.manifest?.name, !name.isEmpty { return name }
        return Self.maskedUrl(addon.manifestUrl, hostOnly: true)
    }

    /// ADD-3: the manifest URL as a row subtitle, with the configuration part (path and query,
    /// where debrid add-ons keep the user's API key) collapsed to "…".
    static func maskedUrl(_ manifestUrl: String, hostOnly: Bool = false) -> String {
        guard let components = URLComponents(string: manifestUrl), let host = components.host, !host.isEmpty else {
            return hostOnly ? String(localized: "Add-on") : manifestUrl
        }
        let hostPart = components.port.map { "\(host):\($0)" } ?? host
        if hostOnly { return hostPart }
        let path = components.path
        let hasConfiguration = (components.query?.isEmpty == false)
            || !(path.isEmpty || path == "/" || path == "/manifest.json")
        return hasConfiguration ? "\(hostPart)/\u{2026}/manifest.json" : "\(hostPart)/manifest.json"
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    deinit {
        watcher?.cancel()
        profileWatcher?.cancel()
    }
}
