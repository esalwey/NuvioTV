import SwiftUI

// One look for every transient player affordance ("Skip Intro/Outro/Recap", the Up Next actions)
// on BOTH engines. On the native AVPlayer screen the interactive chips are
// AVPlayerViewController.contextualActions (Apple's own affordance — focusable glass pill, system
// position); the mpv screen can't host focusable UI (libmpv owns the remote), so it draws
// `PlayerActionChip` in the same spot with the same label/symbol and triggers on Select (F6). The
// Up Next countdown is the app-drawn `UpNextCard` on both engines, because a UIAction title that
// changes every second re-animates the whole transport bar.
enum PlayerChipStyle {
    static let animation: Animation = .easeInOut(duration: 0.25)
    /// Bottom-trailing inset from the screen edge (overscan-safe), both engines.
    static let edgePadding: CGFloat = Theme.Spacing.screen
    /// SF Symbols mirrored on the native contextual actions.
    static let skipSymbol = "forward.frame.fill"
    static let nextSymbol = "forward.end.fill"
    /// Trailing hint on the mpv chip: a click of the touch surface centre (Select), which is what
    /// triggers it (F6, VIS-05 point 3). Replaces the old D-pad-down chevron.
    static let selectHintSymbol = "smallcircle.filled.circle"
    /// Neutral Liquid Glass (docs/design/hig-hybrid-contract.md): a prompt is an action, not a
    /// selection, so it never wears the brand accent. Also the one tint of every player panel
    /// (`playerPanelGlass()`), dark enough for text over bright scenes.
    static let glassTint = Color.black.opacity(0.45)
    /// Inner padding of every floating player panel (transport bar, pause / Up Next / stream-info
    /// cards) — AES-7.
    static let panelPadding: CGFloat = Theme.Spacing.lg
    /// Skip window ends this many seconds before the segment end so the affordance disappears
    /// cleanly (both engines' `updateSkipPrompt`).
    static let lastSecondExclusion: Double = 1
}

extension View {
    /// The single surface every floating player panel wears (AES-7): neutral Liquid Glass in the
    /// shared tint, `Theme.Radius.panel` corners and one soft drop shadow — the transport bar and the
    /// cards around it used to show four radii, three tints and four shadows on one screen.
    func playerPanelGlass() -> some View {
        glassEffect(.regular.tint(PlayerChipStyle.glassTint),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .playerPanelShadow()
    }

    /// The one drop shadow under every floating player surface: the panels above, the swipe-down
    /// panel (its own bottom-rounded glass shape) and the mpv action chip.
    func playerPanelShadow() -> some View {
        shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

/// Non-focusable action chip drawn by the mpv screen (the native screen uses contextualActions).
struct PlayerActionChip: View {
    let label: String
    let symbol: String
    /// Trailing Select glyph — the mpv screen's trigger hint.
    var showsPressHint = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
            Text(label)
            if showsPressHint {
                Image(systemName: PlayerChipStyle.selectHintSymbol)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .font(Theme.Font.sectionTitle)
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.horizontal, Theme.Spacing.lg + Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.md)
        .glassEffect(.regular.tint(PlayerChipStyle.glassTint), in: .capsule)
        .playerPanelShadow()
        .accessibilityElement(children: .combine)
    }
}

/// Small status capsule. Never focusable. (The up-next countdown moved to `UpNextCard`, whose ring
/// can't be truncated away the way the tail of this one-line caption was.)
struct PlayerChipCaption: View {
    let text: String
    var symbol: String? = nil
    var showsProgress = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if showsProgress { ProgressView().scaleEffect(0.6) }
            if let symbol { Image(systemName: symbol) }
            Text(text).monospacedDigit().lineLimit(1)
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .glassEffect(.regular.tint(PlayerChipStyle.glassTint), in: .capsule)
        .frame(maxWidth: 620, alignment: .trailing)
    }
}
