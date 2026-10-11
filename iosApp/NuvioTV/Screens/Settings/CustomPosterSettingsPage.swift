import SwiftUI
import SharedCore

/// Settings > Appearance > Custom Posters: the URL pattern of a rating-poster style service and the
/// surfaces it applies to. Pushed by a `SettingsLinkRow`, so Back pops to the Appearance list.
///
/// Typing a URL with the tvOS keyboard is slow, so the footer points at Remote Setup (Advanced),
/// whose web page carries the same two controls. Both write the shared
/// `CustomPosterUrlRepository`, which syncs with the profile.
struct CustomPosterSettingsPage: View {
    @ObservedObject var model: SettingsViewModel
    @State private var draft = ""

    private var isOn: Bool { !model.customPosterPattern.isEmpty }
    private var draftIsSaved: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) == model.customPosterPattern
    }

    var body: some View {
        List {
            SettingsSection(
                title: String(localized: "Poster URL"),
                footer: String(localized: "Use {imdb_id}, {tmdb_id}, {id}, {type} or {shape} where the service expects them, for example https://example.com/key/{imdb_id}.jpg. A title the pattern can't be filled for keeps its own poster. You can also set this from a phone in Advanced > Remote Setup.")
            ) {
                TextField(String(localized: "https://example.com/{imdb_id}.jpg"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(SettingsRowFont.title)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text("Poster URL"))

                SettingsActionRow(
                    title: String(localized: "Save"),
                    subtitle: draftIsSaved ? "" : String(localized: "Apply this pattern to your posters"),
                    systemImage: "checkmark"
                ) {
                    model.setCustomPosterPattern(draft)
                    draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if isOn {
                    SettingsDestructiveRow(
                        title: String(localized: "Remove Custom Poster URL"),
                        systemImage: "xmark.circle"
                    ) {
                        draft = ""
                        model.setCustomPosterPattern("")
                    }
                }
            }

            if isOn {
                SettingsSection(title: String(localized: "Use On")) {
                    ForEach(CustomPosterSurface.allCases, id: \.rawValue) { surface in
                        SettingsToggleRow(
                            title: Self.title(for: surface),
                            isOn: Binding(
                                get: { model.customPosterSurfaces.contains(surface.rawValue) },
                                set: { model.setCustomPosterSurface(surface, enabled: $0) }
                            )
                        )
                    }
                }
            }
        }
        .navigationTitle(Text("Custom Posters"))
        .onAppear { draft = model.customPosterPattern }
    }

    private static func title(for surface: CustomPosterSurface) -> String {
        switch surface {
        case .home: return String(localized: "Home")
        case .continueWatching: return String(localized: "Continue Watching")
        case .collections: return String(localized: "Collections")
        case .library: return String(localized: "Library")
        case .search: return String(localized: "Search")
        case .details: return String(localized: "Details")
        }
    }
}
