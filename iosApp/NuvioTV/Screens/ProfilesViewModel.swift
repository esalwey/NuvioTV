import Combine
import Foundation
import SharedCore

/// Observes the shared `ProfileRepository` and exposes local (guest-mode) profile management to the
/// tvOS UI. All operations persist locally via `ProfileStorage` (NSUserDefaults) because the app runs
/// in anonymous mode — no sign-in, no cloud. Selecting a profile drives `ActiveProfileProvider`
/// (wired in Phase 0), so downstream data (watch progress, library, …) is scoped per profile.
@MainActor
final class ProfilesViewModel: ObservableObject {
    @Published private(set) var profiles: [NuvioProfile] = []
    @Published private(set) var activeProfile: NuvioProfile?
    @Published private(set) var isBusy = false
    /// Cloud avatar catalog (empty in guest mode / offline — pickers hide themselves).
    @Published private(set) var avatars: [AvatarCatalogItem] = []

    /// Max profiles supported by the shared repository (`MAX_PROFILES`).
    let maxProfiles = 6

    /// True when signed in with a real Nuvio account (PIN + avatar catalog need the cloud).
    /// Fed by a watcher on `AuthRepository.state` (the exported StateFlow has no sync `.value`).
    @Published private(set) var isCloudAccount = false

    /// The profile the app was last entered with (set by `select`). When "Who's watching?" is
    /// opened from inside the app, picking this profile goes straight back (upstream 519510591).
    @Published private(set) var sessionProfileIndex: Int32?

    private var watcher: FlowWatcher?
    private var avatarsWatcher: FlowWatcher?
    private var authWatcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        ProfileRepository.shared.loadCachedProfiles()
        watcher = FlowWatcherKt.watch(ProfileRepository.shared.state) { [weak self] emitted in
            guard let self, let state = emitted as? ProfileState else { return }
            self.profiles = state.profiles
            self.activeProfile = state.activeProfile
        }
        avatarsWatcher = FlowWatcherKt.watch(AvatarRepository.shared.avatars) { [weak self] emitted in
            guard let self, let items = emitted as? [AvatarCatalogItem] else { return }
            self.avatars = items
        }
        authWatcher = FlowWatcherKt.watch(AuthRepository.shared.state) { [weak self] emitted in
            guard let self else { return }
            self.isCloudAccount = (emitted as? AuthStateAuthenticated)?.isAnonymous == false
        }
        // Hydrates from cache, then fetches the catalog RPC (no-ops without a cloud session).
        AvatarRepository.shared.fetchAvatars { _ in }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        avatarsWatcher?.cancel()
        avatarsWatcher = nil
        authWatcher?.cancel()
        authWatcher = nil
    }

    // MARK: - Actions

    /// Breadcrumbs bracket every Kotlin call: a throw crossing back into Swift here aborts the
    /// process rather than surfacing as a catchable error, so the last line printed names the stage
    /// that took the app down. Kept out of `#if DEBUG` on purpose — testers run release builds, and
    /// their console log is the only diagnostic we get for a crash we cannot reproduce locally.
    func select(_ profile: NuvioProfile) {
        print("[ProfileSelect] selecting profile \(profile.profileIndex)")
        ProfileRepository.shared.selectProfile(profileIndex: profile.profileIndex)
        print("[ProfileSelect] selectProfile returned — requesting full pull")
        // Full cloud pull for the selected profile (addons first, then the rest in parallel).
        // Self-guarding: no-op in guest mode / signed out, so the local-only flow is unchanged.
        SyncManager.shared.pullAllForProfile(profileId: profile.profileIndex)
        // Periodic activity polling (library + watch progress) for the session. Self-guarding the
        // same way; a profile switch re-targets the loop, sign-out cancels it via cancelAccountSync.
        SyncManager.shared.startPeriodicNuvioSyncPull(profileId: profile.profileIndex)
        sessionProfileIndex = profile.profileIndex
        print("[ProfileSelect] full pull requested — tap complete")
    }

    /// Upstream 519510591 + 6761ebabb: back into the app on the profile it is already running —
    /// no PIN, no repository fan-out, no cloud pull. Only the periodic activity poll, stopped when
    /// the picker opened, is re-armed (it waits a full interval before its first pull).
    func resumeSessionProfile() {
        guard let index = sessionProfileIndex else { return }
        print("[ProfileSelect] back to the running profile \(index) — no fan-out, no pull")
        SyncManager.shared.startPeriodicNuvioSyncPull(profileId: index)
    }

    /// Whether the app is still running `sessionProfileIndex` and that profile still exists (a
    /// deletion in the picker re-points the repository at another profile without a fan-out,
    /// and then only a real selection may enter the app).
    func canResumeSessionProfile() -> Bool {
        guard let index = sessionProfileIndex else { return false }
        return ProfileRepository.shared.activeProfileId == index
            && profiles.contains(where: { $0.profileIndex == index })
    }

    /// `completion(true)` once the profile is saved; `false` when the push failed (STAB-09), so
    /// the editor can stay open and say so instead of closing on an edit the server never got.
    func createProfile(
        name: String,
        colorHex: String,
        avatarId: String? = nil,
        avatarUrl: String? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        isBusy = true
        ProfileRepository.shared.createProfile(
            name: name,
            avatarColorHex: colorHex,
            avatarId: avatarId,
            avatarUrl: avatarUrl,
            usesPrimaryAddons: false
        ) { [weak self] saved, _ in
            let ok = saved?.boolValue == true
            DispatchQueue.main.async {
                self?.isBusy = false
                completion(ok)
            }
        }
    }

    /// Same contract as `createProfile`. The shared repository keeps `usesPrimaryPlugins` as stored.
    func updateProfile(
        _ profile: NuvioProfile,
        name: String,
        colorHex: String,
        avatarId: String? = nil,
        avatarUrl: String? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        isBusy = true
        ProfileRepository.shared.updateProfile(
            profileIndex: profile.profileIndex,
            name: name,
            avatarColorHex: colorHex,
            avatarId: avatarId,
            avatarUrl: avatarUrl,
            usesPrimaryAddons: profile.usesPrimaryAddons
        ) { [weak self] saved, _ in
            let ok = saved?.boolValue == true
            DispatchQueue.main.async {
                self?.isBusy = false
                completion(ok)
            }
        }
    }

    // MARK: - PIN (cloud accounts only; RPCs verify/set/clear server-side)

    /// Verifies a profile PIN. Falls back to the shared local cache when offline.
    func verifyPin(_ profile: NuvioProfile, pin: String, completion: @escaping (PinVerifyResult?) -> Void) {
        ProfileRepository.shared.verifyPin(profileIndex: profile.profileIndex, pin: pin) { result, _ in
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Sets (or changes, when `currentPin` is provided) a profile's 4-digit PIN.
    func setPin(profileIndex: Int32, pin: String, currentPin: String?, completion: @escaping (PinVerifyResult?) -> Void) {
        ProfileRepository.shared.setPin(profileIndex: profileIndex, pin: pin, currentPin: currentPin) { result, _ in
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Removes a profile's PIN lock (requires the current PIN).
    func clearPin(profileIndex: Int32, currentPin: String?, completion: @escaping (PinVerifyResult?) -> Void) {
        ProfileRepository.shared.clearPin(profileIndex: profileIndex, currentPin: currentPin) { result, _ in
            DispatchQueue.main.async { completion(result) }
        }
    }

    func deleteProfile(_ profile: NuvioProfile, completion: @escaping () -> Void = {}) {
        ProfileRepository.shared.deleteProfile(profileIndex: profile.profileIndex) { _ in
            DispatchQueue.main.async { completion() }
        }
    }

    deinit {
        watcher?.cancel()
        avatarsWatcher?.cancel()
        authWatcher?.cancel()
    }
}
