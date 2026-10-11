import SwiftUI

/// Results of the Settings search field, shown in place of the category split while a query is
/// typed (the system `.searchable` field on `SettingsView` owns the keyboard, dictation and the
/// iPhone keyboard). Each result is a plain list row; choosing one hands the entry back so
/// Settings can show its category and scroll to its section.
struct SettingsSearchResultsView: View {
    let query: String
    let developerUnlocked: Bool
    let onSelect: (SettingsSearchEntry) -> Void

    /// Must be read from a view INSIDE the `.searchable` scope, which is why this is its own view.
    @Environment(\.dismissSearch) private var dismissSearch

    private var results: [SettingsSearchEntry] {
        SettingsSearchIndex.search(query, in: SettingsSearchIndex.entries, developerUnlocked: developerUnlocked)
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
                            dismissSearch()
                            onSelect(entry)
                        }
                    }
                }
            }
            .accessibilityIdentifier("settings_search_results")
        }
    }
}
