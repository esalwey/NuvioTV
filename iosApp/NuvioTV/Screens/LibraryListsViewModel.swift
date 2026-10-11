import Combine
import Foundation
import SharedCore

/// Drives "Manage Lists" for the library on screen: create, rename, change privacy, delete and
/// reorder the user's own lists (Trakt personal lists).
///
/// The shared `LibraryListManagementController` is the state machine (which dialog is open, the
/// draft, pending and error states, and "the profile or source changed, drop the draft"); this
/// class mirrors its state for SwiftUI and forwards input. `info` is nil whenever the library
/// being shown has no lists of its own to manage (the local library, Simkl), which is what hides
/// the Manage Lists button.
@MainActor
final class LibraryListsViewModel: ObservableObject {
    /// The user's own lists in provider order, plus what the provider lets them do with them.
    @Published private(set) var info: LibraryListManagementInfo?
    /// The open dialog, or nil. `mode` is manage (the list of lists), edit (create or edit one
    /// list) or delete (a confirmed delete in flight, or failed).
    @Published private(set) var dialog: LibraryListDialogState?
    /// A reorder that the provider refused (the shared repository already rolled the order back).
    @Published var reorderFailure: String?

    var canManage: Bool { info != nil }
    var lists: [TrackingLibraryTab] { info?.lists ?? [] }

    private let controller = LibraryListsBridge.shared.makeController()
    private var infoWatcher: FlowWatcher?
    private var dialogWatcher: FlowWatcher?

    func start() {
        guard infoWatcher == nil else { return }
        LibraryRepository.shared.ensureLoaded()
        infoWatcher = FlowWatcherKt.watch(LibraryListsBridge.shared.managementInfo) { [weak self] emitted in
            guard let self else { return }
            self.info = emitted as? LibraryListManagementInfo
            // A profile or source switch under an open dialog: drop it rather than edit the wrong library.
            self.controller.reconcileContext()
        }
        dialogWatcher = FlowWatcherKt.watch(controller.state) { [weak self] emitted in
            self?.dialog = emitted as? LibraryListDialogState
        }
    }

    func stop() {
        infoWatcher?.cancel()
        infoWatcher = nil
        dialogWatcher?.cancel()
        dialogWatcher = nil
    }

    // MARK: - Dialog navigation

    /// Opens the list of lists. Also the way back from the editor.
    func openManager() { controller.open() }

    func dismiss() { controller.dismiss() }

    func create() { controller.create() }

    func edit(_ tab: TrackingLibraryTab) { controller.edit(tab: tab) }

    // MARK: - Draft

    func setName(_ value: String) { controller.setName(value: value) }

    func setDescription(_ value: String) { controller.setDescription(value: value) }

    /// `apiValue` is the privacy's wire value ("private", "link", "friends", "public").
    func setPrivacy(apiValue: String) {
        guard let option = info?.privacyOptions.first(where: { $0.apiValue == apiValue }) else { return }
        controller.setPrivacy(value: option)
    }

    /// Saves the open draft. A failure stays in `dialog.error` and keeps the draft for a retry.
    func save() {
        controller.submit { _ in }
    }

    /// Deletes `tab` (the caller already asked the user to confirm). A failure leaves the dialog
    /// in delete mode with `error` set; `dismissDeleteFailure()` returns to the list of lists.
    func delete(_ tab: TrackingLibraryTab) {
        controller.requestDelete(tab: tab)
        controller.submit { _ in }
    }

    func dismissDeleteFailure() { controller.open() }

    // MARK: - Reorder

    func canMove(_ tab: TrackingLibraryTab, by offset: Int) -> Bool {
        guard info?.supportsReordering == true,
              let index = lists.firstIndex(where: { $0.key == tab.key }) else { return false }
        return lists.indices.contains(index + offset)
    }

    /// Moves `tab` one place up (-1) or down (+1). The shared repository reorders its cached
    /// lists at once, so the rows move before Trakt has answered.
    func move(_ tab: TrackingLibraryTab, by offset: Int) {
        guard canMove(tab, by: offset), let index = lists.firstIndex(where: { $0.key == tab.key }) else { return }
        var keys = lists.map { $0.key }
        keys.swapAt(index, index + offset)
        LibraryListsBridge.shared.reorder(orderedKeys: keys) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.reorderFailure = String(localized: "Couldn't change the order of your lists. Check the connection and try again.")
            }
        }
    }

    deinit {
        infoWatcher?.cancel()
        dialogWatcher?.cancel()
    }
}
