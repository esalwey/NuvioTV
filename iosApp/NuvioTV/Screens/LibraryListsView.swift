import SwiftUI
import SharedCore

/// "Manage Lists": the user's own lists (Trakt personal lists) in a system `List`, the way a
/// Settings pane lists things. A row opens the editor, a long press offers Move Up / Move Down /
/// Delete (spec 5.6), "New List" opens a blank editor. Presented full screen from the Library;
/// Back returns from the editor to the list of lists, then closes.
///
/// Which screen shows, the draft, the pending state and the error all come from the shared
/// `LibraryListManagementController` through `LibraryListsViewModel`.
struct LibraryListsSheet: View {
    @ObservedObject var model: LibraryListsViewModel
    @State private var pendingDelete: TrackingLibraryTab?

    var body: some View {
        NavigationStack {
            Group {
                if model.isEditingList, let state = model.dialog {
                    LibraryListEditorView(model: model, state: state) { tab in
                        pendingDelete = tab
                    }
                    // A new editor (another list, or New List) starts from its own values; a failed
                    // save keeps the same instance, so the typed text survives for a retry.
                    .id(state.instance)
                } else {
                    managerList
                }
            }
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .onExitCommand {
            if model.isEditingList {
                model.openManager()
            } else {
                model.dismiss()
            }
        }
        .alert(
            String(localized: "Delete This List?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { tab in
            Button("Delete", role: .destructive) { model.delete(tab) }
            Button("Cancel", role: .cancel) {}
        } message: { tab in
            Text("\u{201C}\(tab.title)\u{201D} will be deleted from \(model.info?.providerName ?? ""). This can\u{2019}t be undone.")
        }
        .alert(
            String(localized: "Couldn\u{2019}t Delete the List"),
            isPresented: Binding(
                get: { model.deleteFailed },
                set: { if !$0 { model.dismissDeleteFailure() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.dialog?.error?.message ?? String(localized: "Check the connection and try again."))
        }
        .alert(
            String(localized: "Couldn\u{2019}t Reorder Your Lists"),
            isPresented: Binding(
                get: { model.reorderFailure != nil },
                set: { if !$0 { model.reorderFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.reorderFailure ?? "")
        }
    }

    // MARK: - The list of lists

    private var managerList: some View {
        List {
            Section {
                SettingsActionRow(title: String(localized: "New List"), systemImage: "plus") {
                    model.create()
                }
            } footer: {
                if model.lists.isEmpty {
                    Text("You don\u{2019}t have any lists yet. Create one to sort your titles.")
                        .font(SettingsRowFont.sectionHeader)
                }
            }

            if !model.lists.isEmpty {
                Section {
                    ForEach(model.lists, id: \.key) { tab in
                        listRow(tab)
                    }
                } header: {
                    Text(model.info?.providerName ?? "")
                        .font(SettingsRowFont.sectionHeader)
                } footer: {
                    if model.info?.supportsReordering == true, model.lists.count > 1 {
                        Text("Press and hold a list to move it or delete it.")
                            .font(SettingsRowFont.sectionHeader)
                    }
                }
                .disabled(isDeleting)
            }
        }
        .navigationTitle(String(localized: "Manage Lists"))
    }

    private var isDeleting: Bool {
        model.isDeletePending
    }

    private func listRow(_ tab: TrackingLibraryTab) -> some View {
        Button {
            model.edit(tab)
        } label: {
            LabeledContent {
                if let privacy = tab.privacy {
                    Text(ListPrivacyText.title(privacy.apiValue))
                        .font(SettingsRowFont.title)
                        .settingsAccentTint()
                }
            } label: {
                SettingsRowLabel(
                    title: tab.title,
                    subtitle: Self.nonEmpty(tab.description_),
                    systemImage: "list.bullet"
                )
            }
        }
        .contextMenu {
            Button {
                model.edit(tab)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            if model.canMove(tab, by: -1) {
                Button {
                    model.move(tab, by: -1)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
            }
            if model.canMove(tab, by: 1) {
                Button {
                    model.move(tab, by: 1)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
            }
            Button(role: .destructive) {
                pendingDelete = tab
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Editor

/// Create or edit one list: name, an optional description and who can see it. The text lives in
/// local state (a tvOS `TextField` edits through the system keyboard) and is mirrored into the
/// shared draft as it changes; Save submits the shared draft.
private struct LibraryListEditorView: View {
    @ObservedObject var model: LibraryListsViewModel
    let state: LibraryListDialogState
    let onDelete: (TrackingLibraryTab) -> Void

    @State private var name: String
    @State private var details: String
    @State private var privacy: String

    init(
        model: LibraryListsViewModel,
        state: LibraryListDialogState,
        onDelete: @escaping (TrackingLibraryTab) -> Void
    ) {
        self.model = model
        self.state = state
        self.onDelete = onDelete
        _name = State(initialValue: state.name)
        _details = State(initialValue: state.description_)
        _privacy = State(initialValue: state.privacy.apiValue)
    }

    private var existingList: TrackingLibraryTab? {
        guard let key = state.key else { return nil }
        return model.lists.first { $0.key == key }
    }

    private var canSave: Bool {
        !state.isPending && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var privacyOptions: [String] {
        let options = model.info?.privacyOptions.map { $0.apiValue } ?? []
        return options.isEmpty ? [privacy] : options
    }

    var body: some View {
        List {
            Section {
                TextField(String(localized: "List Name"), text: $name)
                    .font(Theme.Font.body)
                    .disabled(state.isPending)
                    .onChange(of: name) { _, value in model.setName(value) }
                if model.info?.supportsDescription == true {
                    TextField(String(localized: "Description (Optional)"), text: $details)
                        .font(Theme.Font.body)
                        .disabled(state.isPending)
                        .onChange(of: details) { _, value in model.setDescription(value) }
                }
            }

            Section {
                SettingsPickerRow(
                    title: String(localized: "Who Can See This List"),
                    selection: $privacy,
                    options: privacyOptions,
                    label: ListPrivacyText.title
                )
                .disabled(state.isPending)
                .onChange(of: privacy) { _, value in model.setPrivacy(apiValue: value) }
            } footer: {
                Text(ListPrivacyText.explanation(privacy))
                    .font(SettingsRowFont.sectionHeader)
            }

            if let error = state.error {
                Section {
                    Label(
                        error.message ?? String(localized: "Couldn\u{2019}t save the list. Check the connection and try again."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    model.save()
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        Label("Save", systemImage: "checkmark")
                            .font(Theme.Font.body)
                        Spacer(minLength: 0)
                        if state.isPending { ProgressView() }
                    }
                }
                .disabled(!canSave)

                if let list = existingList {
                    SettingsDestructiveRow(title: String(localized: "Delete List"), systemImage: "trash") {
                        onDelete(list)
                    }
                    .disabled(state.isPending)
                }
            }
        }
        .navigationTitle(state.key == nil ? String(localized: "New List") : String(localized: "Edit List"))
    }
}

// MARK: - Privacy wording

/// Who can see a list, in the words Trakt uses. Keyed by the shared privacy's wire value.
enum ListPrivacyText {
    static func title(_ apiValue: String) -> String {
        switch apiValue {
        case "link": return String(localized: "Link")
        case "friends": return String(localized: "Friends")
        case "public": return String(localized: "Public")
        default: return String(localized: "Private")
        }
    }

    static func explanation(_ apiValue: String) -> String {
        switch apiValue {
        case "link": return String(localized: "Anyone with the link can see this list.")
        case "friends": return String(localized: "Only your friends can see this list.")
        case "public": return String(localized: "Anyone can see this list.")
        default: return String(localized: "Only you can see this list.")
        }
    }
}
