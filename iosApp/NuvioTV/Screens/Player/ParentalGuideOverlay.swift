import Combine
import SharedCore
import SwiftUI

// The parental guide shown as playback starts (Settings > Playback > Player Interface > Show
// Parental Guide), on BOTH engines: a line grows down the leading edge, the advisories fade in
// under each other ("Violence · Moderate"), stay for a few seconds and leave the way they came.
// Passive: nothing in it is focusable, and the transport chrome sending it away is instant.

/// When the guide may appear and for how long.
enum ParentalGuideTiming {
    /// The advisories stay on screen this long once they are all in.
    static let holdSeconds: Double = 5
    /// A first frame this long ago is too late: the viewer kept the controls up (or paused) and a
    /// guide appearing minutes into the film would be noise.
    static let latestStartSeconds: TimeInterval = 20
    /// Episodes of one series within this window do not repeat the guide (a binge sees it once).
    static let repeatSuppressionSeconds: TimeInterval = 3 * 3600

    static func shouldShow(settingOn: Bool,
                           hasWarnings: Bool,
                           alreadyShown: Bool,
                           firstFrameAge: TimeInterval?,
                           chromeVisible: Bool) -> Bool {
        guard settingOn, hasWarnings, !alreadyShown, !chromeVisible, let age = firstFrameAge else { return false }
        return age <= latestStartSeconds
    }
}

/// One playback's guide: fetches the warnings, then decides when to show them.
@MainActor
final class ParentalGuidePresenter: ObservableObject {
    @Published private(set) var warnings: [ParentalWarning] = []
    @Published private(set) var isShowing = false

    private var requested = false
    private var shown = false
    private var firstFrameAt: Date?
    private var chromeVisible = false
    private var parentMetaId = ""

    /// Title and series that already showed their guide, for `repeatSuppressionSeconds`.
    private static var lastShown: (parentMetaId: String, at: Date)?

    /// Starts the lookup, once, when the setting is on and the title has an IMDb id.
    func prepare(context: PlaybackContext) {
        guard !requested, PlayerOverlaySettings.shared.showParentalGuide else { return }
        guard let imdbId = ParentalGuideLoader.imdbId(from: [context.parentMetaId, context.videoId]) else { return }
        requested = true
        parentMetaId = context.parentMetaId
        ParentalGuideLoader.fetchWarnings(imdbId: imdbId) { [weak self] warnings in
            guard let self else { return }
            self.warnings = warnings
            self.evaluate()
        }
    }

    /// The first video frame is on screen.
    func firstFrameShown() {
        guard firstFrameAt == nil else { return }
        firstFrameAt = Date()
        evaluate()
    }

    /// The transport chrome came or went. It always ends a running guide; it also holds a pending
    /// one back until the chrome has gone (the opening seconds usually keep the bar up).
    func chromeVisibilityChanged(_ visible: Bool) {
        chromeVisible = visible
        if visible {
            isShowing = false
        } else {
            evaluate()
        }
    }

    /// The overlay finished its fade-out.
    func finished() {
        isShowing = false
    }

    private func evaluate() {
        guard !isShowing else { return }
        let age = firstFrameAt.map { Date().timeIntervalSince($0) }
        guard ParentalGuideTiming.shouldShow(settingOn: PlayerOverlaySettings.shared.showParentalGuide,
                                             hasWarnings: !warnings.isEmpty,
                                             alreadyShown: shown || recentlyShownForTitle,
                                             firstFrameAge: age,
                                             chromeVisible: chromeVisible) else { return }
        shown = true
        Self.lastShown = (parentMetaId, Date())
        isShowing = true
    }

    private var recentlyShownForTitle: Bool {
        guard let last = Self.lastShown, last.parentMetaId == parentMetaId else { return false }
        return Date().timeIntervalSince(last.at) < ParentalGuideTiming.repeatSuppressionSeconds
    }
}

/// The overlay's place on screen (top-leading) and its link to the chrome. `chromeVisible` is the
/// engine's own "transport bar is up" rule.
struct ParentalGuideHost: View {
    @ObservedObject var presenter: ParentalGuidePresenter
    let chromeVisible: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if presenter.isShowing {
                ParentalGuideOverlay(warnings: presenter.warnings) { presenter.finished() }
                    .padding(.top, PlayerChipStyle.edgePadding)
                    .padding(.leading, PlayerChipStyle.edgePadding)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .onChange(of: chromeVisible, initial: true) { _, visible in
            presenter.chromeVisibilityChanged(visible)
        }
    }
}

/// The native screen's guide host: the system transport bar's visibility lives in the clock model,
/// which only this view observes (a position tick never redraws the player screen).
struct NativeParentalGuideOverlay: View {
    @ObservedObject var presenter: ParentalGuidePresenter
    @ObservedObject var clock: PlayerClockModel
    let isPaused: Bool

    var body: some View {
        ParentalGuideHost(presenter: presenter, chromeVisible: clock.transportBarVisible || isPaused)
    }
}

/// The advisories: a line growing down the leading edge, then one row per advisory fading in.
struct ParentalGuideOverlay: View {
    let warnings: [ParentalWarning]
    /// The fade-out is complete.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var overlayOpacity = 0.0
    @State private var lineProgress = 0.0
    @State private var visibleRows = 0

    private static let lineWidth: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { index, warning in
                row(warning)
                    .opacity(index < visibleRows ? 1 : 0)
            }
        }
        .padding(.leading, Theme.Spacing.md + Self.lineWidth)
        .background(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.85))
                .frame(width: Self.lineWidth)
                .scaleEffect(y: lineProgress, anchor: .top)
        }
        .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
        .opacity(overlayOpacity)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .task { await run() }
    }

    private func row(_ warning: ParentalWarning) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: warning.label)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.9))
            Text(verbatim: " \u{00B7} ")
                .foregroundStyle(.white.opacity(0.5))
            Text(verbatim: warning.severity)
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(Font.caption)
        .lineLimit(1)
    }

    private var accessibilityText: String {
        let list = warnings.map { "\($0.label), \($0.severity)" }.joined(separator: "; ")
        return String(localized: "player.parentalGuide.accessibility",
                      defaultValue: "Content advisories: \(list)",
                      comment: "VoiceOver label of the parental guide shown when playback starts. The argument lists the advisories, e.g. Violence, Moderate; Profanity, Mild.")
    }

    /// Fade in, line down, rows one after the other, hold, then the reverse. Reduce Motion: the
    /// whole block fades in and out at once. Cancelled (and silent) when the host removes the view.
    private func run() async {
        let count = warnings.count
        guard count > 0 else {
            onFinished()
            return
        }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.3)) {
                overlayOpacity = 1
                lineProgress = 1
                visibleRows = count
            }
            guard await pause(ParentalGuideTiming.holdSeconds + 0.3) else { return }
            withAnimation(.easeInOut(duration: 0.3)) { overlayOpacity = 0 }
            guard await pause(0.3) else { return }
            onFinished()
            return
        }
        withAnimation(.easeOut(duration: 0.3)) { overlayOpacity = 1 }
        guard await pause(0.3) else { return }
        withAnimation(.easeInOut(duration: 0.4)) { lineProgress = 1 }
        guard await pause(0.4) else { return }
        for shownRows in 1...count {
            guard await pause(0.08) else { return }
            withAnimation(.easeOut(duration: 0.2)) { visibleRows = shownRows }
        }
        guard await pause(ParentalGuideTiming.holdSeconds) else { return }
        for remainingRows in stride(from: count - 1, through: 0, by: -1) {
            withAnimation(.easeIn(duration: 0.15)) { visibleRows = remainingRows }
            guard await pause(0.06) else { return }
        }
        withAnimation(.easeInOut(duration: 0.3)) { lineProgress = 0 }
        guard await pause(0.3) else { return }
        withAnimation(.easeOut(duration: 0.2)) { overlayOpacity = 0 }
        guard await pause(0.2) else { return }
        onFinished()
    }

    /// Sleeps; false when the task was cancelled (the view left the screen).
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled
    }
}
