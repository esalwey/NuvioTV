import SwiftUI

/// "Swipe down for info" affordance at the top of the screen (Infuse-style): shown briefly after
/// playback starts and again after a pause, hidden while the panel is open. Non-focusable.
struct PlayerSwipeHint: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Text("Swipe down for info")
                .font(Theme.Font.caption)
            Image(systemName: "chevron.compact.down")
                .font(Theme.Font.sectionTitle)
        }
        .foregroundStyle(Theme.Palette.textSecondary)
        .shadow(color: .black.opacity(0.6), radius: 4)
        .padding(.top, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

extension PlayerSwipeHint {
    /// AES-9: the hint teaches one gesture. Once the viewer has opened the swipe-down panel on
    /// either engine it stops appearing (the mpv transport bar used to carry it every time the bar
    /// showed). Device-local UI state, like the player's other UserDefaults keys.
    static let learnedKey = "player.swipeDownHintLearned"

    static var isLearned: Bool { UserDefaults.standard.bool(forKey: learnedKey) }

    static func markLearned() {
        guard !isLearned else { return }
        UserDefaults.standard.set(true, forKey: learnedKey)
    }
}
