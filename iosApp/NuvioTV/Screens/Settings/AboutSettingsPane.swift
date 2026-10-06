import SwiftUI
import SharedCore

/// "About" category content: build/version truth (FEAT-13). Reads the version straight out of the
/// running bundle instead of any hand-maintained constant, so this pane can never drift from what
/// was actually built — the "Stamp Build Metadata" run-script build phase writes NuvioCommitSHA /
/// NuvioBetaTag into Info.plist at build time (see project.pbxproj, NuvioTV target).
///
/// VIS-01: a public build shows Version, Build, tvOS, Device and Source code here, and nothing
/// else. Every probe, readout and A/B lever moved to `DeveloperSettingsPane`, which appears as its
/// own Settings category after Version is pressed `DeveloperMode.unlockPressCount` (7) times. The
/// unlock is persisted, so Release IPAs (what testers run) can still reach the diagnostics.
///
/// Focus: the Version row is a `Button` (it has to take presses), so the pane always has one
/// focusable row — the BUG-47 requirement that every pane can be entered from the sidebar.
struct AboutSettingsPane: View {
    @AppStorage(DeveloperMode.unlockedKey) private var developerUnlocked = false
    /// Presses on Version during this visit. Starts again from zero each time the pane appears.
    @State private var versionPresses = 0

    var body: some View {
        SettingsSection(String(localized: "About")) {
            Button(action: registerVersionPress) {
                LabeledContent {
                    Text("\(Self.marketingVersion) (\(Self.buildNumber))")
                        .font(SettingsRowFont.title)
                        .foregroundStyle(.secondary)
                } label: {
                    SettingsRowLabel(title: String(localized: "Version"), subtitle: unlockHint)
                }
            }
            .accessibilityIdentifier("about_version_row")

            SettingsValueRow(
                title: String(localized: "Build"),
                value: Self.betaTag
            )
            SettingsValueRow(
                title: String(localized: "tvOS"),
                value: ProcessInfo.processInfo.operatingSystemVersionString
            )
            SettingsValueRow(
                title: String(localized: "Device"),
                value: Self.deviceModelIdentifier
            )
            SettingsValueRow(
                title: String(localized: "settings.about.sourceCode", defaultValue: "Source Code", comment: "About pane row title; the value is the public repository address"),
                value: "github.com/esalwey/NuvioMobile"
            )
        }
        .onAppear { versionPresses = 0 }
    }

    /// Shown under Version once the presses start to count, Android-style, so the unlock is
    /// discoverable for someone who was told about it and invisible to everyone else.
    private var unlockHint: String? {
        if developerUnlocked {
            guard versionPresses > 0 else { return nil }
            return String(
                localized: "settings.about.developerShown",
                defaultValue: "Developer settings are in the Settings list.",
                comment: "Shown under Version in About after the hidden Developer settings are unlocked"
            )
        }
        let remaining = DeveloperMode.unlockPressCount - versionPresses
        guard versionPresses >= 3, remaining > 0 else { return nil }
        return String(
            localized: "settings.about.developerCountdown",
            defaultValue: "Press \(remaining) more times to show Developer settings.",
            comment: "Countdown under Version in About while unlocking the hidden Developer settings; the number is the presses left"
        )
    }

    private func registerVersionPress() {
        guard !developerUnlocked else {
            versionPresses = DeveloperMode.unlockPressCount
            return
        }
        versionPresses += 1
        if versionPresses >= DeveloperMode.unlockPressCount {
            developerUnlocked = true
        }
    }

    private static var marketingVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0"
    }

    private static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    /// Stamped by the "Stamp Build Metadata" run-script build phase from `NUVIO_BETA_TAG` (set by
    /// scripts/release-beta.sh). Empty on plain Xcode Debug builds, which never set that env var.
    private static var betaTag: String {
        let tag = (Bundle.main.object(forInfoDictionaryKey: "NuvioBetaTag") as? String) ?? ""
        return tag.isEmpty ? String(localized: "Dev build") : tag
    }

    /// The hardware model identifier (e.g. "AppleTV6,2"), read via `uname(2)` — `UIDevice.current`
    /// only exposes the marketing/user-assigned name, not the model.
    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier += String(UnicodeScalar(UInt8(value)))
        }
    }
}
