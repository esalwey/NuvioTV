import SwiftUI
import SharedCore

/// "Content Sources" category content: TMDB metadata enrichment, MDBList ratings, and JS plugin
/// providers. Extracted from SettingsView.swift (Phase 2 HIG revamp file split) — logic and
/// wiring preserved verbatim, only regrouped into a per-category pane.
struct ContentSourcesSettingsPane: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var plugins: PluginsViewModel

    var body: some View {
        Group {
            SettingsSection(String(localized: "Metadata (TMDB)")) {
                Text("Add a free TMDB API key to enrich titles with cast profiles, studios & networks, collections, and better artwork. Create one at themoviedb.org \u{2192} Settings \u{2192} API (v3 auth). Titles you open after enabling will be enriched.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)

                if model.tmdbHasKey {
                    SettingsToggleRow(
                        title: String(localized: "TMDB Enrichment"),
                        subtitle: String(localized: "API key saved"),
                        isOn: Binding(
                            get: { model.tmdbEnabled },
                            set: { model.setTmdbEnabled($0) }
                        )
                    )
                    Text("Language for TMDB titles, descriptions, logos and the Home hero. Device follows this Apple TV's language.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                    SettingsPickerRow(
                        title: String(localized: "Metadata Language"),
                        selection: Binding(
                            get: { model.tmdbLanguageSelection },
                            set: { model.setTmdbLanguage($0) }
                        ),
                        options: LanguageOptions.tmdbMetadata.map(\.code),
                        label: { LanguageOptions.name(forCode: $0, in: LanguageOptions.tmdbMetadata) }
                    )
                    SettingsDestructiveRow(
                        title: String(localized: "Remove API Key"),
                        subtitle: String(localized: "Clears the saved TMDB key and turns enrichment off."),
                        systemImage: "trash"
                    ) {
                        model.clearTmdbKey()
                    }
                } else {
                    TmdbKeyEntryRow { model.saveTmdbKey($0) }
                }
            }

            SettingsSection(String(localized: "Ratings (MDBList)")) {
                Text("Add a free MDBList API key to show IMDb, Rotten Tomatoes, Metacritic, Trakt and Letterboxd scores in a title's Details. Create one at mdblist.com \u{2192} Preferences \u{2192} API Access. Titles you open after enabling will show the ratings.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)

                if model.mdbListHasKey {
                    SettingsToggleRow(
                        title: String(localized: "MDBList Ratings"),
                        subtitle: String(localized: "API key saved"),
                        isOn: Binding(
                            get: { model.mdbListEnabled },
                            set: { model.setMdbListEnabled($0) }
                        )
                    )
                    SettingsDestructiveRow(
                        title: String(localized: "Remove API Key"),
                        subtitle: String(localized: "Clears the saved MDBList key and turns ratings off."),
                        systemImage: "trash"
                    ) {
                        model.clearMdbListKey()
                    }
                } else {
                    DebridKeyEntryRow(providerName: "MDBList", placeholder: String(localized: "MDBList API key")) {
                        model.saveMdbListKey($0)
                    }
                }
            }

            SettingsSection(String(localized: "Library & Watch Progress")) {
                librarySection
            }

            // FEAT-10 (tester ask): choose which catalogs Search fans out to. Fewer sources
            // means faster, more focused results — the fan-out across every search-capable
            // catalog of every addon is also the app's biggest single burst of requests.
            SettingsSection(String(localized: "Search Sources")) {
                searchSourcesSection
            }

            SettingsSection(String(localized: "Plugins")) {
                pluginsSection
            }
        }
    }

    /// Display names for the Library Source / Watch Progress Source pickers below, keyed by the
    /// shared repo's provider-neutral mode strings.
    private static let librarySourceLabels: [(name: String, code: String)] = [
        (String(localized: "Nuvio Library"), "local"),
        (String(localized: "Trakt"), "trakt"),
        (String(localized: "Simkl"), "simkl"),
    ]
    private static let watchProgressSourceLabels: [(name: String, code: String)] = [
        (String(localized: "Nuvio Sync"), "nuvio_sync"),
        (String(localized: "Trakt"), "trakt"),
        (String(localized: "Simkl"), "simkl"),
    ]

    /// Library Source (which backend the Library tab reads from) and Watch Progress Source (which
    /// backend owns Continue Watching / watched history). Both are provider-neutral picks backed by
    /// `TrackingSettingsRepository`; the shared layer falls back to the local/Nuvio option on its
    /// own if the chosen provider isn't connected (`effectiveLibrarySourceMode` /
    /// `effectiveWatchProgressSource`), so this pane doesn't need to gate the options itself.
    @ViewBuilder
    private var librarySection: some View {
        Text("Choose where your library and watch progress are saved. Connect Trakt or Simkl in Account & Services first to use them as a source \u{2014} otherwise this Apple TV falls back to its local/Nuvio option automatically.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        SettingsPickerRow(
            title: String(localized: "Library Source"),
            selection: Binding(
                get: { model.librarySourceMode },
                set: { model.setLibrarySourceMode($0) }
            ),
            options: Self.librarySourceLabels.map(\.code),
            label: { code in LanguageOptions.name(forCode: code, in: Self.librarySourceLabels) }
        )

        SettingsPickerRow(
            title: String(localized: "Watch Progress Source"),
            selection: Binding(
                get: { model.watchProgressSource },
                set: { model.setWatchProgressSource($0) }
            ),
            options: Self.watchProgressSourceLabels.map(\.code),
            label: { code in LanguageOptions.name(forCode: code, in: Self.watchProgressSourceLabels) }
        )
    }

    /// FEAT-10: one toggle per search-capable catalog. Rows derive from the installed addons
    /// (SettingsViewModel's addon watcher), the disabled set is this profile's, on this Apple TV
    /// (SRC-2).
    @ViewBuilder
    private var searchSourcesSection: some View {
        // UX-8 (u/mrStevenx3, restated three times, finally "completely hide the Discover
        // section"): one container-level toggle. Synced per profile — deliberately NOT under the
        // "this Apple TV only" caption below, which describes the per-catalog rows.
        SettingsToggleRow(
            title: String(localized: "Hide Discover"),
            subtitle: model.hideDiscover
                ? String(localized: "Search shows only the search field and recent searches")
                : String(localized: "Search shows the Discover section (types, catalogs, genres) below the field"),
            isOn: Binding(
                get: { model.hideDiscover },
                set: { model.setHideDiscover($0) }
            )
        )

        // Upstream 7c1c6578 (#1934): per profile, stored on this Apple TV.
        SettingsToggleRow(
            title: String(localized: "Recent Searches"),
            subtitle: String(localized: "Save recent searches and show them on the Search screen."),
            isOn: Binding(
                get: { model.recentSearchesEnabled },
                set: { model.setRecentSearchesEnabled($0) }
            )
        )

        Text("Choose which catalogs Search looks through. Fewer sources means faster, more focused results. Applies to this profile, on this Apple TV only.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        if model.searchSourceOptions.isEmpty {
            Text("No installed add-on offers search. Install a catalog add-on with search support and its sources will appear here.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        } else {
            ForEach(model.searchSourceOptions, id: \.key) { option in
                // Legacy bare keys disable a whole collision group; exact-match misses that (Codex finding 2/4 follow-up).
                let disabled = SearchRepository.shared.isSearchSourceDisabled(optionKey: option.key, disabledCatalogKeys: model.disabledSearchSourceKeys)
                SettingsToggleRow(
                    title: "\(option.catalogName) \u{00B7} \(option.typeLabel)",
                    subtitle: disabled
                        ? String(localized: "\(option.addonName) \u{00B7} skipped when searching")
                        : String(localized: "\(option.addonName)"),
                    isOn: Binding(
                        get: { !disabled },
                        set: { model.setSearchSource(key: option.key, disabled: !$0) }
                    )
                )
            }

            // BUG-33 defect 1 (P1, twice re-opened): the tester's only way to confirm a
            // deselected catalog was actually skipped was a device log capture — and the
            // diagnostic that shipped logged at debug level, which os_log hides by default
            // (BUG-11). This mirrors it in-app: one caption naming exactly which catalogs the
            // last search hit, screenshot-able from this exact pane.
            Text(model.lastSearchFanOut ?? String(localized: "No search performed yet."))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        }
    }

    /// The Plugins section body: master switch + per-scraper toggles. Repos are managed on the
    /// phone and arrive via cloud sync (sync-only v1) — reflected in the empty-state copy.
    @ViewBuilder
    private var pluginsSection: some View {
        Text("JS plugin providers add extra stream sources. Install a repository by its manifest URL \u{2014} it syncs to your other Nuvio devices automatically.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        SettingsToggleRow(
            title: String(localized: "Enable Plugins"),
            subtitle: String(localized: "Run enabled plugin providers when loading streams."),
            isOn: Binding(
                get: { plugins.pluginsEnabled },
                set: { plugins.setPluginsEnabled($0) }
            )
        )

        PluginRepoEntryRow(isInstalling: plugins.isInstalling) { plugins.addRepository($0) }

        if let status = plugins.statusMessage {
            Text(status)
                .font(Theme.Font.caption)
                .foregroundStyle(status.hasPrefix("Installed") ? Theme.Palette.textSecondary : .red)
        }

        if plugins.repositories.isEmpty {
            Text("No plugin repositories installed yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            ForEach(plugins.repositories, id: \.manifestUrl) { repo in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(repo.name)
                            .font(Theme.Font.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if repo.isRefreshing {
                            ProgressView().scaleEffect(0.6)
                        }
                        Text(repo.scraperCount == 1 ? String(localized: "1 provider") : String(localized: "\(repo.scraperCount) providers"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Button(role: .destructive) {
                            plugins.removeRepository(repo)
                        } label: {
                            Image(systemName: "trash")
                                .font(Theme.Font.caption)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel(Text(String(
                            localized: "settings.plugins.removeRepository.accessibility",
                            defaultValue: "Remove \(repo.name)",
                            comment: "VoiceOver label of the trash button that removes a plugin repository; the argument is the repository name")))
                    }
                    if let error = repo.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.red)
                    }
                    ForEach(plugins.scrapers(in: repo), id: \.id) { scraper in
                        SettingsToggleRow(
                            title: scraper.name,
                            subtitle: scraper.description_.isEmpty
                                ? String(localized: "v\(scraper.version)")
                                : String(localized: "\(scraper.description_) \u{00B7} v\(scraper.version)"),
                            isOn: Binding(
                                get: { scraper.enabled },
                                set: { plugins.toggleScraper(scraper, $0) }
                            )
                        )
                    }
                }
            }
            SettingsActionRow(
                title: String(localized: "Refresh Plugins"),
                subtitle: String(localized: "Re-download provider code from every repository."),
                systemImage: "arrow.clockwise"
            ) {
                plugins.refreshAll()
            }
        }
    }
}

/// TMDB API key entry: a tvOS `TextField` (opens the full-screen keyboard, dismisses on commit) plus
/// a Save button. The shared repo trims the key and enables enrichment; we only guard against empty.
private struct TmdbKeyEntryRow: View {
    let onSave: (String) -> Void
    @State private var key = ""

    // Spec gap 14 / §6.6: no glass in Settings. The field and the button are two plain rows of
    // the pane's system `List` (a `Group`, so the List gives each its own row and focus platter).
    var body: some View {
        Group {
            TextField("TMDB API Key (v3 auth)", text: $key)
                .font(Theme.Font.body)

            Button {
                if !key.isEmpty { onSave(key) }
            } label: {
                Label("Save & Enable", systemImage: "checkmark")
                    .font(Theme.Font.body)
            }
            .disabled(key.isEmpty)
        }
    }
}

/// Manifest-URL entry for installing a plugin repository from the TV (mirrors the addon install
/// row; the shared repo normalizes the URL and appends /manifest.json).
private struct PluginRepoEntryRow: View {
    let isInstalling: Bool
    let onInstall: (String) -> Void
    @State private var url = ""

    // Same shape as `TmdbKeyEntryRow`: two plain List rows, no glass.
    var body: some View {
        Group {
            TextField("Repository manifest URL", text: $url)
                .font(Theme.Font.body)
                .textContentType(.URL)
                .autocorrectionDisabled()

            Button {
                if !url.isEmpty {
                    onInstall(url)
                    url = ""
                }
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Label("Install Repository", systemImage: "plus")
                        .font(Theme.Font.body)
                    Spacer(minLength: 0)
                    if isInstalling { ProgressView() }
                }
            }
            .disabled(isInstalling || url.isEmpty)
        }
    }
}
