import Combine
import Foundation
import SharedCore

/// Lightweight observer of the ACTIVE server (`ServerConfigurationRepository.active`) for views
/// that only need to know "official or custom, and which host" — Welcome, AuthView's subtitle,
/// QR sign-in's fallback URL, and the Settings "Server" info row. Seeds synchronously from the
/// StateFlow's current value so the first render is already correct (no official→custom flash).
@MainActor
final class ActiveServerObserver: ObservableObject {
    @Published private(set) var isCustom = false
    @Published private(set) var displayHost = ""
    @Published private(set) var backendUrl = ""
    @Published private(set) var supportsTvLogin = true
    @Published private(set) var supportsEmailPassword = true
    @Published private(set) var tvLoginWebBaseUrl: String = ServerConfigurationKt.OFFICIAL_TV_LOGIN_WEB_BASE_URL

    private var watcher: FlowWatcher?

    init() {
        if let current = ServerConfigurationRepository.shared.active.value_ as? ServerConfiguration {
            apply(current)
        }
        watcher = FlowWatcherKt.watch(ServerConfigurationRepository.shared.active) { [weak self] emitted in
            guard let self, let configuration = emitted as? ServerConfiguration else { return }
            self.apply(configuration)
        }
    }

    private func apply(_ configuration: ServerConfiguration) {
        isCustom = configuration.isCustom
        displayHost = configuration.displayHost
        backendUrl = configuration.backendUrl
        supportsTvLogin = configuration.capabilities.tvLogin
        supportsEmailPassword = configuration.capabilities.emailPasswordAuth
        tvLoginWebBaseUrl = configuration.tvLoginWebBaseUrl
    }

    deinit { watcher?.cancel() }
}

/// Backs `ServerConnectionView` (the self-hosted server discover → review → switch flow). Thin
/// mirror of the shared `ServerConnectionController.state` StateFlow: every action is
/// fire-and-forget into the Kotlin controller and every outcome (discovered server, discovery
/// failure, switch failure, busy flags) comes back through the watcher. The Kotlin enums are
/// matched by `.name` (bridged enums aren't exhaustively switchable from Swift) and turned into
/// localized copy here, so the shared module stays string-free.
@MainActor
final class ServerConnectionViewModel: ObservableObject {
    // Active server (as the controller last saw it — refreshed after every successful switch).
    @Published private(set) var activeIsCustom = false
    @Published private(set) var activeDisplayHost = ""
    @Published private(set) var activeBackendUrl = ""
    @Published private(set) var activeSupportsTvLogin = true
    @Published private(set) var activeSupportsEmailPassword = true

    @Published private(set) var isDiscovering = false
    @Published private(set) var isSwitching = false

    // Discovered (not yet connected) server — the Kotlin object plus plain Swift mirrors so the
    // view never touches the bridge in `body`.
    @Published private(set) var discovered: ServerConfiguration?
    @Published private(set) var discoveredHost = ""
    @Published private(set) var discoveredBackendUrl = ""
    @Published private(set) var discoveredIsSecure = true
    @Published private(set) var discoveredIsPublicHost = false
    @Published private(set) var discoveredTvLogin = false
    @Published private(set) var discoveredEmailPassword = false

    @Published private(set) var failureMessage: String?
    @Published private(set) var switchFailureMessage: String?

    private var watcher: FlowWatcher?
    // Whether the last discovery attempt's typed URL carried an explicit scheme. Scheme-less
    // input defaults to https (ServerDiscoveryPolicy, upstream/Android-TV parity), which fails
    // against a plain-HTTP LAN server with no clue why — ConnectionFailed appends a hint when
    // this is false. Nil until the first discover() from this screen.
    private var lastDiscoverInputHadScheme: Bool?

    init() {
        if let seed = ServerConnectionController.shared.state.value_ as? ServerConnectionUiState {
            apply(seed)
        }
        watcher = FlowWatcherKt.watch(ServerConnectionController.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? ServerConnectionUiState else { return }
            self.apply(state)
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }

    // MARK: - Actions (all fire-and-forget; outcomes arrive via `state`)

    /// Runs `/.well-known/nuvio` discovery against `url`. Blank input is a no-op (the controller
    /// would report InvalidUrl, but an empty field shouldn't flash an error).
    func discover(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isDiscovering, !isSwitching else { return }
        lastDiscoverInputHadScheme = trimmed.contains("://")
        ServerConnectionController.shared.discover(url: trimmed)
    }

    func connectDiscovered() {
        guard !isSwitching else { return }
        ServerConnectionController.shared.connectDiscovered()
    }

    func useOfficial() {
        guard !isSwitching else { return }
        ServerConnectionController.shared.useOfficial()
    }

    func resetDiscovery() {
        ServerConnectionController.shared.resetDiscovery()
    }

    // MARK: - Lightweight sync reads for callers that don't want an observer

    /// `(isCustom, host)` of the active server, read synchronously from the repository's StateFlow.
    static var activeServerSummary: (isCustom: Bool, host: String) {
        guard let active = ServerConfigurationRepository.shared.active.value_ as? ServerConfiguration else {
            return (false, "")
        }
        return (active.isCustom, active.displayHost)
    }

    /// The base URL the active CUSTOM server was discovered from (its `discoveryUrl` minus the
    /// `/.well-known/nuvio` suffix) — pre-fills the entry field like Android TV does. Nil for the
    /// official server or when no discovery URL was recorded.
    static func activeCustomDiscoveryBase() -> String? {
        guard let active = ServerConfigurationRepository.shared.active.value_ as? ServerConfiguration,
              active.isCustom else { return nil }
        let discoveryUrl: String? = active.discoveryUrl
        guard let discoveryUrl, !discoveryUrl.isEmpty else { return nil }
        let base = discoveryUrl.components(separatedBy: "/.well-known/nuvio").first ?? discoveryUrl
        return base.isEmpty ? nil : base
    }

    // MARK: - State mirror

    private func apply(_ state: ServerConnectionUiState) {
        let active = state.activeServer
        activeIsCustom = active.isCustom
        activeDisplayHost = active.displayHost
        activeBackendUrl = active.backendUrl
        activeSupportsTvLogin = active.capabilities.tvLogin
        activeSupportsEmailPassword = active.capabilities.emailPasswordAuth

        isDiscovering = state.isDiscovering
        isSwitching = state.isSwitching

        let found: ServerConfiguration? = state.discoveredServer
        discovered = found
        if let found {
            discoveredHost = found.displayHost
            discoveredBackendUrl = found.backendUrl
            discoveredIsSecure = found.isSecure
            discoveredIsPublicHost = found.isPublicHost
            discoveredTvLogin = found.capabilities.tvLogin
            discoveredEmailPassword = found.capabilities.emailPasswordAuth
        } else {
            discoveredHost = ""
            discoveredBackendUrl = ""
            discoveredIsSecure = true
            discoveredIsPublicHost = false
            discoveredTvLogin = false
            discoveredEmailPassword = false
        }

        let failure: ServerDiscoveryFailure? = state.failure
        if let failure {
            let statusCode: KotlinInt? = state.statusCode
            failureMessage = Self.discoveryMessage(
                for: failure,
                statusCode: statusCode,
                activeIsCustom: active.isCustom,
                enteredSchemelessUrl: lastDiscoverInputHadScheme == false
            )
        } else {
            failureMessage = nil
        }

        let switchFailure: ServerSwitchFailure? = state.switchFailure
        if let switchFailure {
            switchFailureMessage = Self.switchMessage(for: switchFailure)
        } else {
            switchFailureMessage = nil
        }
    }

    /// Maps the Kotlin `ServerDiscoveryFailure` (by `.name` — PascalCase entries collapse to
    /// all-lowercase properties in Swift, and `switch` over the bridged enum isn't exhaustive).
    private static func discoveryMessage(for failure: ServerDiscoveryFailure, statusCode: KotlinInt?, activeIsCustom: Bool, enteredSchemelessUrl: Bool) -> String {
        switch failure.name {
        case "InvalidUrl":
            return String(localized: "Enter a valid HTTP or HTTPS backend URL.")
        case "OfficialServer":
            if activeIsCustom {
                return String(localized: "api.nuvio.tv is the official server. Use \u{201C}Use Official Server\u{201D} in Settings to switch back.")
            }
            return String(localized: "api.nuvio.tv is the official server and is already selected.")
        case "ConnectionFailed":
            let base = String(localized: "Couldn\u{2019}t reach the discovery endpoint. Check the URL and that the server is online.")
            guard enteredSchemelessUrl else { return base }
            return base + " " + String(localized: "Addresses without a scheme are treated as HTTPS \u{2014} include http:// for a plain-HTTP server.")
        case "HttpError":
            let code = statusCode?.intValue ?? 0
            return String(localized: "The discovery endpoint returned HTTP \(code).")
        case "ResponseTooLarge":
            return String(localized: "The discovery document is larger than allowed.")
        case "InvalidDocument":
            return String(localized: "The server returned an invalid discovery document.")
        case "UnsupportedVersion":
            return String(localized: "This discovery document version isn\u{2019}t supported.")
        case "WrongService":
            return String(localized: "The discovery document isn\u{2019}t for Nuvio.")
        case "NotSelfHosted":
            return String(localized: "The discovery document doesn\u{2019}t identify a self-hosted server.")
        case "MissingConfiguration":
            return String(localized: "The discovery document is missing a valid backend URL or publishable key.")
        case "UnsupportedAuthentication":
            return String(localized: "The server doesn\u{2019}t advertise a sign-in method this Apple TV supports (email & password or QR sign-in).")
        default:
            return String(localized: "Couldn\u{2019}t reach the discovery endpoint. Check the URL and that the server is online.")
        }
    }

    private static func switchMessage(for failure: ServerSwitchFailure) -> String {
        switch failure.name {
        case "SessionClear":
            return String(localized: "Couldn\u{2019}t safely clear the current session. The server was not changed.")
        case "Save":
            return String(localized: "Couldn\u{2019}t save the server configuration.")
        case "Restart":
            return String(localized: "The server was saved, but the app couldn\u{2019}t restart its connection. Relaunch Nuvio.")
        default:
            return String(localized: "The server was saved, but the app couldn\u{2019}t restart its connection. Relaunch Nuvio.")
        }
    }
}
