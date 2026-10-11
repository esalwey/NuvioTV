import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

/// Live chrome data the libmpv screen collects for its Chapters tab: the file's own chapters, else the
/// intro/recap/credits segments. The scrubber itself stays a plain track, as on the system player.
@MainActor
final class MPVChromeModel: ObservableObject {
    /// File chapters (mpv `chapter-list`): start in seconds and the file's own name for each.
    @Published var fileChapters: [PlayerFileChapter] = []
    /// The skip segments themselves — the Chapters tab names them like the native screen does.
    @Published var segments: [SkipSegment] = []

    /// The Chapters tab: the segments' chapters (the native screen's `navigationMarkerGroups`),
    /// else the file's own chapters.
    func chapters(durationSec: Double) -> [PlayerChapter] {
        let fromSegments = PlayerChapters.fromSegments(segments, durationSec: durationSec > 0 ? durationSec : nil)
        if !fromSegments.isEmpty { return fromSegments }
        return PlayerChapters.fromFileChapters(fileChapters, durationSec: durationSec)
    }
}

/// Time labels of the chrome ("4:05", "1:02:33").
enum PlayerChromeFormat {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The tvOS 26 system player's transport bar, reproduced for the libmpv engine so it looks and reads
/// exactly like the native screen's `AVPlayerViewController` (user report: one interface for every
/// format). No platter: like the system player, the content floats straight over the picture on a
/// soft shade at the bottom edge (`PlayerChromeScrim`), top to bottom: the title view (episode line
/// over the title, from the same metadata the native item carries) with the round glass transport
/// buttons at its trailing end, the plain scrubber and its scrub head, elapsed and remaining time,
/// and the content-tab row ("swipe down").
///
/// The buttons, the scrubber overlay and the tab row are slots: the passive overlay
/// (`PlayerControlsOverlay`, nothing focusable — libmpv owns the remote) draws them as glyphs, and
/// the presented focus layer (`MPVTransportFocusView`) puts real menus and tabs in the same places,
/// so moving focus into the bar never shifts a pixel.
struct PlayerTransportBar<Buttons: View, ScrubberOverlay: View, Tabs: View>: View {
    @ObservedObject var state: MPVPlaybackState
    let summary: PlayerInfoSummary
    let buttons: Buttons
    let scrubberOverlay: ScrubberOverlay
    let tabs: Tabs

    @Environment(\.colorSchemeContrast) private var contrast

    init(state: MPVPlaybackState,
         summary: PlayerInfoSummary,
         @ViewBuilder buttons: () -> Buttons,
         @ViewBuilder scrubberOverlay: () -> ScrubberOverlay,
         @ViewBuilder tabs: () -> Tabs) {
        _state = ObservedObject(wrappedValue: state)
        self.summary = summary
        self.buttons = buttons()
        self.scrubberOverlay = scrubberOverlay()
        self.tabs = tabs()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.xl) {
                titleBlock
                Spacer(minLength: 0)
                buttons
            }
            .padding(.bottom, Theme.Spacing.lg)
            ProgressBar(fraction: state.fraction,
                        scrubFraction: state.scrubFraction,
                        scrubLabel: state.scrubTargetSec.map { PlayerChromeFormat.time($0) })
                .frame(height: ProgressBar.headSize.height)
                .overlay { scrubberOverlay }
            timeRow
                .padding(.top, Theme.Spacing.sm)
            tabs
                .padding(.top, Theme.Spacing.md)
        }
        .padding(.horizontal, PlayerChromeLayout.contentInset)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Title view

    /// The native title view: the episode line (series only, `iTunesMetadataTrackSubTitle`) over
    /// the title (`commonIdentifierTitle` — the series, or the movie). System text styles: the
    /// player chrome is SF, as on the system player, whatever the app's font family.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let line = summary.episodeLine {
                Text(verbatim: line)
                    .font(Font.callout)
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(1)
            }
            Text(verbatim: summary.header.title)
                .font(Font.headline)
                .fontWeight(.bold)
                .lineLimit(1)
        }
        .playerChromeTextShadow()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Times

    /// Elapsed on the leading end, remaining on the trailing end, as on the system bar.
    private var timeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            if let rate = state.fastForwardRate {
                // Hold fast-forward / rewind rate (2×, 3×, 4×), as the system bar names it.
                Label {
                    Text(verbatim: "\(Int(abs(rate)))\u{00D7}")
                } icon: {
                    Image(systemName: rate < 0 ? "backward.fill" : "forward.fill")
                }
                .labelStyle(.titleAndIcon)
            } else if state.isPaused {
                Image(systemName: "pause.fill")
                    .accessibilityLabel(Text("Paused"))
            }
            Text(verbatim: PlayerChromeFormat.time(state.positionSec))
            Spacer(minLength: Theme.Spacing.lg)
            Text(verbatim: "-" + PlayerChromeFormat.time(max(state.durationSec - state.positionSec, 0)))
        }
        .font(Font.callout)
        .monospacedDigit()
        .foregroundStyle(secondaryStyle)
        .lineLimit(1)
        .playerChromeTextShadow()
    }

    private var secondaryStyle: Color {
        .white.opacity(contrast == .increased ? 0.9 : 0.7)
    }
}

extension View {
    /// A soft shadow under the chrome's text: with no platter behind it, the labels keep their
    /// contrast over a bright scene (the system player does the same on top of its shade).
    func playerChromeTextShadow() -> some View {
        shadow(color: .black.opacity(0.45), radius: 6, y: 1)
    }
}

// MARK: - Transport buttons and tab pills

/// One round transport-bar button: the item's SF Symbol in a Liquid Glass circle (the only glass in
/// the bar, as on the system player), a solid white disc with a black symbol when focused. With
/// Reduce Transparency the glass is a dark disc with a hairline.
struct PlayerTransportGlyph: View {
    let item: PlayerTransportItem
    var focused = false

    static let diameter: CGFloat = 66

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Image(systemName: item.symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(focused ? Color.black : Color.white)
            .frame(width: Self.diameter, height: Self.diameter)
            .modifier(PlayerTransportGlyphSurface(focused: focused, reduceTransparency: reduceTransparency))
            .scaleEffect(focused ? 1.12 : 1)
            .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 10, y: 4)
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}

private struct PlayerTransportGlyphSurface: ViewModifier {
    let focused: Bool
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if focused {
            content.background(Circle().fill(Color.white))
        } else if reduceTransparency {
            content
                .background(Circle().fill(Color.black.opacity(0.7)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        } else {
            content.glassEffect(PlayerChipStyle.glass, in: .circle)
        }
    }
}

/// The transport buttons as drawn while nothing in the bar has focus.
struct PlayerTransportGlyphRow: View {
    let items: [PlayerTransportItem]

    var body: some View {
        GlassEffectContainer(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(items) { PlayerTransportGlyph(item: $0) }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Button style of the focusable transport buttons (and the menus' labels): the glyph, focus-aware.
struct PlayerTransportButtonStyle: ButtonStyle {
    let item: PlayerTransportItem

    func makeBody(configuration: Configuration) -> some View {
        FocusAwareGlyph(item: item, pressed: configuration.isPressed)
    }

    private struct FocusAwareGlyph: View {
        let item: PlayerTransportItem
        let pressed: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            PlayerTransportGlyph(item: item, focused: focused)
                .scaleEffect(pressed ? 0.94 : 1)
        }
    }
}

/// One content-tab title under the scrubber: plain text at rest, a white capsule when focused.
struct PlayerTabPill: View {
    let title: String
    var focused = false
    /// The tab whose content is showing (focus went down into it).
    var selected = false

    var body: some View {
        Text(verbatim: title)
            .font(Font.callout.weight(.semibold))
            .foregroundStyle(focused ? Color.black : Color.white.opacity(selected ? 1 : 0.7))
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xs)
            .background {
                if focused {
                    Capsule().fill(Color.white)
                } else if selected {
                    Capsule().fill(Color.white.opacity(0.18))
                }
            }
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}

struct PlayerTabPillButtonStyle: ButtonStyle {
    let title: String
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        FocusAwarePill(title: title, selected: selected)
    }

    private struct FocusAwarePill: View {
        let title: String
        let selected: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            PlayerTabPill(title: title, focused: focused, selected: selected)
        }
    }
}

/// The tab row as drawn while nothing in the bar has focus.
struct PlayerTabPillRow: View {
    let tabs: [PlayerContentTab]

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(tabs) { PlayerTabPill(title: $0.title) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(
            localized: "player.chrome.tabs.swipeFor",
            defaultValue: "Swipe down for \(names)",
            comment: "VoiceOver label of the player's content tab row, e.g. 'Swipe down for Info, Episodes, Stream Info'.")))
    }

    private var names: String {
        tabs.map { $0.title }.joined(separator: ", ")
    }
}

/// Passive bottom chrome of the libmpv screen: a bottom dim and the transport bar, nothing
/// focusable (libmpv owns the remote; `MPVTransportFocusView` takes over when focus enters the bar).
struct PlayerControlsOverlay: View {
    @ObservedObject var state: MPVPlaybackState
    let summary: PlayerInfoSummary
    var items: [PlayerTransportItem] = []
    var tabs: [PlayerContentTab] = []
    /// Height of the chrome content (scrim excluded), for the prompts stacked above it.
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerChromeScrim()
            PlayerTransportBar(state: state, summary: summary) {
                PlayerTransportGlyphRow(items: items)
            } scrubberOverlay: {
                EmptyView()
            } tabs: {
                PlayerTabPillRow(tabs: tabs)
            }
            .padding(.horizontal, PlayerChromeLayout.barInset)
            .padding(.bottom, PlayerChromeLayout.barBottomInset)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
                onContentHeightChange?(height + PlayerChromeLayout.barBottomInset)
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

/// The system player's skip indicator: a click on the left / right edge of the touch surface draws
/// the circular arrow with the seconds skipped on that side of the picture (clicks in a row add up:
/// 10, 20, 30...), and it fades a moment after the last one. Passive; the bar shows alongside.
struct PlayerSkipIndicator: View {
    let feedback: SkipFeedback?
    /// Called once the indicator has been on screen long enough; the owner clears it.
    let onExpired: (SkipFeedback) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let visibleDuration: Duration = .milliseconds(900)
    /// Distance of the arrow from the screen edge: it sits over the picture, well inside the edge
    /// the click was made on.
    private static let sideInset: CGFloat = Theme.Spacing.screen * 3
    private static let glyphSize: CGFloat = 120

    var body: some View {
        ZStack {
            if let feedback {
                glyph(feedback)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: feedback.direction < 0 ? .leading : .trailing)
                    .padding(.horizontal, Self.sideInset)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: feedback)
        .task(id: feedback?.id) {
            guard let feedback else { return }
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            onExpired(feedback)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glyph(_ feedback: SkipFeedback) -> some View {
        ZStack {
            Image(systemName: feedback.direction < 0 ? "gobackward" : "goforward")
                .font(.system(size: Self.glyphSize, weight: .regular))
            Text(verbatim: "\(feedback.seconds)")
                .font(.system(size: feedback.seconds >= 100 ? 30 : 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .offset(y: 4)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 12, y: 2)
    }
}

/// Where the bar sits on screen (both the passive overlay and the focus layer).
enum PlayerChromeLayout {
    static let barInset: CGFloat = Theme.Spacing.screen
    static let barBottomInset: CGFloat = Theme.Spacing.xl
    /// Side inset of the bar's content inside the bar inset: the text starts about 84 pt from the
    /// edge, where the system player's title view does.
    static let contentInset: CGFloat = Theme.Spacing.lg
}

/// The bottom gradient the chrome sits on. With no platter, this shade is what keeps the white title,
/// time labels and tabs readable over a bright scene (spec 6.9.3: the bottom of the picture goes
/// from clear to a light shade, the text shadow does the rest), and it fades out well above the controls so the picture keeps its
/// brightness. Deeper while a content tab (Info / Episodes / Chapters) is open, as on the system
/// player. Reduce Transparency swaps the soft shade for a darker one, never for a box.
struct PlayerChromeScrim: View {
    var deep = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Opacity of the shade at the bottom edge, and a third of the way up, at rest.
    private var restBottomOpacity: Double { reduceTransparency ? 0.7 : 0.35 }
    private var restMidOpacity: Double { reduceTransparency ? 0.35 : 0.12 }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: deep ? 0.2 : 0.62),
                .init(color: .black.opacity(deep ? 0.55 : restMidOpacity), location: deep ? 0.55 : 0.85),
                .init(color: .black.opacity(deep ? 0.85 : restBottomOpacity), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.3), value: deep)
            .allowsHitTesting(false)
    }
}

/// The system scrubber (spec §6.9.3): a plain 6 pt capsule track (no chapter marks, as on the system
/// player), the played part in white, a 4 × 22 pt playhead mark, and — while scrubbing — a second head at the
/// target with its time above (time-only preview, decision D9). The played part stays on the real
/// playhead until Select / Play commits the scrub (PLY-A3).
private struct ProgressBar: View {
    let fraction: Double
    /// Scrub head position (0…1); nil when not scrubbing.
    var scrubFraction: Double? = nil
    /// Target time drawn above the scrub head.
    var scrubLabel: String? = nil
    static let headSize = CGSize(width: 4, height: 22)
    private static let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let midY = geo.size.height / 2
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                    .frame(height: Self.trackHeight)
                Capsule().fill(.white)
                    .frame(width: max(0, width * clamped(fraction)), height: Self.trackHeight)
                // Playhead mark (dimmed while a scrub head is out, so the target reads first).
                Capsule()
                    .fill(.white.opacity(scrubFraction == nil ? 1 : 0.5))
                    .frame(width: Self.headSize.width, height: Self.headSize.height)
                    .position(x: width * clamped(fraction), y: midY)
                if let scrubFraction {
                    Capsule()
                        .fill(.white)
                        .frame(width: Self.headSize.width, height: Self.headSize.height + 8)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .position(x: width * clamped(scrubFraction), y: midY)
                    if let scrubLabel {
                        Text(verbatim: scrubLabel)
                            .font(Theme.Font.meta.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xxs)
                            .background(.ultraThinMaterial, in: Capsule())
                            .fixedSize()
                            .position(x: labelX(scrubFraction, width: width), y: -Self.headSize.height - 14)
                    }
                }
            }
            .frame(height: geo.size.height)
        }
        .accessibilityHidden(true)
    }

    private func clamped(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }

    /// Keeps the time label over the head without running off either end of the bar.
    private func labelX(_ fraction: Double, width: CGFloat) -> CGFloat {
        let inset: CGFloat = 56
        guard width > inset * 2 else { return width / 2 }
        return min(max(width * clamped(fraction), inset), width - inset)
    }
}
