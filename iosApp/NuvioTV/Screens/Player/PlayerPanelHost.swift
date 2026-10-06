import AVKit
import SwiftUI
import UIKit

// tvOS 26 removed AVPlayerViewController's classic swipe-down tabbed panel (Info · Subtitles ·
// Audio): custom info view controllers now render as a pill under the seek bar, and Subtitles /
// Audio became transport-bar popovers. Nuvio wants the classic top panel back (Infuse-style), so
// this file owns the two UIKit pieces that make an app-drawn panel possible ON TOP of the system
// player without giving up its transport bar, popovers, or contextual actions:
//
//  - `NativePlayerHostController` — container VC whose only child is the `AVPlayerViewController`.
//    Remote presses and swipes are dispatched to the FOCUSED view's responder chain; gesture
//    recognizers on any superview in that chain observe them too, so recognizers on this container's
//    view see the Down press / down swipe regardless of which internal AVPVC view holds focus.
//    (`contentOverlayView` is the wrong place — it sits below the controls, outside the chain.)
//  - `PlayerPanelHostController` — the presented panel. Presenting (`.overFullScreen`, clear
//    background) gives focus containment for free (AVPVC's focus environment goes inactive so the
//    transport bar can't react to the panel's presses), keeps the video rendering underneath, and
//    lets us swallow Menu deterministically so it closes the panel instead of popping the player.
final class NativePlayerHostController: UIViewController, UIGestureRecognizerDelegate {
    let playerVC = AVPlayerViewController()
    /// Asked to open the panel (Down press / down swipe while nothing is presented). The owner
    /// builds the panel content and calls `present(panel:)`.
    var onOpenPanel: (() -> Void)?
    /// Fired after a presented panel has been dismissed (any way: Menu, swipe up, programmatic).
    var onPanelClosed: (() -> Void)?
    /// Menu press hook: return true to consume it — the Up Next card cancelled autoplay and is
    /// leaving for the details page — or false to let the press continue up to SwiftUI, whose
    /// `fullScreenCover` pops the player exactly as today.
    var onMenuPress: (() -> Bool)?
    /// D-pad Down press hook, asked before the panel opens: return true when the Up Next card
    /// consumed it (play the next episode now / choose a source).
    var onDownPress: (() -> Bool)?
    /// Whether a Down press is wanted by `onDownPress` right now (the Up Next card is up). Only
    /// consulted when there is no app panel (`onOpenPanel == nil`, decision D3 on the native
    /// engine): the Down recognizers then stand aside so a Down press or swipe reaches
    /// AVPlayerViewController and opens its content tabs. nil = always wanted (old behaviour).
    var claimsDownPress: (() -> Bool)?
    /// Select press hook for the Up Next card's "OK cancels" (mpv parity — the system player would
    /// otherwise just toggle pause whenever the "Cancel" action isn't the focused one). The press is
    /// observed, never consumed: it may be activating a focused contextual action ("Play Now"), so
    /// `onSelectPress` hands back a token (nil = the card isn't up) and `onSelectSettled` gets it a
    /// beat later, after that action had its turn — the engine then acts only if none ran.
    var onSelectPress: (() -> Int?)?
    var onSelectSettled: ((Int) -> Void)?
    private var swallowMenuRelease = false
    private(set) var panelHost: PlayerPanelPresenting?
    private var downPress: UITapGestureRecognizer!
    private var downSwipe: UISwipeGestureRecognizer!
    private var selectPress: UITapGestureRecognizer!
    /// Passive observer of ordinary remote use (never cancels or delays a press): proof someone is
    /// watching, which resets the "Still watching?" run (NE-5 — the native path had no reset point).
    private var interactionPress: UITapGestureRecognizer!
    /// How long a Select waits for a focused contextual action to handle the same press.
    private static let selectSettleDelay: TimeInterval = 0.2

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "player.native"
        addChild(playerVC)
        playerVC.view.frame = view.bounds
        playerVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)

        downPress = UITapGestureRecognizer(target: self, action: #selector(handleDownPress))
        downPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.downArrow.rawValue)]
        downPress.delegate = self
        downSwipe = UISwipeGestureRecognizer(target: self, action: #selector(handleOpenGesture))
        downSwipe.direction = .down
        downSwipe.delegate = self
        view.addGestureRecognizer(downPress)
        view.addGestureRecognizer(downSwipe)

        // Select: observed like the interaction presses below (never cancels or delays the press
        // for the system player), plus the Up Next card's "OK cancels".
        selectPress = UITapGestureRecognizer(target: self, action: #selector(handleSelectPress))
        selectPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        selectPress.cancelsTouchesInView = false
        selectPress.delaysTouchesEnded = false
        selectPress.delegate = self
        view.addGestureRecognizer(selectPress)

        // Menu stays out of this set: it is owned by `pressesBegan` below and the cover's exit.
        interactionPress = UITapGestureRecognizer(target: self, action: #selector(handleInteraction))
        interactionPress.allowedPressTypes = [
            UIPress.PressType.playPause, .leftArrow, .rightArrow, .upArrow,
        ].map { NSNumber(value: $0.rawValue) }
        interactionPress.cancelsTouchesInView = false
        interactionPress.delaysTouchesEnded = false
        interactionPress.delegate = self
        view.addGestureRecognizer(interactionPress)
    }

    @objc private func handleInteraction() {
        NextEpisodeEngine.consecutiveAutoPlays = 0
    }

    /// Our panel or one of the system player's own popovers is up: those own the remote.
    private var isShowingOverlay: Bool {
        panelHost != nil || presentedViewController != nil || playerVC.presentedViewController != nil
    }

    @objc private func handleSelectPress() {
        NextEpisodeEngine.consecutiveAutoPlays = 0
        guard !isShowingOverlay, let token = onSelectPress?() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectSettleDelay) { [weak self] in
            // Re-checked: the same press may have opened one of the system player's menus.
            guard let self, !self.isShowingOverlay else { return }
            self.onSelectSettled?(token)
        }
    }

    /// Down press: the Up Next card first (play now), else the top panel — same order as mpv.
    @objc private func handleDownPress() {
        NextEpisodeEngine.consecutiveAutoPlays = 0
        guard panelHost == nil, presentedViewController == nil,
              playerVC.presentedViewController == nil else { return }
        if onDownPress?() == true { return }
        onOpenPanel?()
    }

    /// With no app panel to open, the down swipe never begins and the Down press begins only when
    /// the Up Next card claims it, so neither can cancel the press for the system player's content
    /// tabs (Episodes / Stream Info / Chapters).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard onOpenPanel == nil else { return true }
        if gestureRecognizer === downSwipe { return false }
        if gestureRecognizer === downPress { return claimsDownPress?() ?? true }
        return true
    }

    /// Recognize alongside AVPlayerViewController's own recognizers — never block the system player.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleOpenGesture() {
        // Not while our panel is up, and not while the system player has one of ITS popovers
        // (Subtitles / Audio menus) presented — a Down there navigates the popover's rows and
        // must not also open the panel over it (`presentedViewController` reports ancestors'
        // presentations, not the child's, so check the player VC explicitly).
        guard panelHost == nil, presentedViewController == nil,
              playerVC.presentedViewController == nil else { return }
        onOpenPanel?()
    }

    // This controller sits between AVPlayerViewController and the SwiftUI host in the focused
    // responder chain, so a Menu the system player did not consume (transport bar hidden) passes
    // through here on its way to the cover's default exit. Not while our panel or one of AVPVC's
    // own popovers is up — those own Menu themselves (same guard as `handleOpenGesture`).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }),
           panelHost == nil, presentedViewController == nil, playerVC.presentedViewController == nil,
           onMenuPress?() == true {
            swallowMenuRelease = true
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Swallow the matching Menu release too, so nothing above sees a half press.
        if swallowMenuRelease, presses.contains(where: { $0.type == .menu }) {
            swallowMenuRelease = false
            return
        }
        super.pressesEnded(presses, with: event)
    }

    /// Present the panel over the live player. `crossDissolve` fades the host; the panel content
    /// animates its own slide-in. Reduce Motion → no animation at all.
    func present<Content: View>(panel: PlayerPanelHostController<Content>) {
        guard panelHost == nil, presentedViewController == nil else { return }
        panel.modalPresentationStyle = .overFullScreen
        panel.modalTransitionStyle = .crossDissolve
        panel.onClosed = { [weak self] in
            self?.panelHost = nil
            self?.onPanelClosed?()
        }
        panelHost = panel
        present(panel, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func closePanel(animated: Bool) {
        panelHost?.close(animated: animated)
    }
}

/// Type-erased handle on a presented panel host (the hosting controller itself is generic).
protocol PlayerPanelPresenting: AnyObject {
    func close(animated: Bool)
    /// Close, then run `action` once the panel is gone (an action that replaces playback must not
    /// run under it).
    func close(animated: Bool, then action: (() -> Void)?)
}

/// Hosts the SwiftUI panel over the player. Menu closes the panel (swallowed here so it never
/// reaches the SwiftUI `fullScreenCover` that would pop the whole player); swipe up also closes.
final class PlayerPanelHostController<Content: View>: UIHostingController<Content>, PlayerPanelPresenting {
    var onClosed: (() -> Void)?
    /// A swipe up closes the panel (the top panel). Set before presenting.
    var closesOnSwipeUp = true
    private var closing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.panel"
        // The mpv chrome's focus layer moves focus up with the swipe instead (`closesOnSwipeUp`).
        guard closesOnSwipeUp else { return }
        let up = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
        up.direction = .up
        view.addGestureRecognizer(up)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            close(animated: true)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Swallow the matching Menu release too, so nothing below sees a half press.
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesEnded(presses, with: event)
    }

    @objc private func handleSwipeUp() { close(animated: true) }

    func close(animated: Bool) {
        close(animated: animated, then: nil)
    }

    func close(animated: Bool, then action: (() -> Void)?) {
        guard !closing else {
            // Already going away: the action still runs, once the dismissal had time to finish.
            if let action {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { action() }
            }
            return
        }
        closing = true
        let onClosed = onClosed
        dismiss(animated: animated && !UIAccessibility.isReduceMotionEnabled) {
            onClosed?()
            action?()
        }
    }
}
