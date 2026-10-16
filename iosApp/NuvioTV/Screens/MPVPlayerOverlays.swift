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

    /// The labels under the bar, as the system bar writes them: "15:43" and "-06:52" on a 22:35
    /// episode (the minutes carry two digits once the title is ten minutes long or more, on both
    /// labels), "1:02:33" past an hour.
    static func label(_ seconds: Double, padded: Bool) -> String {
        guard seconds.isFinite, seconds >= 0 else { return padded ? "00:00" : "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: padded ? "%02d:%02d" : "%d:%02d", m, s)
    }

    /// The remaining time: the whole-second duration less the whole seconds elapsed, so that the two
    /// labels always add up to the length (15:57 and -06:38 on 22:35, not -06:37).
    static func remaining(duration: Double, elapsed: Double, padded: Bool) -> String {
        guard duration.isFinite, duration > 0 else { return "-" + label(0, padded: padded) }
        let left = max(Int(duration.rounded()) - Int(max(elapsed, 0)), 0)
        return "-" + label(Double(left), padded: padded)
    }
}

/// Which parts of the chrome are drawn: the focus layer and the passive overlay both show the same
/// bar, and hide parts of it by fading them (the layout never moves).
struct PlayerBarParts: Equatable {
    /// The scrubber, its two labels, the state glyph and the hint.
    var bar = true
    var title = true
    var buttons = true
    var pills = true
}

/// How a part of the chrome fades: `PlayerSpec.Chrome`'s measured cascades coming in, a quick fade
/// going out. Pure opacity, no slide (the system player has none).
enum PlayerBarFade {
    enum Part { case bar, title, buttons, pills }

    static func animation(_ part: Part, visible: Bool, cascade: MPVChromeCascade,
                          skim: Bool, touch: Bool) -> Animation {
        guard visible else {
            // Going away: 100 to 130 ms when a finger lands on a paused player, 133 to 167 ms when
            // the chrome times out.
            return .easeOut(duration: touch ? PlayerSpec.Chrome.touchFadeSec : PlayerSpec.Chrome.hideFadeSec)
        }
        let fade: PlayerSpec.Fade
        if skim, part == .bar {
            fade = PlayerSpec.Chrome.skimBar
        } else {
            switch (cascade, part) {
            case (.pause, .bar): fade = PlayerSpec.Chrome.pauseBar
            case (.pause, .title): fade = PlayerSpec.Chrome.pauseTitle
            case (.pause, .buttons): fade = PlayerSpec.Chrome.pauseButtons
            case (.pause, .pills): fade = PlayerSpec.Chrome.pausePills
            case (.show, .bar): fade = PlayerSpec.Chrome.showBar
            case (.show, .title): fade = PlayerSpec.Chrome.showTitle
            case (.show, .buttons): fade = PlayerSpec.Chrome.showButtons
            case (.show, .pills): fade = PlayerSpec.Chrome.showPills
            }
        }
        return .easeOut(duration: fade.duration).delay(fade.delay)
    }
}

/// The colours of the bar, read off the owner's recording of the system player.
private enum PlayerBarPalette {
    /// The played part: white, and a pale lavender after a skip click (18.085 s).
    static let fill = Color.white
    static let tintedFill = Color(red: 0.84, green: 0.83, blue: 1.0)
    /// What is left to play, and (while scrubbing) the stretch between the playhead and the target.
    static let track = Color(red: 0.62, green: 0.60, blue: 1.0).opacity(0.38)
    static let zone = Color(red: 0.66, green: 0.58, blue: 1.0).opacity(0.80)
    /// The ring inside the knob.
    static let knobRing = Color(red: 0.29, green: 0.29, blue: 0.62)
    /// A focused round button: a pale cyan disc with a dark teal symbol (64.905 s).
    static let focusDisc = Color(red: 0.78, green: 0.97, blue: 0.96)
    static let focusGlyph = Color(red: 0.05, green: 0.30, blue: 0.34)
    /// The hint under the remaining time.
    static let hint = Color(red: 0.80, green: 0.85, blue: 1.0)
}

/// The tvOS 26 system player's transport bar, reproduced for the libmpv engine so it looks and reads
/// exactly like the native screen's `AVPlayerViewController` (user report: one interface for every
/// format). No platter and no scrim: like the system player, the content floats straight over the
/// picture, top to bottom: the title view (episode line over the title, from the same metadata the
/// native item carries) with the round glass transport buttons at its trailing end, the scrubber with
/// the elapsed time under the playhead and the remaining time at the end, and the content-tab row
/// ("swipe down"). Sizes and positions are `PlayerSpec.Layout`'s (docs/player-spec.md, section 9).
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
    /// The bar is on screen: its head and times follow the playhead between the polls. Off while the
    /// passive bar is hidden, so nothing ticks for a bar nobody sees.
    let live: Bool
    /// Which parts are drawn (`PlayerBarParts`); the others fade out in place.
    let parts: PlayerBarParts
    /// The bar alone, brought up by a skip click: its fade-in is the short one.
    let skim: Bool
    /// The bar and its labels are dimmed: focus sits on a transport button.
    let barDimmed: Bool

    init(state: MPVPlaybackState,
         summary: PlayerInfoSummary,
         live: Bool = true,
         parts: PlayerBarParts = PlayerBarParts(),
         skim: Bool = false,
         barDimmed: Bool = false,
         @ViewBuilder buttons: () -> Buttons,
         @ViewBuilder scrubberOverlay: () -> ScrubberOverlay,
         @ViewBuilder tabs: () -> Tabs) {
        _state = ObservedObject(wrappedValue: state)
        self.summary = summary
        self.live = live
        self.parts = parts
        self.skim = skim
        self.barDimmed = barDimmed
        self.buttons = buttons()
        self.scrubberOverlay = scrubberOverlay()
        self.tabs = tabs()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.xl) {
                titleBlock
                    .opacity(parts.title ? 1 : 0)
                    .animation(fade(.title, visible: parts.title), value: parts.title)
                Spacer(minLength: 0)
                buttons
                    .opacity(parts.buttons ? 1 : 0)
                    .animation(fade(.buttons, visible: parts.buttons), value: parts.buttons)
            }
            .padding(.bottom, PlayerSpec.Layout.titleRowToBar)
            PlayerScrubber(state: state, live: live, dimmed: barDimmed)
                .overlay { scrubberOverlay }
                .opacity(parts.bar ? 1 : 0)
                .animation(fade(.bar, visible: parts.bar), value: parts.bar)
            // The pills' row. The hint of the subtitles a back skip turned on sits in the same row,
            // right-aligned under the remaining time (26.5 s of the owner's recording).
            ZStack(alignment: .leading) {
                tabs
                    .opacity(parts.pills ? 1 : 0)
                    .animation(fade(.pills, visible: parts.pills), value: parts.pills)
                subtitleHint
                    .opacity(parts.bar ? 1 : 0)
                    .animation(fade(.bar, visible: parts.bar), value: parts.bar)
            }
            .padding(.top, PlayerSpec.Layout.barToPills)
        }
        .padding(.horizontal, PlayerSpec.Layout.sideInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func fade(_ part: PlayerBarFade.Part, visible: Bool) -> Animation {
        PlayerBarFade.animation(part, visible: visible, cascade: state.chromeCascade,
                                skim: skim, touch: state.scrubChrome)
    }

    // MARK: - Title view

    /// The native title view: the episode line (series only, `iTunesMetadataTrackSubTitle`) over
    /// the title (`commonIdentifierTitle` — the series, or the movie). System text styles: the
    /// player chrome is SF, as on the system player, whatever the app's font family.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: PlayerSpec.Layout.episodeToTitle) {
            if let line = summary.episodeLine {
                Text(verbatim: line)
                    .font(.system(size: PlayerSpec.Layout.episodeFont, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            Text(verbatim: summary.header.title)
                .font(.system(size: PlayerSpec.Layout.titleFont, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        // The block is laid out bottom-aligned with the buttons; the system player's title sits a
        // little lower than that (`PlayerSpec.Layout.titleDrop`).
        .offset(y: PlayerSpec.Layout.titleDrop)
        .playerChromeTextShadow()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Hint

    @ViewBuilder
    private var subtitleHint: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let seconds = state.subtitleHint {
                Text(verbatim: String(localized: "Subtitles on for \(seconds) seconds"))
                    .font(.system(size: PlayerSpec.Layout.hintFont, weight: .semibold))
                    .foregroundStyle(PlayerBarPalette.hint)
                    .lineLimit(1)
                    .playerChromeTextShadow()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.07), value: state.subtitleHint)
    }
}

/// The scrubber: the bar, the knob, the elapsed time under the head (or under the scrub target), the
/// remaining time at the bar's end, and the state glyph beside the elapsed time. It ticks (30 Hz)
/// only while something on it moves by itself: the playing head, or a hold's.
struct PlayerScrubber: View {
    @ObservedObject var state: MPVPlaybackState
    let live: Bool
    let dimmed: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live || !(state.isAdvancing || state.scan != nil))) { _ in
            let uptime = ProcessInfo.processInfo.systemUptime
            PlayerScrubberRow(duration: state.durationSec,
                              head: state.displayPosition(at: uptime),
                              target: state.scrubTargetSec,
                              slot: state.slot(at: uptime),
                              knob: state.knobShown,
                              tinted: state.barTinted)
        }
        .opacity(dimmed ? PlayerSpec.Chrome.dimmedBarOpacity : 1)
        .animation(.easeOut(duration: 0.15), value: dimmed)
    }
}

/// One drawing of the scrubber. While a scrub is on, the bar has three stretches — white up to the
/// nearer of the playhead and the target, a deeper lavender between the two, the pale track beyond
/// — and a thin tick on the farther of the two; the time under the bar is the target's. At rest it
/// is the white fill and the pale track, and (with a finger resting on a paused player) the knob.
struct PlayerScrubberRow: View {
    let duration: Double
    /// Where the picture is (seconds).
    let head: Double
    /// Where a scrub points (seconds); nil = no scrub.
    let target: Double?
    let slot: MPVBarSlot?
    let knob: Bool
    let tinted: Bool

    private var thickness: CGFloat {
        (target != nil || knob) ? PlayerSpec.Layout.barThicknessActive : PlayerSpec.Layout.barThickness
    }

    /// The bar's centre line inside the row: the thickest the bar gets is half of it.
    private var barCentre: CGFloat { PlayerSpec.Layout.barThicknessActive / 2 }

    private var labelCentre: CGFloat {
        barCentre + PlayerSpec.Layout.labelOffset + (knob ? PlayerSpec.Layout.labelKnobExtra : 0)
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / duration, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let shown = target ?? head
            ZStack(alignment: .topLeading) {
                track(width: width)
                knobView(width: width, at: shown)
                elapsedLabel(width: width, shown: shown)
                remainingLabel(width: width, shown: shown)
            }
        }
        .frame(height: PlayerSpec.Layout.scrubberRowHeight)
        .animation(.easeOut(duration: 0.2), value: knob)
        .animation(.easeOut(duration: 0.2), value: target != nil)
        .accessibilityHidden(true)
    }

    // MARK: - Bar

    private func track(width: CGFloat) -> some View {
        let headX = width * fraction(head)
        let targetX = width * fraction(target ?? head)
        let low = min(headX, targetX), high = max(headX, targetX)
        return ZStack(alignment: .leading) {
            Rectangle().fill(PlayerBarPalette.track)
            Rectangle().fill(PlayerBarPalette.zone)
                .frame(width: max(high - low, 0))
                .offset(x: low)
            Rectangle().fill(tinted ? PlayerBarPalette.tintedFill : PlayerBarPalette.fill)
                .frame(width: max(low, 0))
        }
        .frame(width: width, height: thickness)
        .clipShape(Capsule())
        .overlay(alignment: .leading) {
            // The tick on the farther of the playhead and the target stands a little proud of the bar.
            if target != nil {
                Rectangle().fill(Color.white)
                    .frame(width: 2.5, height: thickness + 8)
                    .offset(x: high - 1.25)
            }
        }
        .position(x: width / 2, y: barCentre)
    }

    /// The knob a resting finger puts on the playhead: a white disc with an indigo ring in it.
    private func knobView(width: CGFloat, at seconds: Double) -> some View {
        ZStack {
            Circle().fill(Color.white)
            Circle()
                .strokeBorder(PlayerBarPalette.knobRing, lineWidth: 3.5)
                .frame(width: PlayerSpec.Layout.knobRingDiameter, height: PlayerSpec.Layout.knobRingDiameter)
        }
        .frame(width: PlayerSpec.Layout.knobDiameter, height: PlayerSpec.Layout.knobDiameter)
        .shadow(color: .black.opacity(0.25), radius: 4)
        .scaleEffect(knob ? 1 : 0.2)
        .opacity(knob ? 1 : 0)
        .animation(.easeOut(duration: knob ? PlayerSpec.Scrub.knobGrowSec : PlayerSpec.Scrub.knobShrinkSec),
                   value: knob)
        .position(x: width * fraction(seconds), y: barCentre)
    }

    // MARK: - Labels

    private var labelFont: Font {
        .system(size: PlayerSpec.Layout.labelFont, weight: .semibold)
    }

    /// The elapsed time, centred under the head (under the target while scrubbing), with the state
    /// glyph hanging off its trailing side — or its leading side for a rewind and a back skip.
    private func elapsedLabel(width: CGFloat, shown: Double) -> some View {
        let x = min(max(width * fraction(shown), 30), max(width - 170, 30))
        return Text(verbatim: PlayerChromeFormat.label(shown, padded: duration >= 600))
            .font(labelFont)
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .playerChromeTextShadow()
            .overlay(alignment: .leading) { leadingSlot }
            .overlay(alignment: .trailing) { trailingSlot }
            .animation(.easeOut(duration: PlayerSpec.Skip.glyphFadeSec), value: slot)
            .position(x: x, y: labelCentre)
    }

    private func remainingLabel(width: CGFloat, shown: Double) -> some View {
        Text(verbatim: PlayerChromeFormat.remaining(duration: duration, elapsed: shown, padded: duration >= 600))
            .font(labelFont)
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .playerChromeTextShadow()
            .frame(width: width, alignment: .trailing)
            .position(x: width / 2, y: labelCentre)
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if let slot, slot.side < 0 {
            PlayerBarSlotView(slot: slot)
                .alignmentGuide(.leading) { d in d.width + PlayerSpec.Layout.glyphGap }
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var trailingSlot: some View {
        if let slot, slot.side > 0 {
            PlayerBarSlotView(slot: slot)
                .alignmentGuide(.trailing) { _ in -PlayerSpec.Layout.glyphGap }
                .transition(.opacity)
        }
    }
}

/// What the bar draws beside the elapsed time: the pause glyph, the skip glyph of a click, the badge
/// of a hold (a ring with the way it runs in it, and a bare digit from the second tier on, on the
/// far side of the ring), or the spinner a hold's release leaves until the picture is back.
struct PlayerBarSlotView: View {
    let slot: MPVBarSlot

    var body: some View {
        content
            .font(.system(size: PlayerSpec.Layout.labelFont, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .playerChromeTextShadow()
    }

    @ViewBuilder
    private var content: some View {
        switch slot {
        case .pause:
            PlayerSlotRing(symbol: "pause.fill")
                .accessibilityLabel(Text("Paused"))
        case .skip(let direction, _):
            Image(systemName: direction < 0 ? "gobackward.10" : "goforward.10")
                .font(.system(size: 28, weight: .semibold))
                .accessibilityHidden(true)
        case .scan(let direction, let digit):
            HStack(spacing: 8) {
                if direction < 0, let digit { Text(verbatim: "\(digit)") }
                PlayerSlotRing(symbol: direction < 0 ? "backward.fill" : "forward.fill")
                if direction > 0, let digit { Text(verbatim: "\(digit)") }
            }
            .accessibilityHidden(true)
        case .seeking:
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: PlayerSpec.Layout.glyphDiameter, height: PlayerSpec.Layout.glyphDiameter)
                .accessibilityHidden(true)
        }
    }
}

/// A thin ring with a small symbol in it: the pause and the hold glyphs.
private struct PlayerSlotRing: View {
    let symbol: String

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
        }
        .frame(width: PlayerSpec.Layout.glyphDiameter, height: PlayerSpec.Layout.glyphDiameter)
    }
}

extension View {
    /// A soft shadow under the chrome's text: with no platter behind it, the labels keep their
    /// contrast over a bright scene (the system player does the same).
    func playerChromeTextShadow() -> some View {
        shadow(color: .black.opacity(0.45), radius: 6, y: 1)
    }
}

// MARK: - Transport buttons and tab pills

/// One round transport-bar button: the item's SF Symbol in a Liquid Glass circle (the only glass in
/// the bar, as on the system player), a pale cyan disc with a dark symbol when focused. With Reduce
/// Transparency the glass is a dark disc with a hairline.
struct PlayerTransportGlyph: View {
    let item: PlayerTransportItem
    var focused = false

    static let diameter: CGFloat = PlayerSpec.Layout.buttonDiameter

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Image(systemName: item.symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(focused ? PlayerBarPalette.focusGlyph : Color.white)
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
            content.background(Circle().fill(PlayerBarPalette.focusDisc))
        } else if reduceTransparency {
            content
                .background(Circle().fill(Color.black.opacity(0.7)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        } else {
            content.glassEffect(PlayerChipStyle.transportGlass, in: .circle)
        }
    }
}

/// The transport buttons as drawn while nothing in the bar has focus.
struct PlayerTransportGlyphRow: View {
    let items: [PlayerTransportItem]

    var body: some View {
        GlassEffectContainer(spacing: PlayerSpec.Layout.buttonSpacing) {
            HStack(spacing: PlayerSpec.Layout.buttonSpacing) {
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

/// One content-tab title under the scrubber: a Liquid Glass capsule at rest, a white capsule with dark
/// text when it is the tab whose content is showing or the one focus is on. No scale, no ring (the
/// system's pills have none).
struct PlayerTabPill: View {
    let title: String
    /// The tab whose content is showing, or that focus is on.
    var selected = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Text(verbatim: title)
            .font(.system(size: PlayerSpec.Layout.pillFont, weight: .semibold))
            .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.white)
            .padding(.horizontal, PlayerSpec.Layout.pillPadding)
            .frame(height: PlayerSpec.Layout.pillHeight)
            .modifier(PlayerPillSurface(selected: selected, reduceTransparency: reduceTransparency))
            .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private struct PlayerPillSurface: ViewModifier {
    let selected: Bool
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected {
            content.background(Capsule().fill(Color.white))
        } else if reduceTransparency {
            content
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        } else {
            content.glassEffect(PlayerChipStyle.transportGlass, in: .capsule)
        }
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
            PlayerTabPill(title: title, selected: focused || selected)
        }
    }
}

/// The tab row as drawn while nothing in the bar has focus.
struct PlayerTabPillRow: View {
    let tabs: [PlayerContentTab]

    var body: some View {
        GlassEffectContainer(spacing: PlayerSpec.Layout.pillSpacing) {
            HStack(spacing: PlayerSpec.Layout.pillSpacing) {
                ForEach(tabs) { PlayerTabPill(title: $0.title) }
            }
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

/// Passive bottom chrome of the libmpv screen: the transport bar, nothing focusable (libmpv owns the
/// remote; `MPVTransportFocusView` takes over when focus enters the bar). No dimming of the picture:
/// the system player has none.
struct PlayerControlsOverlay: View {
    @ObservedObject var state: MPVPlaybackState
    let summary: PlayerInfoSummary
    var items: [PlayerTransportItem] = []
    var tabs: [PlayerContentTab] = []
    /// Which parts are on screen (the bar alone while a skip or a scrub has the chrome).
    var parts = PlayerBarParts()
    /// The bar alone that a skip click brought up: its fade-in is the short one.
    var skim = false
    /// The bar is on screen (see `PlayerTransportBar.live`).
    var live = true
    /// Height of the chrome content, for the prompts stacked above it.
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    var body: some View {
        PlayerTransportBar(state: state, summary: summary, live: live, parts: parts, skim: skim) {
            PlayerTransportGlyphRow(items: items)
        } scrubberOverlay: {
            EmptyView()
        } tabs: {
            PlayerTabPillRow(tabs: tabs)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
            onContentHeightChange?(height + PlayerSpec.Layout.bottomInset)
        })
        .padding(.bottom, PlayerSpec.Layout.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}
