import SwiftUI
import SharedCore

/// In-app language choice (Appearance > Language): "Device Default" plus every language the app
/// actually ships a translation for.
///
/// tvOS has no per-app language screen, so the choice is the `AppleLanguages` override the shared
/// `TvOsThemeSettingsStore` writes. The system reads it at launch, hence the footer: the new
/// language shows the next time Nuvio opens. The Menu key and Siri Remote cannot relaunch an app,
/// and quitting it from code is not something an Apple TV app does, so the pane says so plainly.
struct AppLanguageSettingsSection: View {
    /// Mirrors the repository value; written by this row only (the code is device-local and not part
    /// of the settings sync payload), so a plain @State is enough.
    @State private var code: String = ThemeSettingsRepository.shared.currentAppLanguageCode()

    var body: some View {
        SettingsSection(
            String(localized: "Language"),
            footer: AppLanguageSupport.isRestartPending(selectedCode: code)
                ? String(localized: "Restart Nuvio to finish switching languages.")
                : String(localized: "Choose the language Nuvio uses. Device Default follows Apple TV\u{2019}s language. A change shows the next time Nuvio opens.")
        ) {
            SettingsPickerRow(
                title: String(localized: "App Language"),
                selection: Binding(
                    get: { code },
                    set: { newValue in
                        guard newValue != code else { return }
                        code = newValue
                        ThemeSettingsRepository.shared.setAppLanguageCode(code: newValue)
                    }
                ),
                options: AppLanguageSupport.options(including: code),
                label: { AppLanguageSupport.displayName(forCode: $0) }
            )
            .accessibilityIdentifier("appearance_row_language")
        }
    }
}

/// Which languages the picker offers and how they are named; the launch snapshot that decides
/// whether a restart is still pending. Pure enough to unit-test.
enum AppLanguageSupport {
    /// The sentinel the shared `AppLanguage.DEVICE` uses.
    static let deviceCode = "device"

    /// The selection the process started with. Captured once, early (`AppThemeModel.init`), before
    /// the user can change anything: `AppleLanguages` is only read at launch, so a selection that
    /// differs from this one has not taken effect yet.
    nonisolated(unsafe) private static var launchCode: String?

    static func captureLaunchLanguage() {
        guard launchCode == nil else { return }
        ThemeSettingsRepository.shared.ensureLoaded()
        launchCode = ThemeSettingsRepository.shared.currentAppLanguageCode()
    }

    static func isRestartPending(selectedCode: String) -> Bool {
        guard let launchCode else { return false }
        return launchCode.caseInsensitiveCompare(selectedCode) != .orderedSame
    }

    /// Language codes the app bundle carries translations for, from the bundle itself so the list
    /// can never promise a language the build lacks.
    static func shippedCodes(localizations: [String] = Bundle.main.localizations) -> [String] {
        var seen = Set<String>()
        return localizations.filter { code in
            code != "Base" && !code.isEmpty && seen.insert(code.lowercased()).inserted
        }
    }

    /// Device Default first, then the shipped languages by their own names. The current value is
    /// kept in the list even if the bundle no longer ships it (a value restored from an older
    /// build), so the picker always holds a valid selection.
    static func options(including current: String, shipped: [String] = shippedCodes()) -> [String] {
        let sorted = shipped.sorted {
            displayName(forCode: $0).localizedCaseInsensitiveCompare(displayName(forCode: $1)) == .orderedAscending
        }
        var list = [deviceCode] + sorted
        if !list.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            list.append(current)
        }
        return list
    }

    /// "Device Default", or the language written in itself ("Francais", "Deutsch"), the way every
    /// platform language list does, so someone who landed in the wrong language can still find theirs.
    static func displayName(forCode code: String) -> String {
        if code.caseInsensitiveCompare(deviceCode) == .orderedSame {
            return String(localized: "Device Default")
        }
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forIdentifier: code), !name.isEmpty else { return code }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
