import Combine
import Foundation
import SharedCore

// MARK: - Plain Swift mirrors of the shared media-server state
//
// The views never touch the Kotlin objects: `MediaServersController.state` is flattened into these
// value types once per emission. The Kotlin enums (`MediaServerStatus`, `ServerFailure`) are
// matched by `.name`, the same way `ServerConnectionViewModel` handles its enums, so a SCREAMING_CASE
// entry never depends on how the bridge spells it in Swift.

struct MediaServerLibraryItem: Identifiable, Equatable {
    let id: String
    let name: String
    /// "movie", "series", "collection" or "mixed".
    let kind: String
    var selected: Bool

    /// What the library holds, as the row subtitle.
    var kindLabel: String {
        switch kind {
        case "movie": return String(localized: "Movies")
        case "series": return String(localized: "Series")
        case "collection": return String(localized: "Collections")
        default: return String(localized: "Movies & Series")
        }
    }
}

struct MediaServerItem: Identifiable, Equatable {
    enum Status: Equatable {
        case ok
        case disabled
        case signInRequired
        case unreachable
    }

    let id: String
    let providerId: String
    let providerName: String
    let name: String
    let address: String
    let userName: String
    var enabled: Bool
    var useCatalogMetadata: Bool
    var importWatchState: Bool
    let supportsCatalogMetadata: Bool
    let supportsWatchStateImport: Bool
    var libraries: [MediaServerLibraryItem]
    let status: Status

    /// "Jellyfin · viewer", plus the health note when the server is not simply working.
    var summary: String {
        var parts = [providerName, userName]
        if let note = status.note { parts.append(note) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

extension MediaServerItem.Status {
    /// Short health note for a row subtitle; nil while everything works.
    var note: String? {
        switch self {
        case .ok: return nil
        case .disabled: return String(localized: "Disabled")
        case .signInRequired: return String(localized: "Sign in again")
        case .unreachable: return String(localized: "Server unavailable")
        }
    }
}

struct MediaServerProviderItem: Identifiable, Equatable {
    let id: String
    let displayName: String
    let minimumVersion: String
}

/// Backs Settings → Account & Services → Media Servers (the list, the server page and the sign-in
/// page share one instance). Thin mirror of the shared `MediaServersController.state`: actions are
/// fire-and-forget into Kotlin and every outcome comes back through the watcher. Toggles are applied
/// optimistically so a switch never snaps back for the frame it takes the state to round-trip.
@MainActor
final class MediaServersViewModel: ObservableObject {
    @Published private(set) var servers: [MediaServerItem] = []
    @Published private(set) var providers: [MediaServerProviderItem] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var connectError: String?
    /// Bumped by the shared controller once per successful sign-in.
    @Published private(set) var connectGeneration = 0
    @Published private(set) var refreshingServerId: String?
    @Published private(set) var refreshError: String?

    private var watcher: FlowWatcher?

    /// Idempotent: the list, the server page and the sign-in page all call it from `onAppear`. The
    /// watcher lives until this model is deallocated, so a page being pushed over another never
    /// leaves the one underneath without updates.
    func start() {
        guard watcher == nil else { return }
        MediaServersController.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(MediaServersController.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? MediaServersUiState else { return }
            self.apply(state)
        }
    }

    deinit { watcher?.cancel() }

    // MARK: - Lookups

    func server(_ id: String) -> MediaServerItem? {
        servers.first { $0.id == id }
    }

    func provider(_ id: String) -> MediaServerProviderItem? {
        providers.first { $0.id == id }
    }

    // MARK: - Actions

    func connect(provider: MediaServerProviderItem, address: String, username: String, password: String) {
        guard !isConnecting else { return }
        MediaServersController.shared.connect(
            providerId: provider.id,
            address: address,
            username: username,
            password: password
        )
    }

    func clearConnectFailure() {
        MediaServersController.shared.clearConnectFailure()
    }

    func refreshLibraries(_ id: String) {
        guard refreshingServerId == nil else { return }
        MediaServersController.shared.refreshLibraries(connectionId: id)
    }

    func setEnabled(_ id: String, _ value: Bool) {
        mutate(id) { $0.enabled = value }
        MediaServersController.shared.setEnabled(connectionId: id, enabled: value)
    }

    func setCatalogMetadata(_ id: String, _ value: Bool) {
        mutate(id) { $0.useCatalogMetadata = value }
        MediaServersController.shared.setCatalogMetadata(connectionId: id, enabled: value)
    }

    func setImportWatchState(_ id: String, _ value: Bool) {
        mutate(id) { $0.importWatchState = value }
        MediaServersController.shared.setImportWatchState(connectionId: id, enabled: value)
    }

    func setLibrarySelected(_ serverId: String, libraryId: String, _ value: Bool) {
        mutate(serverId) { server in
            if let index = server.libraries.firstIndex(where: { $0.id == libraryId }) {
                server.libraries[index].selected = value
            }
        }
        MediaServersController.shared.setLibrarySelected(connectionId: serverId, libraryId: libraryId, selected: value)
    }

    func remove(_ id: String) {
        servers.removeAll { $0.id == id }
        MediaServersController.shared.remove(connectionId: id)
    }

    private func mutate(_ id: String, _ change: (inout MediaServerItem) -> Void) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        change(&servers[index])
    }

    // MARK: - State mirror

    private func apply(_ state: MediaServersUiState) {
        servers = state.servers.map(Self.item(from:))
        let mappedProviders = state.providers.map {
            MediaServerProviderItem(id: $0.id, displayName: $0.displayName, minimumVersion: $0.minimumVersion)
        }
        providers = mappedProviders
        isConnecting = state.isConnecting
        connectGeneration = Int(state.connectGeneration)
        refreshingServerId = state.refreshingServerId

        let connectFailure: ServerFailure? = state.connectFailure
        if let connectFailure {
            let provider = mappedProviders.first { $0.id == state.connectFailureProviderId }
            connectError = Self.signInMessage(failure: connectFailure.name, provider: provider)
        } else {
            connectError = nil
        }

        let refreshFailure: ServerFailure? = state.refreshFailure
        if let refreshFailure {
            refreshError = Self.refreshMessage(failure: refreshFailure.name)
        } else {
            refreshError = nil
        }
    }

    private static func item(from info: MediaServerInfo) -> MediaServerItem {
        MediaServerItem(
            id: info.id,
            providerId: info.providerId,
            providerName: info.providerName,
            name: info.name,
            address: info.address,
            userName: info.userName,
            enabled: info.enabled,
            useCatalogMetadata: info.useCatalogMetadata,
            importWatchState: info.importWatchState,
            supportsCatalogMetadata: info.supportsCatalogMetadata,
            supportsWatchStateImport: info.supportsWatchStateImport,
            libraries: info.libraries.map {
                MediaServerLibraryItem(id: $0.id, name: $0.name, kind: $0.kind, selected: $0.selected)
            },
            status: status(info.status.name)
        )
    }

    private static func status(_ name: String) -> MediaServerItem.Status {
        switch name {
        case "DISABLED": return .disabled
        case "SIGN_IN_REQUIRED": return .signInRequired
        case "UNREACHABLE": return .unreachable
        default: return .ok
        }
    }

    /// Sign-in failures, in the words the phone app uses (`servers_error_*`).
    private static func signInMessage(failure: String, provider: MediaServerProviderItem?) -> String {
        switch failure {
        case "AUTH_REQUIRED":
            return String(localized: "Incorrect username or password.")
        case "NOT_FOUND":
            return String(localized: "Enter a valid server address.")
        case "UNREACHABLE":
            return String(localized: "Could not reach the server.")
        case "UNSUPPORTED":
            if let provider {
                return String(localized: "\(provider.displayName) \(provider.minimumVersion) or later is required.")
            }
            return String(localized: "This server version isn\u{2019}t supported.")
        case "FORBIDDEN":
            return String(localized: "This user does not have access.")
        default:
            return String(localized: "Could not connect to the server.")
        }
    }

    private static func refreshMessage(failure: String) -> String {
        switch failure {
        case "AUTH_REQUIRED":
            return String(localized: "Sign in to this server again to refresh its libraries.")
        case "UNREACHABLE":
            return String(localized: "The server is unavailable.")
        case "FORBIDDEN":
            return String(localized: "This user does not have access.")
        default:
            return String(localized: "Could not refresh the libraries.")
        }
    }
}
