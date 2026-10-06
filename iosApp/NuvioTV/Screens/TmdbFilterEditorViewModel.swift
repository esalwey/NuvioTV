import Combine
import Foundation
import SharedCore

/// Backs `TmdbFilterEditorView`: a Swift mirror of the shared `TmdbSourceFilterEditor` state
/// machine (`TmdbSourceFilterEditor.uiState`, `nil` = not editing). All edits go straight to the
/// Kotlin singleton (`setField` / `toggleId` / `setSortBy` / `clearFilters` / `save` / `cancel`);
/// this object only re-publishes the emitted `TmdbSourceFilterEditorState` in SwiftUI-friendly
/// shapes. One editor session at a time (the shared object is a singleton keyed by `begin`).
@MainActor
final class TmdbFilterEditorViewModel: ObservableObject {
    /// A live TMDB genre (id + TMDB-localized name) from the shared `loadGenres()`.
    struct Genre: Identifiable, Equatable {
        let id: Int
        let name: String
    }

    /// `begin()` returned false — the collection / folder / source vanished or isn't a tmdb
    /// source. The view shows a message plus a Cancel button (focus anchor).
    @Published private(set) var loadFailed = false
    @Published private(set) var sourceTitle = ""
    @Published private(set) var mediaTypeIsTv = false
    /// `TmdbCollectionSourceType.name` ("DISCOVER" / "COMPANY" / "NETWORK" / …).
    @Published private(set) var tmdbSourceTypeName = ""
    /// `TmdbCollectionSort.value` (e.g. "popularity.desc").
    @Published private(set) var sortBy = ""
    /// Draft text per field, keyed by `TmdbFilterField.name` ("WITH_GENRES", …); "" = unset.
    @Published private(set) var fields: [String: String] = [:]
    @Published private(set) var availableGenres: [Genre] = []
    @Published private(set) var isLoadingGenres = false
    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    /// `TmdbFilterField.name`s that failed the last `save()` validation.
    @Published private(set) var invalidFieldNames: Set<String> = []
    @Published private(set) var saveFailed = false
    @Published private(set) var saved = false

    private let target: FolderDetailViewModel.EditableSource
    private var watcher: FlowWatcher?

    init(target: FolderDetailViewModel.EditableSource) {
        self.target = target
        sourceTitle = target.title
        // Watch first so the state `begin()` publishes synchronously is the first emission.
        watcher = FlowWatcherKt.watch(TmdbSourceFilterEditor.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            // `nil` = not editing (after `cancel()`); keep the last mirror so the cover doesn't
            // blank out mid-dismiss animation.
            guard let state = emitted as? TmdbSourceFilterEditorState else { return }
            self.apply(state)
        }
        let began = TmdbSourceFilterEditor.shared.begin(
            collectionId: target.collectionId,
            folderId: target.folderId,
            sourceIndex: Int32(target.sourceIndex)
        )
        if !began {
            loadFailed = true
        }
    }

    deinit {
        watcher?.cancel()
    }

    private func apply(_ state: TmdbSourceFilterEditorState) {
        sourceTitle = state.sourceTitle
        mediaTypeIsTv = state.mediaType == .tv
        tmdbSourceTypeName = state.tmdbSourceType.name
        sortBy = state.sortBy
        var mirrored: [String: String] = [:]
        for (field, value) in state.fields {
            mirrored[field.name] = value
        }
        fields = mirrored
        availableGenres = state.availableGenres.map { Genre(id: Int($0.id), name: $0.name) }
        isLoadingGenres = state.isLoadingGenres
        isDirty = state.isDirty
        isSaving = state.isSaving
        invalidFieldNames = Set(state.invalidFields.map(\.name))
        saveFailed = state.saveFailed
        saved = state.saved
    }

    // MARK: - Reads

    /// Raw draft text for `field` ("" when unset).
    func value(_ field: TmdbFilterField) -> String {
        fields[field.name] ?? ""
    }

    /// Individual ids in `field` — split on `,` and `|`, trimmed, blanks dropped (same rule as
    /// the shared `TmdbSourceFilterEditorState.ids`).
    func ids(_ field: TmdbFilterField) -> [String] {
        value(field)
            .split(whereSeparator: { $0 == "," || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// True when `id` is one of `ids(field)` — drives the quick chips' selected state. For the
    /// single-valued code fields (language / country / region) this is a plain equality check.
    func contains(_ field: TmdbFilterField, _ id: String) -> Bool {
        if field.isSingleValued {
            return value(field).trimmingCharacters(in: .whitespacesAndNewlines) == id
        }
        return ids(field).contains(id)
    }

    func isInvalid(_ field: TmdbFilterField) -> Bool {
        invalidFieldNames.contains(field.name)
    }

    // MARK: - Edits (all forwarded to the shared editor; mirrors update on the next emission)

    func setField(_ field: TmdbFilterField, _ value: String) {
        TmdbSourceFilterEditor.shared.setField(field: field, value: value)
    }

    func toggleId(_ field: TmdbFilterField, _ id: String) {
        TmdbSourceFilterEditor.shared.toggleId(field: field, id: id)
    }

    func setSortBy(_ value: String) {
        TmdbSourceFilterEditor.shared.setSortBy(value: value)
    }

    func clearFilters() {
        TmdbSourceFilterEditor.shared.clearFilters()
    }

    /// Validates + persists. False → check `invalidFieldNames` (validation) or `saveFailed`
    /// (exception); true → the shared state stays alive with `saved == true`, so the caller
    /// should `cancel()` and dismiss.
    @discardableResult
    func save() -> Bool {
        TmdbSourceFilterEditor.shared.save()
    }

    /// Drops the shared editor state (idempotent — safe from both the buttons and onDisappear).
    func cancel() {
        TmdbSourceFilterEditor.shared.cancel()
    }
}
