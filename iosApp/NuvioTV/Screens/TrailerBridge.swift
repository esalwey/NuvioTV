import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted the moment the full-screen trailer cover starts dismissing (see
    /// `TrailerBridgeCoverObserver`). The player-side caption hides on it, instantly.
    static let trailerBridgeCoverWillDismiss = Notification.Name("TrailerBridge.coverWillDismiss")
}

/// FEAT-32: the bridge between the description page and the full-screen trailer, modelled on the
/// official Nuvio app's sequence (frame-read from u/mrStevenx3's 2026-09-05 video, see the tracker
/// row): on the way in, the chrome fades, the title fades in bottom-left — as the title's logo art
/// where there is one, else its text — above the "Press Back" hint, the hero dims to black, and the
/// trailer cuts in from black under that caption; on the way out, the still backdrop lands slightly
/// enlarged and settles before the chrome fades back in. Before this the `fullScreenCover` simply
/// appeared over the description.
///
/// rc2 feedback (u/mrStevenx3, 2026-09-06) reshaped the caption: the shrink-into-place scale was
/// removed ("the title resizes with the still (odd)") and plain text became the title's logo art
/// where the header above it had just shown one ("the logo is missing"). His 09-07 follow-up asked
/// for the scale back ("the logo growing while the page fades to dark"), so as of 2026-09-08 the
/// description-side caption again animates opacity 0→1 and scale 1.25→1 together, under
/// `captionAnimation(to: .leaving)`, now driving the logo rather than text; the cover-side copy the
/// player draws was never scaled and stays that way.
///
/// `DetailView` owns the phase and drives every visual through the pure functions below, so the
/// choreography is testable without a view: `TrailerBridgeTests` pins the state machine and the
/// per-phase values.
enum TrailerBridgePhase: Equatable {
    /// Description page as usual.
    case idle
    /// A trailer was requested; the chrome is fading and the hero is dimming. The cover is NOT
    /// presented yet.
    case leaving
    /// The full-screen cover is up.
    case playing
    /// The cover is going (or gone); the still backdrop is enlarged and the chrome hidden, waiting
    /// for the settle.
    case returning

    /// Probe/trace label (`debug_bridge`, `TrailerZoomProbe` lines).
    var label: String {
        switch self {
        case .idle: return "idle"
        case .leaving: return "leaving"
        case .playing: return "playing"
        case .returning: return "returning"
        }
    }
}

enum TrailerBridgeEvent: Equatable {
    /// `DetailViewModel.trailerPlayback` became non-nil (Watch Trailer, auto-play, extras row).
    case trailerRequested
    /// `leaveDuration` elapsed with the request still standing.
    case leaveFinished
    /// `trailerPlayback` went back to nil: playback ended, Back pressed, or the request was
    /// withdrawn before the cover presented.
    case trailerEnded
    /// The cover has been dismissed (or was never presented) and the settle may start.
    case settle
}

enum TrailerBridgeChoreography {
    /// Chrome fade + dim before the cover presents. Nuvio's whole entry reads as ~0.6 s.
    static let leaveDuration: TimeInterval = 0.6
    /// How long the caption stays on the player after playback starts (Nuvio: a beat, then gone).
    static let captionDwell: TimeInterval = 2.5
    /// The backdrop's scale-down on return.
    static let settleDuration: TimeInterval = 0.5
    /// The chrome waits for the settle, then fades in.
    static let chromeReturnDelay: TimeInterval = 0.5
    static let chromeReturnDuration: TimeInterval = 0.3
    /// Where the still backdrop lands on return before it settles to 1.
    static let returnScale: CGFloat = 1.06

    static func next(_ phase: TrailerBridgePhase, _ event: TrailerBridgeEvent) -> TrailerBridgePhase {
        switch (phase, event) {
        case (_, .trailerRequested):
            // A request during a return restarts the choreography from where the view is.
            return .leaving
        case (.leaving, .leaveFinished):
            return .playing
        case (.leaving, .trailerEnded), (.playing, .trailerEnded):
            return .returning
        case (.returning, .settle):
            return .idle
        default:
            // Stale events (a leave timer that outlived its request, a settle with nothing to
            // settle) change nothing.
            return phase
        }
    }

    // MARK: Per-phase values. Each is the target the view animates towards on entering the phase.

    static func chromeOpacity(_ phase: TrailerBridgePhase) -> Double {
        phase == .idle ? 1 : 0
    }

    static func blackout(_ phase: TrailerBridgePhase) -> Double {
        switch phase {
        case .leaving, .playing: return 1
        case .idle, .returning: return 0
        }
    }

    static func backdropScale(_ phase: TrailerBridgePhase) -> CGFloat {
        phase == .returning ? returnScale : 1
    }

    /// The description-side caption (the player draws its own copy, see `TrailerBridgeCaption`).
    static func captionOpacity(_ phase: TrailerBridgePhase) -> Double {
        switch phase {
        case .leaving, .playing: return 1
        case .idle, .returning: return 0
        }
    }

    /// The caption arrives by shrinking into place, standing in for Nuvio's title-to-caption move.
    /// Removed in rc5 (2026-09-06) on the rc2 remark "the title resizes with the still (odd)";
    /// restored 2026-09-08 on u/mrStevenx3's 09-07 ask for "the logo growing while the page fades
    /// to dark" — rc2's motion was what he liked, so it comes back driving the logo caption instead
    /// of plain text.
    static func captionScale(_ phase: TrailerBridgePhase) -> CGFloat {
        switch phase {
        case .leaving, .playing: return 1
        case .idle, .returning: return 1.25
        }
    }

    // MARK: Animations, keyed on the phase being ENTERED. `nil` = jump.

    static func chromeAnimation(to phase: TrailerBridgePhase) -> Animation? {
        switch phase {
        case .leaving: return .easeOut(duration: 0.35)
        case .idle: return .easeOut(duration: chromeReturnDuration).delay(chromeReturnDelay)
        case .playing, .returning: return nil
        }
    }

    static func blackoutAnimation(to phase: TrailerBridgePhase) -> Animation? {
        switch phase {
        case .leaving: return .easeInOut(duration: leaveDuration)
        // The cover's own dismissal reveals the still backdrop: a hard cut, as in Nuvio.
        case .idle, .playing, .returning: return nil
        }
    }

    static func backdropAnimation(to phase: TrailerBridgePhase) -> Animation? {
        switch phase {
        case .idle: return .easeOut(duration: settleDuration)
        case .leaving, .playing, .returning: return nil
        }
    }

    static func captionAnimation(to phase: TrailerBridgePhase) -> Animation? {
        switch phase {
        case .leaving: return .easeOut(duration: 0.4).delay(0.15)
        case .idle: return .easeOut(duration: 0.2)
        case .playing, .returning: return nil
        }
    }
}

/// Title plus the "Press Back" hint, bottom-left. Drawn twice: on the description while the bridge
/// leaves, and on the full-screen player for `dwell` seconds after playback starts. Both copies are
/// placed with `placedBottomLeading()` so they occupy the same rect — see that helper.
struct TrailerBridgeCaption: View {
    let title: String
    /// The title's logo art (`MetaDetails.logo`, the same URL the description header draws). When
    /// present the caption shows the logo rather than the title text — rc2 (u/mrStevenx3): "the
    /// logo is missing (text only)", the header directly above having just shown it. Falls back to
    /// the text on an empty URL or a failed load, exactly as the header does.
    var logoURL: String? = nil
    /// Seconds before the caption fades on its own; `nil` keeps it (the description side, whose
    /// visibility the bridge phase drives instead).
    var dwell: TimeInterval? = nil
    @State private var visible = true
    /// The player's copy hides the instant the cover starts dismissing. Passed-in state does not
    /// reach a dismissing cover (its content is frozen from the outside), but state and
    /// notifications inside it stay live, so this is driven by
    /// `.trailerBridgeCoverWillDismiss` rather than a parent flag.
    @State private var coverDismissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            titleContent
            Text("Press Back to exit the trailer")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        // Legibility over a bright trailer frame without a capsule behind it.
        .shadow(color: .black.opacity(0.7), radius: 10)
        .padding(.leading, Theme.Spacing.xl + Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xl + Theme.Spacing.md)
        .opacity(visible && !coverDismissing ? 1 : 0)
        .animation(.easeOut(duration: 0.5), value: visible)
        .animation(nil, value: coverDismissing)
        .onReceive(NotificationCenter.default.publisher(for: .trailerBridgeCoverWillDismiss)) { _ in
            // Codex round 1 (P2): only the player's copy, which is a fresh instance per cover.
            // The description's copy lives for the whole visit, and latching it here suppressed
            // the caption on every later trailer request.
            guard dwell != nil else { return }
            coverDismissing = true
        }
        .accessibilityElement(children: .combine)
        .task {
            guard let dwell else { return }
            try? await Task.sleep(for: .seconds(dwell))
            visible = false
        }
    }

    /// The logo where there is one, the title text otherwise — and the title text again if the logo
    /// fails to load, which is the same two-step the description header does with the same URL (so
    /// on the way in the artwork is already in `CachedAsyncImage`'s cache).
    @ViewBuilder
    private var titleContent: some View {
        if let logoURL, !logoURL.isEmpty {
            CachedAsyncImage(string: logoURL, contentMode: .fit, failure: { titleText })
                // Roughly the header's 600x180 lockup at caption scale; `.fit` keeps wide and tall
                // logos inside the same box, and `.leading` keeps a narrow one on the left margin
                // shared with the hint below it.
                .frame(maxWidth: 360, maxHeight: 72, alignment: .leading)
                // The VStack combines its children into one element: without this the title would
                // disappear from the caption's accessibility label the moment a logo exists.
                .accessibilityLabel(Text(title))
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(Theme.Font.screenTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(1)
    }
}

extension TrailerBridgeCaption {
    /// The one placement both copies use. rc2 (u/mrStevenx3, 09-06 video ~110.9 s): at the hand-over
    /// to the cover, the description's copy and the player's copy were both on screen for two frames
    /// about 30 px apart vertically, because each site placed the caption its own way (a
    /// `.frame(maxWidth:maxHeight:alignment:)` + `.ignoresSafeArea()` on the description, an
    /// `.overlay(alignment: .bottomLeading)` on the player). Placing both through this helper makes
    /// the two rects identical by construction; each site keeps its own visibility modifiers
    /// (opacity/animation on the description, `dwell` on the player).
    func placedBottomLeading() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// Reports the START of the full-screen cover's dismissal. SwiftUI tells the presenter about a
/// system dismissal (Back) only when it has finished: the cover binding's nil, `onDismiss` and the
/// player teardown all land in the same millisecond (sim log, 2026-09-05), so for the whole
/// dismissal animation the description underneath still shows its "playing" values (black) and the
/// cover crossfades a frozen copy of its content over it. A child view controller inside the cover
/// gets `viewWillDisappear` when the dismissal begins, which is the hook the bridge needs to move
/// the description to its return values in time for the reveal.
struct TrailerBridgeCoverObserver: UIViewControllerRepresentable {
    let onWillDisappear: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onWillDisappear = onWillDisappear
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.onWillDisappear = onWillDisappear
    }

    final class Controller: UIViewController {
        var onWillDisappear: (() -> Void)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onWillDisappear?()
        }
    }
}
