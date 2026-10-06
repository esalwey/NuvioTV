import Combine
import SharedCore

/// Backs the Settings "Trakt" section. Wraps the shared `TraktAuthRepository` device-code flow:
/// `connect()` asks Trakt for a user code — the repo publishes it (plus the verification URL) via
/// its uiState and polls `/oauth/device/token` in the background until the user approves the code
/// at trakt.tv/activate on another device (or it expires / is denied). Once connected, the player
/// scrobbles automatically (`TraktScrobbleRepository` no-ops while disconnected).
@MainActor
final class TraktViewModel: ObservableObject {
    @Published private(set) var credentialsConfigured = true
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var username: String?
    /// Non-nil while a device flow is pending approval — drives the activation card.
    @Published private(set) var deviceUserCode: String?
    @Published private(set) var deviceVerificationUrl: String?
    @Published private(set) var errorMessage: String?

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        TraktAuthRepository.shared.ensureLoaded(profileId: ProfileRepository.shared.activeProfileId)
        watcher = FlowWatcherKt.watch(TraktAuthRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? TraktAuthUiState else { return }
            self.credentialsConfigured = state.credentialsConfigured
            self.isConnected = state.mode == .connected
            self.isLoading = state.isLoading
            self.username = state.username
            self.deviceUserCode = state.deviceUserCode
            self.deviceVerificationUrl = state.deviceVerificationUrl
            let error = state.errorMessage ?? ""
            self.errorMessage = error.isEmpty ? nil : error
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        // Note: an in-flight device flow keeps polling inside the shared repo even while
        // unsubscribed, so leaving Settings mid-activation doesn't abort the sign-in.
    }

    func connect() {
        TraktAuthRepository.shared.onStartDeviceFlow(profileId: ProfileRepository.shared.activeProfileId)
    }

    func cancelActivation() {
        TraktAuthRepository.shared.onCancelDeviceFlow(profileId: ProfileRepository.shared.activeProfileId)
    }

    func disconnect() {
        TraktAuthRepository.shared.onDisconnectRequested(profileId: ProfileRepository.shared.activeProfileId)
    }
}
