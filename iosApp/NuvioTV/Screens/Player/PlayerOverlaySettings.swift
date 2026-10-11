import Combine
import SharedCore
import SwiftUI

/// The player-interface switches both engines' views read (Settings > Playback > Player
/// Interface): the loading screen's spinner, the parental guide at the start of playback and the
/// clock with the end time. One watcher on the shared `PlayerSettingsRepository` (profile scoped,
/// synced) for the whole app, so a view only reads the property it needs.
@MainActor
final class PlayerOverlaySettings: ObservableObject {
    static let shared = PlayerOverlaySettings()

    @Published private(set) var showLoadingOverlay = true
    @Published private(set) var showParentalGuide = true
    @Published private(set) var osdClockEnabled = true
    /// The shared aspect choice (Fit or Fill) the next playback opens with.
    @Published private(set) var aspectMode: PlayerAspectMode = .fit

    private var watcher: FlowWatcher?

    private init() {
        PlayerSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PlayerSettingsUiState else { return }
            if self.showLoadingOverlay != state.showLoadingOverlay { self.showLoadingOverlay = state.showLoadingOverlay }
            if self.showParentalGuide != state.showParentalGuide { self.showParentalGuide = state.showParentalGuide }
            if self.osdClockEnabled != state.osdClockEnabled { self.osdClockEnabled = state.osdClockEnabled }
            let aspect = PlayerAspectMode(resizeMode: state.resizeMode)
            if self.aspectMode != aspect { self.aspectMode = aspect }
        }
    }

    // Settings > Playback > Player Interface.

    func setShowLoadingOverlay(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setShowLoadingOverlay(enabled: enabled)
    }

    func setShowParentalGuide(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setShowParentalGuide(enabled: enabled)
    }

    func setOsdClockEnabled(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setOsdClockEnabled(enabled: enabled)
    }
}
