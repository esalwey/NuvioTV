import Combine
import SwiftUI
import SharedCore

/// Resolved poster-card styling for the tvOS UI, derived from the shared `PosterCardStyleRepository`
/// (which stores phone-scale dp and syncs across devices). Widths are scaled to tvOS points so the
/// same synced setting looks right on both platforms; corner radius is used directly as points
/// (default 12 == the previous fixed look).
struct PosterStyle: Equatable {
    var width: CGFloat = Theme.Size.posterWidth
    var height: CGFloat = Theme.Size.posterHeight
    var cornerRadius: CGFloat = Theme.Radius.card
    var showTitle: Bool = true
    var landscapeCatalogRows: Bool = false

    static let `default` = PosterStyle()

    /// tvOS points per stored dp (default width dp 126 → 220 pt).
    private static let dpToPoint = Theme.Size.posterWidth / 126.0

    init() {}

    init(from state: PosterCardStyleUiState) {
        let scaledWidth = CGFloat(state.widthDp) * PosterStyle.dpToPoint
        width = scaledWidth
        height = scaledWidth * 1.5 // 2:3 portrait — matches shared heightDp = widthDp * 3 / 2
        cornerRadius = CGFloat(state.cornerRadiusDp)
        showTitle = !state.hideLabelsEnabled
        landscapeCatalogRows = state.catalogLandscapeModeEnabled
    }
}

private struct PosterStyleKey: EnvironmentKey {
    static let defaultValue = PosterStyle.default
}

extension EnvironmentValues {
    var posterStyle: PosterStyle {
        get { self[PosterStyleKey.self] }
        set { self[PosterStyleKey.self] = newValue }
    }
}

/// Observes the shared `PosterCardStyleRepository` and republishes a resolved `PosterStyle` for the
/// environment. Owned at the app root and injected via `.environment(\.posterStyle,)`; profile-scoped
/// (the repo reloads on profile switch through the lifecycle coordinator).
@MainActor
final class PosterStyleModel: ObservableObject {
    @Published private(set) var style = PosterStyle.default

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        PosterCardStyleRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(PosterCardStyleRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PosterCardStyleUiState else { return }
            self.style = PosterStyle(from: state)
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}
