import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

/// Live chrome data the libmpv screen collects for its transport bar (spec §6.9.3): chapter ticks
/// from the file's own chapters, else from the intro/recap/credits segments.
@MainActor
final class MPVChromeModel: ObservableObject {
    /// File chapters (mpv `chapter-list`), in seconds, the first one (0) excluded.
    @Published var chapterTimes: [Double] = []
    /// Skip-segment boundaries (intro/recap/credits starts and ends), in seconds.
    @Published var segmentBounds: [Double] = []

    /// What the scrubber marks: the file's chapters when it has any, else the known segments.
    var tickTimes: [Double] { chapterTimes.isEmpty ? segmentBounds : chapterTimes }
}

/// Sustained-pause details for the transport bar (TV-app pause look, spec §6.9.3): a larger title,
/// the synopsis and what's left, over a deeper scrim. nil = the plain chrome.
struct PlayerPauseDetails: Equatable {
    let synopsis: String?
    let remaining: String?
    let provider: String?
}

/// Bottom transport chrome, a clone of the tvOS 26 system player (spec §6.9.3): no panel — the
/// controls float on a bottom dim gradient. Title block (eyebrow + headline), a thin scrubber with
/// chapter ticks, a playhead mark and a separate scrub head, elapsed / end time / remaining, and
/// the content-tab pills that the swipe-down panel opens on. Only the pills wear Liquid Glass.
/// Nothing here is focusable: libmpv owns the remote.
struct PlayerControlsOverlay: View {
    @ObservedObject var state: MPVPlaybackState
    let titleParts: PlaybackTitleParts
    /// Sustained pause: the title block grows and gains the synopsis (replaces the old pause card).
    var pauseDetails: PlayerPauseDetails? = nil
    /// Chapter marks in seconds (file chapters, or the skip segments).
    var chapterTicks: [Double] = []
    /// The swipe-down panel's tabs, shown as the system player's content pills.
    var tabs: [PlayerPanelTab] = []
    /// The tab the panel opens on (drawn as the focused pill).
    var highlightedTab: PlayerPanelTab = .info
    /// Height of the chrome content (gradient excluded), for the prompts stacked above it.
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    // Explicit: the private environment values would make the synthesized initializer private.
    init(state: MPVPlaybackState,
         titleParts: PlaybackTitleParts,
         pauseDetails: PlayerPauseDetails? = nil,
         chapterTicks: [Double] = [],
         tabs: [PlayerPanelTab] = [],
         highlightedTab: PlayerPanelTab = .info,
         onContentHeightChange: ((CGFloat) -> Void)? = nil) {
        _state = ObservedObject(wrappedValue: state)
        self.titleParts = titleParts
        self.pauseDetails = pauseDetails
        self.chapterTicks = chapterTicks
        self.tabs = tabs
        self.highlightedTab = highlightedTab
        self.onContentHeightChange = onContentHeightChange
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            scrim
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
                    onContentHeightChange?(height)
                })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    // MARK: - Layers

    /// Bottom dim so white text reads over any scene: 45 % of the screen, black 0 → 0.65; deeper
    /// and taller while the pause details are up.
    private var scrim: some View {
        let paused = pauseDetails != nil
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: paused ? 0.25 : 0.55),
                .init(color: .black.opacity(paused ? 0.55 : 0.35), location: paused ? 0.6 : 0.8),
                .init(color: .black.opacity(paused ? 0.8 : 0.65), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: paused)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBlock
                .padding(.bottom, Theme.Spacing.lg)
            ProgressBar(fraction: state.fraction,
                        scrubFraction: state.scrubFraction,
                        scrubLabel: state.scrubTargetSec.map { Self.timeString($0) },
                        ticks: tickFractions)
                .frame(height: ProgressBar.headSize.height)
            timeRow
                .padding(.top, Theme.Spacing.sm)
            if !tabs.isEmpty {
                pills
                    .padding(.top, Theme.Spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Title

    /// "SEVERANCE · S2 · E5" over "Trojan's Horse" for an episode; the movie's name alone otherwise.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let eyebrow {
                Text(verbatim: eyebrow)
                    .font(Theme.Font.meta)
                    .textCase(.uppercase)
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(1)
            }
            Text(verbatim: headline)
                // System text styles (Headline 38 / Title 3 48): the player chrome is SF, as on the
                // system player, whatever the app's font family.
                .font(pauseDetails == nil ? Font.headline : Font.title3)
                .fontWeight(.bold)
                .lineLimit(pauseDetails == nil ? 1 : 2)
            if let details = pauseDetails {
                if let synopsis = details.synopsis {
                    Text(verbatim: synopsis)
                        .font(Theme.Font.body)
                        .foregroundStyle(secondaryStyle)
                        .lineLimit(3)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .padding(.top, Theme.Spacing.xs)
                }
                let facts = [details.remaining, details.provider].compactMap { $0 }
                if !facts.isEmpty {
                    Text(verbatim: facts.joined(separator: " \u{00B7} "))
                        .font(Theme.Font.meta)
                        .monospacedDigit()
                        .foregroundStyle(secondaryStyle)
                        .lineLimit(1)
                        .padding(.top, Theme.Spacing.xxs)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        guard titleParts.isEpisode else { return titleParts.heading }
        return titleParts.episodeName ?? titleParts.heading
    }

    private var eyebrow: String? {
        guard titleParts.isEpisode else { return nil }
        var parts: [String] = []
        if let series = titleParts.series, series != headline { parts.append(series) }
        if let code = titleParts.code { parts.append(code) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Times

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
            Text(verbatim: Self.timeString(state.positionSec))
            Spacer(minLength: Theme.Spacing.lg)
            if let endsAt {
                Text(verbatim: endsAt)
                    .foregroundStyle(secondaryStyle)
                    .padding(.trailing, Theme.Spacing.md)
            }
            Text(verbatim: "-" + Self.timeString(max(state.durationSec - state.positionSec, 0)))
        }
        .font(Theme.Font.meta)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// "Ends at 22:41": wall-clock end at the current speed (system player parity).
    private var endsAt: String? {
        guard state.durationSec > 0, state.positionSec.isFinite else { return nil }
        let speed = state.playbackSpeed > 0 ? state.playbackSpeed : 1
        let remaining = max(state.durationSec - state.positionSec, 0) / speed
        guard remaining.isFinite else { return nil }
        let time = Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)
        return String(localized: "player.chrome.endsAt",
                      defaultValue: "Ends at \(time)",
                      comment: "mpv player transport bar: wall-clock time the video ends, e.g. 'Ends at 22:41'.")
    }

    private var tickFractions: [Double] {
        guard state.durationSec > 0 else { return [] }
        return chapterTicks
            .map { $0 / state.durationSec }
            .filter { $0 > 0.005 && $0 < 0.995 }
    }

    // MARK: - Content pills

    /// The system player's content tabs (Info · Subtitles · Audio · Playback): glass capsules, the
    /// one Down opens drawn focused (white, black label). Visual only — Down opens the panel there.
    private var pills: some View {
        GlassEffectContainer(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(tabs) { tab in
                    pill(tab)
                }
                Image(systemName: "chevron.down")
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(secondaryStyle)
                    .padding(.leading, Theme.Spacing.xxs)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(
            localized: "player.chrome.pills.accessibility",
            defaultValue: "Swipe down for Info, Subtitles, Audio and Playback",
            comment: "VoiceOver label of the mpv player's content tab pills (the swipe-down panel's tabs).")))
    }

    @ViewBuilder
    private func pill(_ tab: PlayerPanelTab) -> some View {
        let focused = tab == highlightedTab
        let label = Text(verbatim: tab.title)
            .font(Theme.Font.meta)
            .foregroundStyle(focused ? Color.black : Color.white)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xs)
        if focused {
            label.background(Capsule().fill(.white))
        } else if reduceTransparency {
            label
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .overlay(Capsule().strokeBorder(.white.opacity(contrast == .increased ? 0.5 : 0.15), lineWidth: 1))
        } else {
            label
                .glassEffect(.regular, in: .capsule)
                .overlay {
                    if contrast == .increased {
                        Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                    }
                }
        }
    }

    // MARK: - Helpers

    private var secondaryStyle: Color {
        .white.opacity(contrast == .increased ? 0.9 : 0.7)
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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
