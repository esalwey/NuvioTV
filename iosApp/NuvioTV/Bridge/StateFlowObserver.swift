import Combine
import Foundation
import SharedCore

/// Reusable SwiftUI bridge over a Kotlin `StateFlow`.
///
/// Wraps the shared `FlowWatcher` (Kotlin) and republishes each emission as a `@Published`
/// `value`, so any SwiftUI view can do `@StateObject var obs = StateFlowObserver(repo.uiState, initial:)`
/// and read `obs.value`. Emissions arrive on the main thread (the Kotlin side uses Dispatchers.Main).
///
/// `Value` is the concrete Kotlin UiState type as seen in Swift (e.g. `NetworkStatusUiState`).
/// The Kotlin callback hands us `Any?` (generics erase across the ObjC bridge), so we cast.
@MainActor
final class StateFlowObserver<Value: AnyObject>: ObservableObject {
    @Published private(set) var value: Value

    private var watcher: FlowWatcher?

    /// - Parameters:
    ///   - flow: the Kotlin `StateFlow` (exposed in Swift as `Kotlinx_coroutines_coreStateFlow`).
    ///   - initial: the value to show until the first emission arrives.
    init(_ flow: Kotlinx_coroutines_coreStateFlow, initial: Value) {
        self.value = initial
        self.watcher = FlowWatcherKt.watch(flow) { [weak self] emitted in
            guard let self, let typed = emitted as? Value else { return }
            self.value = typed
        }
    }

    deinit {
        watcher?.cancel()
    }
}
