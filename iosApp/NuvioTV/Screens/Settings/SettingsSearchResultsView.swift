import SwiftUI

/// The dedicated Settings search page, pushed from the "Search Settings" row at the top of the
/// category list. It is the ONLY view in Settings that carries `.searchable`: attaching the field
/// to the split itself reserved a tall empty header band on tvOS that stayed visible while the
/// panes scrolled and with the sidebar. Here the field is the page's own, like the Search tab.
/// Choosing a result hands the entry back (Settings selects its category and scrolls to its
/// section) and pops the page.
struct SettingsSearchScreen: View {
    let developerUnlocked: Bool
    let onSelect: (SettingsSearchEntry) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var prompt: String {
        String(
            localized: "settings.search.prompt",
            defaultValue: "Search Settings",
            comment: "Placeholder in the Settings search field"
        )
    }

    var body: some View {
        SettingsSearchResultsView(query: query, developerUnlocked: developerUnlocked) { entry in
            onSelect(entry)
            dismiss()
        }
        .searchable(text: $query, prompt: Text(prompt))
        .navigationTitle(prompt)
        .background(Theme.Palette.background.ignoresSafeArea())
    }
}

/// Results of the Settings search field. While the query is empty the whole index is listed, so
/// the page can also be browsed with the remote before typing anything. Each result is a plain
/// list row; choosing one hands the entry back.
struct SettingsSearchResultsView: View {
    let query: String
    let developerUnlocked: Bool
    let onSelect: (SettingsSearchEntry) -> Void

    private var results: [SettingsSearchEntry] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SettingsSearchIndex.entries.filter { !$0.developerOnly || developerUnlocked }
        }
        return SettingsSearchIndex.search(query, in: SettingsSearchIndex.entries, developerUnlocked: developerUnlocked)
    }

    var body: some View {
        let found = results
        if found.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                SettingsSection(nil) {
                    ForEach(found) { entry in
                        SettingsActionRow(
                            title: entry.title,
                            subtitle: entry.location,
                            systemImage: entry.category.icon
                        ) {
                            onSelect(entry)
                        }
                    }
                }
            }
            .accessibilityIdentifier("settings_search_results")
        }
    }
}
