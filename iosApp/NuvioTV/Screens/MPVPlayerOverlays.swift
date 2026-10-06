import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

/// Live chrome data the libmpv screen collects for its transport bar and Chapters tab: chapter
/// ticks from the file's own chapters, else from the intro/recap/credits segments.
@MainActor
final class MPVChromeModel: ObservableObject {
    /// File chapters (mpv `chapter-list`), in seconds, the first one (0) excluded.
    @Published var chapterTimes: [Double] = []
    /// Skip-segment boundaries (intro/recap/credits starts and ends), in seconds.
    @Published var segmentBounds: [Double] = []
    /// The skip segments themselves — the Chapters tab names them like the native screen does.
    @Published var segments: [SkipSegment] = []

    /// What the scrubber marks: the file's chapters when it has any, else the known segments.
    var tickTimes: [Double] { chapterTimes.isEmpty ? segmentBounds : chapterTimes }

    /// The Chapters tab: the segments' chapters (the native screen's `navigationMarkerGroups`),
    /// else the file's own chapters.
    func chapters(durationSec: Double) -> [PlayerChapter] {
        let fromSegments = PlayerChapters.fromSegments(segments, durationSec: durationSec > 0 ? durationSec : nil)
        if !fromSegments.isEmpty { return fromSegments }
        return PlayerChapters.fromFileChapters(chapterTimes, durationSec: durationSec)
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
/// format). One Liquid Glass platter at the bottom holding, top to bottom: the title view (episode
/// line over the title, from the same metadata the native item carries) with the transport buttons
/// at its trailing end, the scrubber with chapter ticks and the scrub head, elapsed and remaining
/// time, and the content-tab row ("swipe down").
///
/// The buttons, the scrubber overlay and the tab row are slots: the passive overlay
/// (`PlayerControlsOverlay`, nothing focusable — libmpv owns the remote) draws them as glyphs, and
/// the presented focus layer (`MPVTransportFocusView`) puts real menus and tabs in the same places,
/// so moving focus into the bar never shifts a pixel.
struct PlayerTransportBar<Buttons: View, ScrubberOverlay: View, Tabs: View>: View {
    @ObservedObject var state: MPVPlaybackState
    let summary: PlayerInfoSummary
    /// Chapter marks in seconds (file chapters, or the skip segments).
    let ticks: [Double]
    let buttons: Buttons
    let scrubberOverlay: ScrubberOverlay
    let tabs: Tabs

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(state: MPVPlaybackState,
         summary: PlayerInfoSummary,
         ticks: [Double],
         @ViewBuilder buttons: () -> Buttons,
         @ViewBuilder scrubberOverlay: () -> ScrubberOverlay,
         @ViewBuilder tabs: () -> Tabs) {
        _state = ObservedObject(wrappedValue: state)
        self.summary = summary
        self.ticks = ticks
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
                        scrubLabel: state.scrubTargetSec.map { PlayerChromeFormat.time($0) },
                        ticks: tickFractions)
                .frame(height: ProgressBar.headSize.height)
                .overlay { scrubberOverlay }
            timeRow
                .padding(.top, Theme.Spacing.sm)
            tabs
                .padding(.top, Theme.Spacing.md)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PlayerBarSurface(reduceTransparency: reduceTransparency, contrast: contrast))
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
        .accessibilityElement(children: .combine)
    }

    // MARK: - Times

    /// Elapsed on the leading end, remaining on the trailing end, as on the system bar.
    private var timeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            if let rate = state.fastForwardRate {
                // Hold-right fast-forward rate (2×, 3×, 4×).
                Label {
                    Text(verbatim: "\(Int(rate))\u{00D7}")
                } icon: {
                    Image(systemName: "forward.fill")
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
    }

    private var tickFractions: [Double] {
        guard state.durationSec > 0 else { return [] }
        return ticks
            .map { $0 / state.durationSec }
            .filter { $0 > 0.005 && $0 < 0.995 }
    }

    private var secondaryStyle: Color {
        .white.opacity(contrast == .increased ? 0.9 : 0.7)
    }
}

/// The bar's platter: Liquid Glass in the players' shared tint, or an opaque dark fill with Reduce
/// Transparency.
private struct PlayerBarSurface: ViewModifier {
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
        if reduceTransparency {
            content
                .background(shape.fill(Color.black.opacity(0.85)))
                .overlay(shape.strokeBorder(Color.white.opacity(contrast == .increased ? 0.5 : 0.15), lineWidth: 1))
        } else {
            content
                .glassEffect(.regular.tint(PlayerChipStyle.glassTint), in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
                    }
                }
        }
    }
}

// MARK: - Transport buttons and tab pills

/// One round transport-bar button: the item's SF Symbol in a circle, white when focused.
struct PlayerTransportGlyph: View {
    let item: PlayerTransportItem
    var focused = false

    static let diameter: CGFloat = 66

    var body: some View {
        Image(systemName: item.symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(focused ? Color.black : Color.white)
            .frame(width: Self.diameter, height: Self.diameter)
            .background(Circle().fill(focused ? Color.white : Color.white.opacity(0.14)))
            .scaleEffect(focused ? 1.12 : 1)
            .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 10, y: 4)
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}

/// The transport buttons as drawn while nothing in the bar has focus.
struct PlayerTransportGlyphRow: View {
    let items: [PlayerTransportItem]

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(items) { PlayerTransportGlyph(item: $0) }
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
    var chapterTicks: [Double] = []
    var items: [PlayerTransportItem] = []
    var tabs: [PlayerContentTab] = []
    /// Height of the chrome content (scrim excluded), for the prompts stacked above it.
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerChromeScrim()
            PlayerTransportBar(state: state, summary: summary, ticks: chapterTicks) {
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

/// Where the bar sits on screen (both the passive overlay and the focus layer).
enum PlayerChromeLayout {
    static let barInset: CGFloat = Theme.Spacing.screen
    static let barBottomInset: CGFloat = Theme.Spacing.xl
}

/// Bottom dim behind the bar so the glass reads over any scene; deeper while a content tab is open.
struct PlayerChromeScrim: View {
    var deep = false

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: deep ? 0.2 : 0.55),
                .init(color: .black.opacity(deep ? 0.55 : 0.25), location: deep ? 0.55 : 0.8),
                .init(color: .black.opacity(deep ? 0.8 : 0.5), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.3), value: deep)
            .allowsHitTesting(false)
    }
}

/// The system scrubber (spec §6.9.3): a 6 pt capsule track, the played part in white, chapter
/// ticks cut into it, a 4 × 22 pt playhead mark, and — while scrubbing — a second head at the
/// target with its time above (time-only preview, decision D9). The played part stays on the real
/// playhead until Select / Play commits the scrub (PLY-A3).
private struct ProgressBar: View {
    let fraction: Double
    /// Scrub head position (0…1); nil when not scrubbing.
    var scrubFraction: Double? = nil
    /// Target time drawn above the scrub head.
    var scrubLabel: String? = nil
    /// Chapter positions (0…1).
    var ticks: [Double] = []

    static let headSize = CGSize(width: 4, height: 22)
    private static let trackHeight: CGFloat = 6
    private static let tickWidth: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let midY = geo.size.height / 2
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                    .frame(height: Self.trackHeight)
                Capsule().fill(.white)
                    .frame(width: max(0, width * clamped(fraction)), height: Self.trackHeight)
                // Chapter ticks: short gaps in the track, like the system's chapter breaks.
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: Self.tickWidth, height: Self.trackHeight)
                        .position(x: width * clamped(tick), y: midY)
                }
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
                            .background(Capsule().fill(.black.opacity(0.6)))
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

/// Top-trailing live diagnostics card (codec, resolution, fps, hwdec, bitrate, audio, cache).
struct StreamInfoOverlayView: View {
    let info: StreamInfoSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Stream Info")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
            ForEach(info.rows, id: \.0) { row in
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Text(row.0)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 190, alignment: .leading)
                    Text(row.1)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                }
                .font(Theme.Font.caption.monospacedDigit())
            }
        }
        .padding(PlayerChipStyle.panelPadding)
        .frame(maxWidth: 560, alignment: .leading)
        .playerPanelGlass()
    }
}
