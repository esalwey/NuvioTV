import Combine
import Foundation
import SharedCore

/// Native debrid settings for tvOS, backed entirely by the shared debrid stack (Batch 4d):
/// `DebridSettingsRepository` (per-profile settings, synced via the "tv" settings blob),
/// `DebridProviders` (Torbox / Premiumize visible; both device-code capable) and
/// `DebridProviderApis` (device-authorization start/redeem + key validation).
///
/// Once a key is saved and `enabled` is on, the shared `StreamsRepository` resolves cached
/// torrent results into direct links by itself — no player/stream-picker changes needed.
///
/// Device flow (mirrors mobile's `DebridSettingsPage`): `startDeviceAuthorization("Nuvio")`
/// → show user code + verification URL → poll `redeemDeviceAuthorization(deviceCode:)` every
/// `intervalSeconds` → Authorized(token) saved as the provider's API key. Thrown redeems are
/// treated as Pending (transient network) with a hard deadline bounding the loop.
@MainActor
final class DebridViewModel: ObservableObject {
    enum AuthPhase: Equatable {
        case idle
        case starting
        case waiting
        case failed(String)
    }

    @Published private(set) var settings: DebridSettings?
    /// Provider currently running a device-auth flow (nil = none).
    @Published private(set) var authProviderId: String?
    @Published private(set) var authPhase: AuthPhase = .idle
    @Published private(set) var activeSession: DebridDeviceAuthorization?
    /// Providers whose stored credential failed auth (BUG-21 follow-up) — fed by the shared
    /// `DebridCredentialHealth` (cache checks, resolves, and the pane-open revalidation below
    /// all record into it). Drives the "Session expired" row state.
    @Published private(set) var authFailedIds: Set<String> = []
    /// DEB-2: provider whose manually entered key is being checked with the provider right now.
    @Published private(set) var validatingKeyProviderId: String?
    /// DEB-2: why the last manual key was not saved, per provider id.
    @Published private(set) var keyErrors: [String: String] = [:]

    /// UI-visible providers: Torbox, Premiumize, AllDebrid, and Real-Debrid — hidden upstream,
    /// listed on tvOS through `DebridProviders.platformVisibleProviderIds` (DEB-1).
    let providers: [DebridProvider] = DebridProviders.shared.visible()

    private var settingsWatcher: FlowWatcher?
    private var healthWatcher: FlowWatcher?
    private var pollTask: Task<Void, Never>?
    /// Providers already probed this pane visit — `revalidateConnected()` runs on every
    /// `.onAppear`, and one whoami round-trip per provider per visit is plenty.
    private var revalidatedThisVisit: Set<String> = []

    /// Bounds the redeem-poll loop when errors are persistent rather than transient.
    private static let pollDeadlineSeconds: TimeInterval = 10 * 60

    func start() {
        guard settingsWatcher == nil else { return }
        DebridSettingsRepository.shared.ensureLoaded()
        settingsWatcher = FlowWatcherKt.watch(DebridSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? DebridSettings else { return }
            self.settings = value
        }
        healthWatcher = FlowWatcherKt.watch(DebridCredentialHealth.shared.authFailedProviderIds) { [weak self] emitted in
            guard let self else { return }
            let ids = (emitted as? Set<AnyHashable>)?.compactMap { $0 as? String } ?? []
            self.authFailedIds = Set(ids)
        }
    }

    func stop() {
        settingsWatcher?.cancel()
        settingsWatcher = nil
        healthWatcher?.cancel()
        healthWatcher = nil
        revalidatedThisVisit = []
        // DEB-3: leaving the Settings tab no longer aborts a device sign-in in progress (the code
        // is usually being typed on a phone at that moment). The poll keeps running — bounded by
        // `pollDeadlineSeconds`, like Trakt's — and saves the token itself; this view model is a
        // tab's @StateObject, so the pane shows the flow again when the tab comes back.
    }

    /// BUG-21 follow-up: probe every connected provider's stored credential against its whoami
    /// endpoint when the pane opens. "Connected" used to mean only "a key string is stored" —
    /// an expired device-flow token kept that label forever while every API call failed. The
    /// probe records into the shared `DebridCredentialHealth`, so a failure flips this pane's
    /// row to "Session expired" AND arms the stream picker's warning banner. Transport errors
    /// record nothing (offline must not read as expired).
    func revalidateConnected() {
        for provider in providers where isConnected(provider.id) {
            guard !revalidatedThisVisit.contains(provider.id) else { continue }
            revalidatedThisVisit.insert(provider.id)
            DebridCredentialHealth.shared.revalidateStoredCredential(providerId: provider.id) { _, _ in
                // Outcome lands via the health flow watcher; nothing to do here.
            }
        }
    }

    // MARK: - Derived state

    func isConnected(_ providerId: String) -> Bool {
        guard let settings else { return false }
        return !settings.apiKeyFor(providerId: providerId)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAnyKey: Bool { settings?.hasAnyApiKey ?? false }
    var resolverEnabled: Bool { settings?.enabled ?? false }

    var activeResolverId: String? {
        guard let settings else { return nil }
        let id: String? = settings.activeResolverProviderId
        return id
    }

    /// Providers currently able to act as the link resolver (connected + resolve-capable).
    var resolverProviders: [DebridProvider] {
        settings?.resolverServices.map { $0.provider } ?? []
    }

    // MARK: - Settings actions

    func setResolverEnabled(_ value: Bool) {
        DebridSettingsRepository.shared.setEnabled(value: value)
    }

    func setPreferredResolver(_ providerId: String) {
        DebridSettingsRepository.shared.setPreferredResolverProviderId(providerId: providerId)
    }

    /// Whether the provider signs in with a device code (else: API key only, e.g. Real-Debrid).
    func supportsDeviceSignIn(_ provider: DebridProvider) -> Bool {
        provider.authMethod.name == "DeviceCode"
    }

    /// DEB-2: a manually entered key is checked with the provider BEFORE it is saved — it used to be
    /// saved as-is, so a typo read "Connected" until the pane was reopened. Rejected or
    /// uncheckable keys are not saved; the entry row keeps the typed key so it can be corrected.
    ///
    /// Goes through `validateApiKeyChecked`, never `DebridProviderApi.validateApiKey`: the latter
    /// has no `@Throws`, so an offline or timed-out check would abort the app instead of reaching
    /// the `error` branch below.
    func saveManualKey(_ providerId: String, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, validatingKeyProviderId == nil else { return }
        guard DebridProviderApis.shared.apiFor(providerId: providerId) != nil else {
            storeManualKey(trimmed, for: providerId)
            return
        }
        let name = DebridProviders.shared.displayName(id: providerId)
        let owner = CredentialOwner.current
        validatingKeyProviderId = providerId
        keyErrors[providerId] = nil
        DebridProviderApis.shared.validateApiKeyChecked(providerId: providerId, apiKey: trimmed) { [weak self] valid, error in
            DispatchQueue.main.async {
                guard let self, self.validatingKeyProviderId == providerId else { return }
                self.validatingKeyProviderId = nil
                // The check outlived a profile switch or sign-out: the key belongs to the profile it
                // was typed on, not to whichever one is active now.
                guard CredentialOwner.current == owner else { return }
                if valid?.boolValue == true {
                    self.storeManualKey(trimmed, for: providerId)
                } else if error != nil {
                    self.keyErrors[providerId] = String(localized: "Couldn't reach \(name) to check this key. Check the connection and try again.")
                } else {
                    self.keyErrors[providerId] = String(localized: "\(name) didn't accept this key. Check it and try again.")
                }
            }
        }
    }

    private func storeManualKey(_ key: String, for providerId: String) {
        keyErrors[providerId] = nil
        DebridSettingsRepository.shared.setProviderApiKey(providerId: providerId, value: key)
        DebridSettingsRepository.shared.setEnabled(value: true)
    }

    func disconnect(_ providerId: String) {
        DebridSettingsRepository.shared.setProviderApiKey(providerId: providerId, value: "")
    }

    // MARK: - Device-code authorization

    func connect(_ provider: DebridProvider) {
        // A second press while this provider's own flow is starting or waiting changes nothing.
        if authProviderId == provider.id, authPhase == .starting || authPhase == .waiting { return }
        // DEB-3: a flow left waiting or failed on ANOTHER provider no longer swallows this press —
        // connecting a different provider replaces it.
        if authProviderId != nil { cancelActivation() }
        guard DebridProviderApis.shared.apiFor(providerId: provider.id) != nil else {
            authProviderId = provider.id
            authPhase = .failed(String(localized: "Device sign-in isn't available for \(provider.displayName). Use manual API key entry below."))
            return
        }
        authProviderId = provider.id
        authPhase = .starting
        activeSession = nil
        let owner = CredentialOwner.current

        // `...Checked`: a thrown start (offline, or Premiumize without a client id) reaches `error`
        // below instead of aborting the app.
        DebridProviderApis.shared.startDeviceAuthorizationChecked(providerId: provider.id, appName: "Nuvio") { [weak self] session, error in
            DispatchQueue.main.async {
                guard let self, self.authProviderId == provider.id else { return }
                guard let session else {
                    let message = error?.localizedDescription ?? ""
                    self.authPhase = .failed(
                        message.contains("PREMIUMIZE_CLIENT_ID")
                            ? String(localized: "Device sign-in isn't configured in this build (missing PREMIUMIZE_CLIENT_ID). Paste an API key from your Premiumize account instead.")
                            : String(localized: "Couldn't start device sign-in. Try again, or paste an API key manually below.")
                    )
                    return
                }
                self.activeSession = session
                self.authPhase = .waiting
                self.beginPolling(session: session, providerId: provider.id, owner: owner)
            }
        }
    }

    func cancelActivation() {
        pollTask?.cancel()
        pollTask = nil
        authProviderId = nil
        authPhase = .idle
        activeSession = nil
    }

    private enum RedeemOutcome {
        case authorized(String)
        case pending
        case expired
        case failed(String?)
    }

    /// The account and profile a key check or device sign-in was started for. Both can now finish
    /// after the user has left the pane (DEB-3) — and so after a profile switch or a sign-out — and
    /// a key is only ever saved into the profile it was entered on.
    private struct CredentialOwner: Equatable {
        let profileId: Int32
        let userId: String?

        static var current: CredentialOwner {
            CredentialOwner(
                profileId: ProfileRepository.shared.activeProfileId,
                userId: (AuthRepository.shared.state.value_ as? AuthStateAuthenticated)?.userId
            )
        }
    }

    private func beginPolling(session: DebridDeviceAuthorization, providerId: String, owner: CredentialOwner) {
        pollTask?.cancel()
        let intervalSeconds = max(Int(session.intervalSeconds), 1)
        pollTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.pollDeadlineSeconds)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let outcome = await self.redeem(providerId: providerId, deviceCode: session.deviceCode)
                guard !Task.isCancelled else { return }

                switch outcome {
                case .authorized(let token):
                    // DEB-3 follow-up: the poll now outlives the Settings tab, so the approval can
                    // land after a profile switch or sign-out. The token belongs to the profile
                    // that started the sign-in; never write it into another one.
                    guard CredentialOwner.current == owner else {
                        self.cancelActivation()
                        self.authProviderId = providerId
                        self.authPhase = .failed(String(localized: "The profile changed before this sign-in finished, so the key wasn't saved. Connect again on this profile."))
                        return
                    }
                    DebridSettingsRepository.shared.setProviderApiKey(providerId: providerId, value: token)
                    DebridSettingsRepository.shared.setEnabled(value: true)
                    self.cancelActivation()
                    return
                case .pending:
                    if Date() > deadline {
                        self.authPhase = .failed(String(localized: "Timed out waiting for approval. Try again."))
                        self.activeSession = nil
                        return
                    }
                case .expired:
                    self.authPhase = .failed(String(localized: "The code expired before it was approved. Try again."))
                    self.activeSession = nil
                    return
                case .failed(let message):
                    self.authPhase = .failed(message ?? String(localized: "Sign-in failed. Try again, or paste an API key manually below."))
                    self.activeSession = nil
                    return
                }
            }
        }
    }

    /// One redeem attempt. A completion error (thrown Kotlin exception → NSError) is treated as
    /// Pending — mobile-parity: transient connectivity mid-approval shouldn't kill the flow; the
    /// poll deadline bounds persistent failure. `...Checked` is what makes that error reach this
    /// completion: the unchecked interface method aborted the app on a throw.
    private func redeem(providerId: String, deviceCode: String) async -> RedeemOutcome {
        guard DebridProviderApis.shared.apiFor(providerId: providerId) != nil else {
            return .failed(nil)
        }
        return await withCheckedContinuation { continuation in
            DebridProviderApis.shared.redeemDeviceAuthorizationChecked(providerId: providerId, deviceCode: deviceCode) { result, _ in
                let outcome: RedeemOutcome
                if let authorized = result as? DebridDeviceAuthorizationTokenResultAuthorized {
                    outcome = .authorized(authorized.accessToken)
                } else if result is DebridDeviceAuthorizationTokenResultExpired {
                    outcome = .expired
                } else if let failed = result as? DebridDeviceAuthorizationTokenResultFailed {
                    let message: String? = failed.message
                    outcome = .failed(message)
                } else if result is DebridDeviceAuthorizationTokenResultUnsupported {
                    outcome = .failed(String(localized: "Device sign-in isn't supported for this provider."))
                } else {
                    outcome = .pending
                }
                continuation.resume(returning: outcome)
            }
        }
    }

    deinit {
        settingsWatcher?.cancel()
        pollTask?.cancel()
    }
}
