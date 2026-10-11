import Combine
import SwiftUI
import SharedCore

/// Add to Lists: a checklist of every list a title can be on (the Nuvio library and the lists of
/// each connected Trakt / Simkl account), reached from the Detail page and from a poster's
/// long-press menu. Presented full screen like the other pickers; Back closes it without saving.
///
/// A system `List` with one section per account and a checkmark on the lists the title is on. A
/// Simkl status is a choice of one, which the shared `LibraryMembershipEditor` enforces.
struct AddToListsSheet: View {
    @StateObject private var model: AddToListsModel
    @Environment(\.dismiss) private var dismiss

    init(item: NuvioLibraryItem) {
        _model = StateObject(wrappedValue: AddToListsModel(item: item))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.itemTitle)
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .task { model.loadIfNeeded() }
        .onChange(of: model.isFinished) { _, finished in
            if finished { dismiss() }
        }
        .membershipRemovalAlert($model.removalPrompt) { prompt in
            model.confirmRemoval(prompt)
        }
        .alert(
            model.notice.map(MembershipText.rewriteTitle) ?? "",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.finishAfterNotice() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice.map(MembershipText.rewriteMessage) ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn\u{2019}t Load Your Lists", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check the connection and try again.")
            } actions: {
                Button("Try Again") { model.load() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        case .ready:
            checklist
        }
    }

    private var checklist: some View {
        List {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.options, id: \.key) { option in
                        Button {
                            model.toggle(option)
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                Text(option.title)
                                    .font(Theme.Font.body)
                                Spacer(minLength: 0)
                                if option.isSelected {
                                    Image(systemName: "checkmark")
                                        .font(Theme.Font.body.weight(.semibold))
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityAddTraits(option.isSelected ? .isSelected : [])
                    }
                } header: {
                    if let title = group.title {
                        Text(title)
                            .font(SettingsRowFont.sectionHeader)
                    }
                }
            }

            if let failure = model.saveFailure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
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
                        if model.isSaving { ProgressView() }
                    }
                }
                .disabled(!model.canSave)
            }
        }
    }
}

// MARK: - Model

/// Loads a title's list membership through the shared `LibraryMembership`, tracks the user's
/// edits, and writes them back. Everything provider-specific (which lists exist, one-of-many
/// Simkl statuses, the "this also clears your history" confirmation) is decided in Kotlin.
@MainActor
final class AddToListsModel: ObservableObject {
    enum Phase { case loading, ready, failed }

    struct ListGroup: Identifiable {
        let id: String
        let title: String?
        let options: [LibraryMembershipOption]
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var groups: [ListGroup] = []
    @Published private(set) var isSaving = false
    @Published private(set) var canSave = false
    @Published private(set) var saveFailure: String?
    @Published private(set) var isFinished = false
    /// A provider that would also clear watched history or a rating is waiting for a yes.
    @Published var removalPrompt: LibraryMembershipOutcome?
    /// The write succeeded but a provider used another list than the one asked for.
    @Published private(set) var notice: LibraryMembershipOutcome?

    let itemTitle: String
    private let item: NuvioLibraryItem
    private var editor: LibraryMembershipEditor?

    init(item: NuvioLibraryItem) {
        self.item = item
        self.itemTitle = item.name
    }

    func loadIfNeeded() {
        guard editor == nil, phase == .loading else { return }
        load()
    }

    func load() {
        phase = .loading
        saveFailure = nil
        LibraryMembership.shared.editor(item: item) { [weak self] editor, error in
            Task { @MainActor in
                guard let self else { return }
                guard let editor, error == nil else {
                    self.phase = .failed
                    return
                }
                self.editor = editor
                self.refresh()
                self.phase = .ready
            }
        }
    }

    func toggle(_ option: LibraryMembershipOption) {
        guard !isSaving, let editor else { return }
        editor.toggle(key: option.key)
        saveFailure = nil
        refresh()
    }

    func save() {
        guard let editor, !isSaving, canSave else { return }
        isSaving = true
        saveFailure = nil
        editor.save { [weak self] outcome, error in
            Task { @MainActor in self?.handle(outcome, error) }
        }
    }

    func confirmRemoval(_ prompt: LibraryMembershipOutcome) {
        removalPrompt = nil
        guard !isSaving else { return }
        isSaving = true
        prompt.confirmRemoval { [weak self] outcome, error in
            Task { @MainActor in self?.handle(outcome, error) }
        }
    }

    /// The user read the "placed in another list" notice: the sheet is done.
    func finishAfterNotice() {
        notice = nil
        isFinished = true
    }

    private func handle(_ outcome: LibraryMembershipOutcome?, _ error: Error?) {
        isSaving = false
        guard error == nil, let outcome else {
            saveFailure = String(localized: "Couldn\u{2019}t update your lists. Check the connection and try again.")
            return
        }
        if outcome.requiresConfirmation {
            removalPrompt = outcome
        } else if !outcome.rewrites.isEmpty {
            notice = outcome
        } else {
            isFinished = true
        }
    }

    /// Rebuilds the rows from the shared editor, one section per account (the Nuvio library, which
    /// has no account name, comes first and carries no header).
    private func refresh() {
        guard let editor else { return }
        var result: [ListGroup] = []
        for option in editor.options() {
            if let last = result.last, last.title == option.groupTitle {
                result[result.count - 1] = ListGroup(id: last.id, title: last.title, options: last.options + [option])
            } else {
                result.append(ListGroup(id: option.groupTitle ?? "local", title: option.groupTitle, options: [option]))
            }
        }
        groups = result
        canSave = editor.hasChanges
    }
}

// MARK: - Wording

enum MembershipText {
    static func removalTitle(_ outcome: LibraryMembershipOutcome) -> String {
        let providers = outcome.providerNames.joined(separator: ", ")
        return String(localized: "Remove from \(providers)?")
    }

    static func removalMessage(_ outcome: LibraryMembershipOutcome) -> String {
        let providers = outcome.providerNames.joined(separator: ", ")
        let impact: String
        if outcome.removalImpact == LibraryRemovalImpact.watchedHistory {
            impact = String(localized: "watched history")
        } else if outcome.removalImpact == LibraryRemovalImpact.rating {
            impact = String(localized: "rating")
        } else {
            impact = String(localized: "watched history and rating")
        }
        let title = outcome.itemTitle
        return String(localized: "Removing \u{201C}\(title)\u{201D} from \(providers) will also clear its \(impact) there. This can\u{2019}t be undone.")
    }

    static func rewriteTitle(_ outcome: LibraryMembershipOutcome) -> String {
        String(localized: "Added to a Different List")
    }

    static func rewriteMessage(_ outcome: LibraryMembershipOutcome) -> String {
        guard let rewrite = outcome.rewrites.first else { return "" }
        let provider = rewrite.providerName
        let resolved = rewrite.resolvedTitle
        let requested = rewrite.requestedTitle
        return String(localized: "\(provider) placed this title in \(resolved) instead of \(requested).")
    }
}

extension View {
    /// The confirmation a provider asks for before a removal also clears watched history or a
    /// rating (Simkl). `confirm` runs the write again with the user's agreement.
    func membershipRemovalAlert(
        _ prompt: Binding<LibraryMembershipOutcome?>,
        confirm: @escaping (LibraryMembershipOutcome) -> Void
    ) -> some View {
        alert(
            prompt.wrappedValue.map(MembershipText.removalTitle) ?? "",
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { if !$0 { prompt.wrappedValue = nil } }
            ),
            presenting: prompt.wrappedValue
        ) { outcome in
            Button("Remove Anyway", role: .destructive) { confirm(outcome) }
            Button("Cancel", role: .cancel) {}
        } message: { outcome in
            Text(MembershipText.removalMessage(outcome))
        }
    }
}
