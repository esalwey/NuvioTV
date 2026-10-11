import Combine
import SwiftUI
import SharedCore

/// Home hero rating chip: follows Settings > Appearance > Ratings > Overall Ratings, the same
/// switch the Detail page's meta line reads. A process-wide singleton so the hero (rebuilt often)
/// never re-subscribes to the shared settings flow.
@MainActor
final class HeroRatingSetting: ObservableObject {
    static let shared = HeroRatingSetting()

    @Published private(set) var showOverallRatings = true

    private var watcher: FlowWatcher?

    private init() {
        MetaScreenSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(MetaScreenSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MetaScreenSettingsUiState else { return }
            if self.showOverallRatings != state.showOverallRatings {
                self.showOverallRatings = state.showOverallRatings
            }
        }
    }

    deinit { watcher?.cancel() }

    /// The rating text the hero shows for an addon-provided `imdbRating`, or nil when there is
    /// nothing worth drawing (blank, or a zero placeholder some addons send).
    nonisolated static func displayText(for rating: String?) -> String? {
        guard let trimmed = rating?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")), value <= 0 { return nil }
        return trimmed
    }
}
