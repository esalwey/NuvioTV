import Combine
import SharedCore

/// The segment kinds Settings > Playback > Automatic Skipping offers. Raw values are the stored
/// values of the shared `AutoSkipSegmentType` (the same profile setting the phone writes).
///
/// A movie's end credits ("movie-credits") are not listed: no skip provider returns them for the
/// content this app plays, so a switch for them would do nothing. A selection the phone synced for
/// them is kept untouched.
enum AutoSkipKind: String, CaseIterable, Identifiable {
    case intro, recap, outro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .intro: return String(localized: "Intro")
        case .recap: return String(localized: "Recap")
        case .outro: return String(localized: "Outro")
        }
    }

    var subtitle: String {
        switch self {
        case .intro: return String(localized: "Skip intros and anime openings automatically.")
        case .recap: return String(localized: "Skip \u{201C}previously on\u{201D} recaps automatically.")
        case .outro: return String(localized: "Skip end credits and anime endings automatically. A scene after the credits still plays.")
        }
    }

    var segmentType: AutoSkipSegmentType {
        switch self {
        case .intro: return .intro
        case .recap: return .recap
        case .outro: return .outro
        }
    }
}

/// The skip-related player settings, watched straight off `PlayerSettingsRepository` (profile
/// scoped and synced): the Automatic Skipping selection, the Anime Skip switch and client ID, and
/// the IntroDB API key (checked with IntroDB before it is saved).
///
/// Never stopped by the pane's `onDisappear`: a page pushed from the pane (Automatic Skipping)
/// reads this same model and the pane disappears while it is up. The watcher ends with the model.
@MainActor
final class SkipSettingsModel: ObservableObject {
    @Published private(set) var autoSkipKinds: Set<String> = []
    @Published private(set) var animeSkipEnabled = false
    @Published private(set) var animeSkipClientId = ""
    /// The key itself is a credential and is never shown; the pane only needs to know it is there.
    @Published private(set) var hasIntroDbKey = false
    /// The typed key is being checked with IntroDB right now.
    @Published private(set) var isCheckingIntroDbKey = false
    /// Why the last typed key was not saved.
    @Published private(set) var introDbKeyError: String?

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        PlayerSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PlayerSettingsUiState else { return }
            let kinds = state.autoSkipSegmentTypeValues
            if self.autoSkipKinds != kinds { self.autoSkipKinds = kinds }
            if self.animeSkipEnabled != state.animeSkipEnabled { self.animeSkipEnabled = state.animeSkipEnabled }
            if self.animeSkipClientId != state.animeSkipClientId { self.animeSkipClientId = state.animeSkipClientId }
            let hasKey = !state.introDbApiKey.isEmpty
            if self.hasIntroDbKey != hasKey { self.hasIntroDbKey = hasKey }
        }
    }

    deinit { watcher?.cancel() }

    // MARK: - Automatic Skipping

    func isAutoSkipEnabled(_ kind: AutoSkipKind) -> Bool {
        autoSkipKinds.contains(kind.rawValue)
    }

    func setAutoSkip(_ kind: AutoSkipKind, enabled: Bool) {
        PlayerSettingsRepository.shared.setAutoSkipSegmentTypeEnabled(segmentType: kind.segmentType, enabled: enabled)
    }

    /// The row's trailing value: "Off", or the picked kinds ("Intro and Recap").
    var autoSkipSummary: String {
        let titles = AutoSkipKind.allCases.filter(isAutoSkipEnabled).map(\.title)
        return titles.isEmpty ? String(localized: "Off") : ListFormatter.localizedString(byJoining: titles)
    }

    // MARK: - Anime Skip

    func setAnimeSkipEnabled(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setAnimeSkipEnabled(enabled: enabled)
    }

    func setAnimeSkipClientId(_ clientId: String) {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        PlayerSettingsRepository.shared.setAnimeSkipClientId(clientId: trimmed)
    }

    // MARK: - IntroDB

    /// Checks the typed key with IntroDB, and saves it only if IntroDB accepts it: a mistyped key
    /// would otherwise read "Saved" until something failed. The typed key stays in the field when
    /// it is rejected, with the reason under it.
    func saveIntroDbApiKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isCheckingIntroDbKey else { return }
        isCheckingIntroDbKey = true
        introDbKeyError = nil
        // The check outlives a profile switch: the key belongs to the profile it was typed on.
        let profileId = ProfileRepository.shared.activeProfileId
        SkipIntroRepository.shared.verifyIntroDbApiKey(apiKey: key) { [weak self] valid, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingIntroDbKey = false
                guard ProfileRepository.shared.activeProfileId == profileId else { return }
                if valid?.boolValue == true {
                    PlayerSettingsRepository.shared.setIntroDbApiKey(apiKey: key)
                } else {
                    self.introDbKeyError = String(localized: "IntroDB didn\u{2019}t accept this key, or couldn\u{2019}t be reached. Check it and try again.")
                }
            }
        }
    }

    func clearIntroDbApiKey() {
        introDbKeyError = nil
        PlayerSettingsRepository.shared.setIntroDbApiKey(apiKey: "")
    }
}
