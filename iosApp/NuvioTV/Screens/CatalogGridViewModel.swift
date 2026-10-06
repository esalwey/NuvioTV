import Combine
import Foundation
import SharedCore

// MARK: - Catalog grid probe (BUG-47 / UX-13)

/// Runtime knob for the H1/H2/H3 hardening around the "See All" grid (this file and
/// `expansionChanged` in BrowseComponents.swift). Every probe line shares the `[CatalogGridProbe]`
/// prefix, so one device walk produces one greppable stream:
///
///     defaults write com.nuvio.media.NuvioTV debug.catalogGridProbe -bool YES
///
/// Deliberately NOT `#if DEBUG`, matching `HomeGeometryProbe` (BrowseComponents.swift) — there is no
/// automated input path to the physical Apple TV, so a device pass reproducing BUG-47 may well be a
/// release-configuration sideload, and the console is the only diagnostic that comes back.
enum CatalogGridProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.catalogGridProbe")

    static func log(_ message: String) {
        NSLog("[CatalogGridProbe] %@", message)
    }
}

/// Backs the full-grid "See All" screen. Observes the shared `CatalogRepository` (a paginated,
/// reactive catalog loader already in `SharedCore`): loads the target's first page on `start`,
/// paginates via `loadMore()` as the grid nears its end, and clears on `stop`.
///
/// `CatalogRepository` is a singleton and holds one active request at a time; only one grid is on
/// screen at once (pushed onto the Home/Search `NavigationStack`), so a single instance is fine.
@MainActor
final class CatalogGridViewModel: ObservableObject {
    @Published private(set) var items: [MetaPreview] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var errorMessage: String?

    private var watcher: FlowWatcher?
    private let target: any CatalogTarget

    /// H2 hardening (BUG-47): `FlowWatcher.cancel()` tears down the Kotlin collector's coroutine
    /// scope, but that cancellation is cooperative — a resume already queued on the main run loop
    /// can still deliver one more value AFTER `stop()` (and `cancel()`) have returned. On tvOS 27
    /// that trailing emission landed mid-pop, driving `@Published` mutations into a view that was
    /// already being torn down and terminating the process. This flag makes the watcher callback
    /// itself inert the instant `stop()` runs, closing the window `cancel()` alone can't close.
    private var stopped = false

    init(target: any CatalogTarget) {
        self.target = target
    }

    func start() {
        guard watcher == nil else { return }
        stopped = false
        if CatalogGridProbe.enabled { CatalogGridProbe.log("start(target:) \(target)") }
        watcher = FlowWatcherKt.watch(CatalogRepository.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            guard !self.stopped else {
                if CatalogGridProbe.enabled { CatalogGridProbe.log("emission after stop") }
                return
            }
            guard let state = emitted as? CatalogUiState else { return }
            self.items = state.items
            self.isLoading = state.isLoading
            self.canLoadMore = state.canLoadMore
            // Nullable Kotlin String may bridge as non-optional in this framework — normalize empty to nil.
            let message: String? = state.errorMessage
            self.errorMessage = (message?.isEmpty == false) ? message : nil
        }
        CatalogRepository.shared.load(target: target, force: false)
    }

    /// Infinite-scroll trigger: called from each grid cell's `onAppear`. Fires `loadMore()` once the
    /// user nears the end of the loaded items, and no-ops if already loading or fully paged.
    func itemAppeared(at index: Int) {
        guard canLoadMore, !isLoading else { return }
        if index >= items.count - 8 {
            CatalogRepository.shared.loadMore()
        }
    }

    func stop() {
        // H2: flip first — see the `stopped` doc comment. Anything the watcher callback delivers
        // after this point (already queued on the main run loop before `cancel()` lands) is a
        // no-op instead of a `@Published` write into a view mid-pop.
        stopped = true
        if CatalogGridProbe.enabled { CatalogGridProbe.log("stop()") }
        watcher?.cancel()
        watcher = nil
        // H1 (BUG-47/UX-13): `clear()` wipes the repository's items + scroll positions along with
        // cancelling the fetch, which is the full-teardown variant meant for sign-out. A grid pop
        // only needs the in-flight fetch cancelled — `detach()` does that without disturbing state,
        // so `load()`'s same-target early-return keeps the grid's items/scroll position intact when
        // the user comes back (UX-13), and so a stray in-flight completion after pop can't touch
        // repository state a different screen may already be reading.
        if CatalogGridProbe.enabled { CatalogGridProbe.log("CatalogRepository.detach()") }
        CatalogRepository.shared.detach()
    }

    deinit { watcher?.cancel() }
}
