import SwiftUI
import UIKit
import SharedCore

// What the viewer sees and what the players read for Automatic Skipping (Settings > Playback >
// Automatic Skipping): the setting itself, and the short confirmation shown after a segment was
// skipped on its own. The decision logic lives in `SkipPlanner.swift`.

/// The viewer's Automatic Skipping selection, read from the shared (profile-synced) player settings.
enum AutoSkipSettings {
    /// "intro", "recap", "outro" (and "movie-credits" when the phone set it); empty = nothing is
    /// skipped on its own, which is the default.
    static func enabledKinds() -> Set<String> {
        (PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState)?
            .autoSkipSegmentTypeValues ?? []
    }
}

/// "Intro skipped": each skip gets its own id, so two in a row restart the timer.
struct AutoSkipToast: Equatable, Identifiable {
    let id = UUID()
    let text: String
}

/// The confirmation capsule, top-trailing on both engines (the bottom edge belongs to the transport
/// bar, the skip chip and the Up Next card). Never focusable, announced to VoiceOver, and a plain
/// fade under Reduce Motion.
struct AutoSkipToastOverlay: View {
    let toast: AutoSkipToast?
    /// The toast stayed up long enough; the owner clears it if it is still the current one.
    let onExpire: (AutoSkipToast) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Long enough to read four words, short enough to be gone before the next scene lands.
    private static let visibleNanoseconds: UInt64 = 1_800_000_000

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let toast {
                PlayerChipCaption(text: toast.text, symbol: PlayerChipStyle.skipSymbol)
                    .padding(.top, PlayerChipStyle.edgePadding)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    .transition(.opacity)
                    .task(id: toast.id) {
                        UIAccessibility.post(notification: .announcement, argument: toast.text)
                        try? await Task.sleep(nanoseconds: Self.visibleNanoseconds)
                        guard !Task.isCancelled else { return }
                        onExpire(toast)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(reduceMotion ? nil : PlayerChipStyle.animation, value: toast)
        .allowsHitTesting(false)
    }
}
