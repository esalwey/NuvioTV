import Combine
import Foundation
import SharedCore

/// Observes the shared `AuthRepository` and drives the root auth gate.
///
/// States map 1:1 onto the shared `AuthState`:
///  - `Loading`        → splash (session restore in flight)
///  - `Unauthenticated`→ Welcome screen (Sign In / Create Account / Continue as Guest)
///  - `Authenticated`  → profile gate → main app. Covers BOTH guest mode (`isAnonymous`, the
///    pre-cloud behavior) and real Nuvio accounts (Supabase email/password, synced).
///
/// For real accounts this also loads the profile cache for that user and pulls the server
/// profiles (`sync_pull_profiles`) — mirroring composeApp's `App()` auth LaunchedEffects.
@MainActor
final class AuthViewModel: ObservableObject {
    enum Gate {
        case loading
        case welcome
        case main
    }

    @Published private(set) var gate: Gate = .loading
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var accountEmail: String?
    @Published private(set) var isAnonymous = true

    private var stateWatcher: FlowWatcher?
    private var errorWatcher: FlowWatcher?

    func start() {
        guard stateWatcher == nil else { return }

        // Begin session restore: emits guest mode instantly when a stored anonymous id exists,
        // otherwise follows the Supabase session (restored, refreshed, or absent).
        AuthRepository.shared.initialize()

        stateWatcher = FlowWatcherKt.watch(AuthRepository.shared.state) { [weak self] emitted in
            guard let self else { return }
            switch emitted {
            case let authed as AuthStateAuthenticated:
                // "Already a real account" must consider anonymity, or a guest→account
                // upgrade (gate already .main) would skip registration.
                let wasRealAccount = self.gate == .main && !self.isAnonymous
                self.isAnonymous = authed.isAnonymous
                self.accountEmail = authed.email
                if !authed.isAnonymous {
                    // Real account: key the profile cache to this user and refresh from the cloud.
                    ProfileRepository.shared.ensureLoaded(userId: authed.userId)
                    ProfileRepository.shared.pullProfiles { _ in }
                    if !wasRealAccount {
                        // Register this device/session with the account (once per sign-in
                        // transition, not on every state emission).
                        Task {
                            _ = try? await DeviceSessionRegistration.shared.registerIfAuthenticated(force: true)
                        }
                    }
                }
                self.gate = .main
            case is AuthStateUnauthenticated:
                self.accountEmail = nil
                self.isAnonymous = true
                self.gate = .welcome
            default: // AuthStateLoading
                self.gate = .loading
            }
        }

        errorWatcher = FlowWatcherKt.watch(AuthRepository.shared.error) { [weak self] emitted in
            self?.errorMessage = emitted as? String
        }
    }

    func stop() {
        stateWatcher?.cancel()
        stateWatcher = nil
        errorWatcher?.cancel()
        errorWatcher = nil
    }

    // MARK: - Actions

    /// Local guest mode — random UUID in NSUserDefaults, no network (the pre-cloud default).
    func continueAsGuest() {
        AuthRepository.shared.signInAnonymously()
    }

    func signIn(email: String, password: String) {
        clearError()
        isBusy = true
        AuthRepository.shared.signInWithEmail(email: email, password: password) { [weak self] _, _ in
            DispatchQueue.main.async { self?.isBusy = false }
            // Success flows through the sessionStatus collector → AuthStateAuthenticated;
            // failure surfaces via AuthRepository.error.
        }
    }

    func signUp(email: String, password: String) {
        clearError()
        isBusy = true
        AuthRepository.shared.signUpWithEmail(email: email, password: password) { [weak self] _, _ in
            DispatchQueue.main.async { self?.isBusy = false }
            // The Nuvio backend auto-confirms email sign-ups and returns a session, so success
            // lands in AuthStateAuthenticated with no "check your email" step.
        }
    }

    /// Signs out (guest OR account) and wipes local data via the shared AccountDataCleaner seam —
    /// this is what prevents guest data (keyed by profile id) bleeding into a signed-in account.
    func signOut() {
        clearError()
        isBusy = true
        AuthRepository.shared.signOut { [weak self] _, _ in
            DispatchQueue.main.async { self?.isBusy = false }
        }
    }

    func clearError() {
        errorMessage = nil
        AuthRepository.shared.clearError()
    }

    deinit {
        stateWatcher?.cancel()
        errorWatcher?.cancel()
    }
}
