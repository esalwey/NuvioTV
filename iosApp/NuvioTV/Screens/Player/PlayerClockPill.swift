import Combine
import SwiftUI

/// The time of day and when the video will end, drawn top-trailing while the transport bar is on
/// screen — on BOTH engines (Settings > Playback > Player Interface > Show Clock and End Time).
///
/// A small piece of functional chrome, so it wears the players' Liquid Glass (an opaque dark fill
/// with Reduce Transparency). It is never focusable and reads as one VoiceOver element.
struct PlayerClockPill: View {
    /// Seconds of video left at normal speed; nil while the length is unknown (no end time then).
    let remainingSec: Double?
    /// The playback speed the remaining video plays at.
    let rate: Double

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Redrawn at every minute change; a new position redraws it between those.
        TimelineView(.everyMinute) { _ in
            let now = Date()
            HStack(spacing: Theme.Spacing.sm) {
                Text(verbatim: Self.timeText(now))
                if let end = Self.endDate(from: now, remainingSec: remainingSec, rate: rate) {
                    Text(verbatim: "\u{00B7}")
                        .foregroundStyle(.secondary)
                    Text(verbatim: String(
                        localized: "player.clock.endsAt",
                        defaultValue: "Ends at \(Self.timeText(end))",
                        comment: "Player clock: the time of day the video will end. The argument is a time such as 9:41 PM."))
                        .foregroundStyle(.secondary)
                }
            }
            .font(Theme.Font.meta)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .modifier(PlayerClockSurface(reduceTransparency: reduceTransparency))
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    /// "9:04 PM" / "21:04", in the viewer's own format.
    static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// When the video ends if it plays on at `rate`; nil when the remaining time is unknown.
    static func endDate(from now: Date, remainingSec: Double?, rate: Double) -> Date? {
        guard let remainingSec, remainingSec.isFinite, remainingSec > 0 else { return nil }
        let speed = rate.isFinite && rate > 0 ? rate : 1
        return now.addingTimeInterval(remainingSec / speed)
    }
}

private struct PlayerClockSurface: ViewModifier {
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        } else {
            content
                .glassEffect(.regular.tint(PlayerChipStyle.glassTint), in: .capsule)
                .playerPanelShadow()
        }
    }
}

/// The pill's place on screen and its visibility rule: shown with the transport bar, gone with it,
/// and not at all when the setting is off. Reading `PlayerOverlaySettings` here keeps both engine
/// screens free of the setting.
struct PlayerClockOverlay: View {
    /// The transport bar (or the pause chrome) is on screen.
    let chromeVisible: Bool
    let remainingSec: Double?
    let rate: Double

    @ObservedObject private var settings = PlayerOverlaySettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = chromeVisible && settings.osdClockEnabled
        ZStack(alignment: .topTrailing) {
            if shown {
                PlayerClockPill(remainingSec: remainingSec, rate: rate)
                    .padding(.top, PlayerChipStyle.edgePadding)
                    .padding(.trailing, PlayerChipStyle.edgePadding)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(reduceMotion ? nil : PlayerChipStyle.animation, value: shown)
        .allowsHitTesting(false)
    }
}

/// What the native screen's clock needs from playback: the position ticks feed it, and only the
/// pill observes it, so a tick never redraws the whole player screen.
@MainActor
final class PlayerClockModel: ObservableObject {
    @Published private(set) var remainingSec: Double?
    /// The system transport bar is on screen (`AVPlayerViewController`'s own visibility callback).
    @Published var transportBarVisible = false

    /// A new playback position. The pill shows minutes, so the remaining time is kept to 5 s steps.
    func update(position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0 else {
            if remainingSec != nil { remainingSec = nil }
            return
        }
        let remaining = (max(duration - position, 0) / 5).rounded() * 5
        if remainingSec != remaining { remainingSec = remaining }
    }
}

/// The native screen's pill: the model's remaining time and the system bar's visibility (or a
/// pause, which the system player never hides its bar on).
struct NativeClockOverlay: View {
    @ObservedObject var model: PlayerClockModel
    let isPaused: Bool
    let rate: Double

    var body: some View {
        PlayerClockOverlay(chromeVisible: model.transportBarVisible || isPaused,
                           remainingSec: model.remainingSec,
                           rate: rate)
    }
}
