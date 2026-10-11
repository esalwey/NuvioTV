import SwiftUI
import SharedCore

// Settings > Playback rows for skipping, built from the same kit as their neighbours
// (SettingsRowViews.swift): a pushed page for the multi-select, stock toggles and key entry.

/// "Automatic Skipping": a pushed page (`NavigationLink`, the tvOS Settings way to a multi-select)
/// whose row shows the current selection as its trailing value, like a `SettingsPickerRow`.
struct AutoSkipSettingsLinkRow: View {
    @ObservedObject var skip: SkipSettingsModel

    var body: some View {
        NavigationLink {
            AutoSkipSettingsPage(skip: skip)
        } label: {
            LabeledContent {
                Text(skip.autoSkipSummary)
                    .font(SettingsRowFont.title)
                    .settingsAccentTint()
            } label: {
                SettingsRowLabel(
                    title: String(localized: "Automatic Skipping"),
                    subtitle: String(localized: "Skip intros, recaps and credits without pressing a button.")
                )
            }
        }
    }
}

/// The page behind the row: one stock toggle per kind. Menu pops back to Playback.
struct AutoSkipSettingsPage: View {
    @ObservedObject var skip: SkipSettingsModel

    var body: some View {
        List {
            SettingsSection(
                title: nil,
                footer: String(localized: "A short message confirms each skip. Seeking back to watch a segment again is respected, and a scene after the credits is never skipped.")
            ) {
                ForEach(AutoSkipKind.allCases) { kind in
                    SettingsToggleRow(
                        title: kind.title,
                        subtitle: kind.subtitle,
                        isOn: Binding(
                            get: { skip.isAutoSkipEnabled(kind) },
                            set: { skip.setAutoSkip(kind, enabled: $0) }
                        )
                    )
                }
            }
        }
        .navigationTitle(String(localized: "Automatic Skipping"))
    }
}

/// Where skip timings come from beyond the built-in providers: Anime Skip (a client ID) and the
/// IntroDB API key. Both credentials sync with the account, so they also reach the phone app.
struct SkipSourcesSection: View {
    @ObservedObject var skip: SkipSettingsModel

    var body: some View {
        SettingsSection(
            String(localized: "Skip Sources"),
            footer: String(localized: "Intro and credits timings come from IntroDB and AniSkip. Anime Skip adds more anime. Credentials sync with your account.")
        ) {
            SettingsToggleRow(
                title: String(localized: "Anime Skip"),
                subtitle: String(localized: "Also look up skip timings on Anime Skip. Needs a client ID from anime-skip.com."),
                isOn: Binding(get: { skip.animeSkipEnabled }, set: { skip.setAnimeSkipEnabled($0) })
            )
            if skip.animeSkipEnabled {
                if skip.animeSkipClientId.isEmpty {
                    DebridKeyEntryRow(
                        providerName: "Anime Skip",
                        placeholder: String(localized: "Anime Skip client ID"),
                        saveTitle: String(localized: "Save Client ID")
                    ) { skip.setAnimeSkipClientId($0) }
                } else {
                    SettingsValueRow(title: String(localized: "Client ID"), value: skip.animeSkipClientId)
                    SettingsDestructiveRow(
                        title: String(localized: "Remove Client ID"),
                        systemImage: "trash"
                    ) { skip.setAnimeSkipClientId("") }
                }
            }

            if skip.hasIntroDbKey {
                SettingsValueRow(
                    title: String(localized: "IntroDB API Key"),
                    value: String(localized: "Saved"),
                    subtitle: String(localized: "Lets you submit intro timings to IntroDB from the Nuvio app on your phone.")
                )
                SettingsDestructiveRow(
                    title: String(localized: "Remove API Key"),
                    systemImage: "trash"
                ) { skip.clearIntroDbApiKey() }
            } else {
                // Checked with IntroDB before it is saved; a rejected key stays in the field with
                // the reason below it.
                DebridKeyEntryRow(
                    providerName: "IntroDB",
                    placeholder: String(localized: "IntroDB API key"),
                    clearsOnSave: false,
                    isValidating: skip.isCheckingIntroDbKey,
                    errorMessage: skip.introDbKeyError
                ) { skip.saveIntroDbApiKey($0) }
            }
        }
    }
}
