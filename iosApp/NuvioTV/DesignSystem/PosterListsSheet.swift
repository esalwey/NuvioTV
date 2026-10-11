import SharedCore
import SwiftUI

/// Backs `PosterListsSheet`: the lists of the connected tracking providers (Trakt watchlist and
/// personal lists) a title can be put on, and the title's membership of each.
///
/// The Kotlin calls are `@Throws` suspend functions, so a network failure arrives here as an
/// `NSError` in the completion handler instead of ending the process.
@MainActor
final class PosterListsModel: ObservableObject {
    @Published private(set) var choices: [LibraryListChoice] = []
    @Published private(set) var isLoading = true
    /// The list whose change is being sent; further presses are ignored until it lands.
    @Published private(set) var pendingKey: String?
    @Published private(set) var errorMessage: String?

    private let item: LibraryItem

    init(preview: MetaPreview) {
        item = preview.toLibraryItem(savedAtEpochMs: 0)
    }

    func load() {
        isLoading = true
        errorMessage = nil
        LibraryListActions.shared.choices(item: item) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.isLoading = false
                if let result {
                    self.choices = result
                } else {
                    self.errorMessage = error?.localizedDescription
                        ?? String(localized: "Couldn't load your lists.")
                }
            }
        }
    }

    func toggle(_ key: String) {
        guard pendingKey == nil else { return }
        pendingKey = key
        errorMessage = nil
        LibraryListActions.shared.toggle(item: item, key: key) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.pendingKey = nil
                if let result {
                    self.choices = result
                } else {
                    self.errorMessage = error?.localizedDescription
                        ?? String(localized: "Couldn't update your lists.")
                }
            }
        }
    }
}

/// F13 follow-up: "Lists" from the poster long-press menu. One system `Toggle` per list, applied as
/// it is switched (no Save step), the way a tvOS settings list behaves. Back dismisses the sheet.
struct PosterListsSheet: View {
    let preview: MetaPreview
    @StateObject private var model: PosterListsModel

    init(preview: MetaPreview) {
        self.preview = preview
        _model = StateObject(wrappedValue: PosterListsModel(preview: preview))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.isLoading {
                        HStack(spacing: Theme.Spacing.md) {
                            ProgressView()
                            Text("Loading your lists\u{2026}")
                                .foregroundStyle(.secondary)
                        }
                    } else if model.choices.isEmpty {
                        Text("No lists available for this title.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.choices, id: \.key) { choice in
                            Toggle(isOn: Binding(
                                get: { choice.isMember },
                                set: { _ in model.toggle(choice.key) }
                            )) {
                                Text(verbatim: choice.title)
                            }
                        }
                    }
                } header: {
                    Text(verbatim: preview.name)
                } footer: {
                    if let message = model.errorMessage {
                        Text(verbatim: message)
                    }
                }

                if model.errorMessage != nil, model.choices.isEmpty, !model.isLoading {
                    Section {
                        Button("Try Again") { model.load() }
                    }
                }
            }
            .navigationTitle(Text("Lists"))
        }
        .task { model.load() }
    }
}
