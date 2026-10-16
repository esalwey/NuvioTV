import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

// Siri Remote grammar for the mpv engine (PLY-A2/A3/A4, F3/F5/F6/F7, docs/player-spec.md): the same
// answers as Apple's player and the native engine, which this one is rebuilt from the measurements
// of (docs/player-spec.md, section 9, the owner's recording of the system player). Every layer Back
// can close comes before leaving: Up Next card → Stream Info → scrub (back to the original time) →
// hold → chrome → exit. Scrubbing state lives in `MPVPlaybackState` (extensions hold no stored
// properties). All timings and sizes are `PlayerSpec`'s, each with its source.
//
// What the system player does, and so does this one:
//  - a click on the left / right edge skips exactly ±10 s — the head and the time move at once — and
//    shows the circular-arrow glyph beside the elapsed time; with the chrome away it brings up the
//    bar alone (no title, buttons or pills), which hides `PlayerSpec.Chrome.skimLifetime` after the
//    last click. The third back skip of a run turns subtitles on for 11 s and says so under the
//    remaining time. Clicks in quick succession seek by keyframe and settle on one exact seek after
//    the last, so the decoder is never asked for a pile of exact seeks;
//  - Select pauses and resumes, always. A skip chip ("Skip Intro") is the system's focusable contextual
//    action: Up moves "focus" onto it, Select then skips, anything else hands the focus back;
//  - a hold on an edge freezes the picture on the frame it stopped on and runs the head by its own
//    clock in three tiers (8, 24 then 48 s per second, a bare digit in the badge from the second tier
//    on); the release seeks there, a spinner holds the badge's place until the picture is back, and
//    playback goes on if it was going;
//  - swiping on the touch surface only shows the chrome while playing; while paused a touch fades the
//    title, the buttons and the pills out and rests a knob on the playhead, and a swipe flicks the
//    head along the bar (the picture stays frozen) until Select commits it;
//  - the chrome hides `PlayerSpec.Chrome.autoHideDelay` after the last interaction while playing and
//    stays up while paused; a pause brings it in after `pauseRevealDelaySec`.
extension MPVTVPlayerViewController: UIGestureRecognizerDelegate {
    /// Identifies the touch-surface pan this extension installs (installed once per view).
    private static let transportPanName = "nuvio.mpv.transportPan"
    /// An arrow held at least this long is a hold (scan), not a click.
    private static let holdThresholdSec: TimeInterval = PlayerSpec.Remote.holdThresholdSec
    /// A click left/right: one exact ±10 s seek (a step of the scrub head while scrubbing).
    private static let clickSeekSec: Double = PlayerSpec.Remote.skipSeconds
    /// A swipe moves the scrub head only after this much travel (points), and not within
    /// `edgeDriftWindowSec` of an edge press: a click's own drift is not a scrub.
    private static let scrubStartTravel: Double = 24
    private static let edgeDriftWindowSec: TimeInterval = 0.4
    /// Clicks closer together than this are one burst: keyframe seeks, then one exact seek.
    private static let skipBurstGapSec: TimeInterval = 0.5
    private static let skipSettleDelaySec: TimeInterval = 0.25

    /// Down swipe: the content tabs (Info, Chapters, Episodes, Stream Info), as on the system player.
    @objc func handleSwipeDown() {
        guard presentedViewController == nil, !state.isScrubbing, !state.isEnded, !state.playbackErrorShown else { return }
        openChrome(.tabs)
    }

    /// Up swipe: with the bar showing, focus moves up to its buttons; otherwise the bar shows.
    @objc func handleSwipeUp() {
        guard presentedViewController == nil, !state.isScrubbing, !state.isEnded, !state.playbackErrorShown else { return }
        upRequested()
    }

    /// Up, by press or by swipe: the first one shows the bar; with a skip chip up, the next moves
    /// "focus" onto it; then (or with no chip) the one after moves focus up to the bar's buttons.
    private func upRequested() {
        guard chromeIsShowing else {
            flashControls()
            return
        }
        if state.skipPrompt != nil, !state.skipChipFocused {
            state.skipChipFocused = true
            flashControls()
            return
        }
        openChrome(.transport)
    }

    /// The full transport chrome is on screen (shown by an interaction, or held by a pause). The bar
    /// alone that a skip click brings up is not it.
    private var chromeIsShowing: Bool {
        state.controlsVisible || state.pauseChromeShown
    }

    /// Hands focus to the chrome's focus layer (menus, content tabs): a hold stops, and the track
    /// lists are refreshed (the async walk fills them if this raced the events).
    private func openChrome(_ entry: PlayerChromeEntry) {
        if state.scan != nil { endScan(commit: true) }
        refreshTracksAsync()
        state.skipChipFocused = false
        state.fingerDown = false
        state.knobShown = false
        cancelSkim()
        // The layer opens over the bar when it was up. The transport buttons bring the bar up first
        // when it was away; the content tabs do not: the system's tab view slides up from the bottom
        // edge on its own, with no transport bar (29.5 s of the owner's recording).
        let barWasShowing = chromeIsShowing
        if entry == .transport, !barWasShowing { flashControls() }
        onOpenChrome?(entry, barWasShowing)
    }

    /// Show a skip prompt while the playhead is inside a segment (leaving a 1s tail so the button
    /// disappears cleanly at the end). A segment the viewer picked under Automatic Skipping is
    /// skipped here instead, once, without ever offering the chip (`AutoSkipTracker`).
    func updateSkipPrompt(position: Double, durationSec: Double) {
        // Upstream 80860602f: an error/placeholder clip (shared short-placeholder rule) offers no skip.
        let placeholder = WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000))
        if !placeholder, autoSkipIfNeeded(position: position, durationSec: durationSec) {
            if state.skipPrompt != nil { state.skipPrompt = nil }
            return
        }
        let prompt = placeholder ? nil
            : SkipPlanner.prompt(position: position, durationSec: durationSec, segments: skipSegments)
        if prompt != state.skipPrompt { state.skipPrompt = prompt }
    }

    /// Automatic Skipping: skips the segment the tracker picks for this tick, shows the "Intro
    /// skipped" confirmation, and reports whether it did. Same rules, tracker and confirmation as the
    /// native screen.
    private func autoSkipIfNeeded(position: Double, durationSec: Double) -> Bool {
        guard let skip = autoSkipTracker.evaluate(
            position: position,
            durationSec: durationSec,
            now: ProcessInfo.processInfo.systemUptime,
            // Not under an open panel either: the skip may end in the next episode replacing the player.
            isPlaying: !state.isPaused && !state.isScrubbing && !state.isEnded && !state.playbackErrorShown
                && !state.panelOpen && state.scan == nil,
            segments: skipSegments,
            enabledKinds: AutoSkipSettings.enabledKinds()
        ) else { return false }
        seekForSkip(targetSec: skip.action.targetSec,
                    isCredits: UpNextTrigger.outroTypes.contains(SkipPlanner.normalized(skip.segment.type)),
                    skipsToPostCredits: skip.action.skipsToPostCredits,
                    automatic: true)
        state.autoSkipToast = AutoSkipToast(text: SkipPlanner.autoSkipMessage(forKind: skip.kind))
        return true
    }

    // MARK: - Touch surface

    // The core's `viewDidLoad` belongs to another batch; the pan goes in before the first appearance
    // instead (idempotent — a re-appearance after the end screen finds it already there).
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installTransportPanIfNeeded()
    }

    private func installTransportPanIfNeeded() {
        let installed = view.gestureRecognizers?.contains(where: { $0.name == Self.transportPanName }) ?? false
        guard !installed else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTransportPan(_:)))
        pan.name = Self.transportPanName
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // Never steal the touches (or the presses) from the rest of the responder chain.
        pan.cancelsTouchesInView = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    /// Only a mostly-horizontal swipe begins the pan, so the down swipe (top panel) keeps working.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.name == Self.transportPanName,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let translation = pan.translation(in: view)
        return abs(translation.x) > abs(translation.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.name == Self.transportPanName || otherGestureRecognizer.name == Self.transportPanName
    }

    /// Resting a finger on the touch surface shows the controls (spec gap 3) while playing — showing
    /// chrome is not an action, so this is fine during playback (HIG: never act on a tap) — and, while
    /// paused, turns the chrome into the bar alone with a knob on the playhead.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .indirect }), presentedViewController == nil,
           !state.playbackErrorShown, !state.isEnded {
            fingerTouched()
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .indirect }) { fingerLifted() }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .indirect }) { fingerLifted() }
        super.touchesCancelled(touches, with: event)
    }

    /// A finger landed. The chrome answers `touchReactionSec` later (4.500 s the finger, 4.567 s the
    /// first frame of the fade in the owner's recording) — and not at all when a button went down in
    /// between: a click on Select or an edge lands a finger on the surface too, and neither shows the
    /// full chrome nor the knob (the chrome came in 0.3 s after a pause, with no touch reaction, and
    /// a skip click with the chrome away showed the bar alone).
    private func fingerTouched() {
        state.fingerDown = true
        let began = ProcessInfo.processInfo.systemUptime
        touchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.fingerDown else { return }
            if self.lastPressUptime >= began - 0.05 { return }
            if self.state.isPaused {
                self.enterScrubChrome()
            } else {
                self.flashControls()
            }
        }
        touchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerSpec.Scrub.touchReactionSec, execute: work)
    }

    private func fingerLifted() {
        touchWork?.cancel()
        touchWork = nil
        guard state.fingerDown else { return }
        state.fingerDown = false
        knobWork?.cancel()
        knobWork = nil
        // The knob collapses (6.083 to 6.2 s) and the pause glyph comes back.
        state.knobShown = false
        if state.scrubChrome { armScrubIdle() }
    }

    /// A finger on a paused player: the title, the buttons and the pills fade out (4.567 to 4.667 s of
    /// the owner's recording), the bar and its labels stay, and a finger that rests there shows the
    /// knob. The bar stays like this until Select commits, Back cancels, or it has been left alone.
    private func enterScrubChrome() {
        revealPausedChromeNow()
        if !state.scrubChrome {
            state.chromeCascade = .show
            state.scrubChrome = true
        }
        armScrubIdle()
        knobWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.fingerDown, self.state.isPaused, !self.state.isScrubbing else { return }
            self.state.knobShown = true
        }
        knobWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerSpec.Scrub.knobDelaySec, execute: work)
    }

    /// The bar alone gives way to the full chrome again: after a commit or a cancel, or when a touch
    /// was left alone for `PlayerSpec.Scrub.idleReturnSec`.
    private func leaveScrubChrome() {
        scrubIdleWork?.cancel()
        scrubIdleWork = nil
        knobWork?.cancel()
        knobWork = nil
        state.knobShown = false
        guard state.scrubChrome else { return }
        state.chromeCascade = .show
        state.scrubChrome = false
    }

    private func armScrubIdle() {
        scrubIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.scrubChrome, !self.state.isScrubbing, !self.state.fingerDown else { return }
            self.leaveScrubChrome()
        }
        scrubIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerSpec.Scrub.idleReturnSec, execute: work)
    }

    /// How far a swipe moves the head, as a share of the duration per full width of the touch
    /// surface: fine for a slow swipe, coarse for a quick flick, smoothly in between
    /// (`PlayerSpec.Scrub`).
    private static func scrubGain(speed: Double) -> Double {
        let span = PlayerSpec.Scrub.speedFast - PlayerSpec.Scrub.speedSlow
        let t = min(max((speed - PlayerSpec.Scrub.speedSlow) / span, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return PlayerSpec.Scrub.gainSlow + (PlayerSpec.Scrub.gainFast - PlayerSpec.Scrub.gainSlow) * eased
    }

    /// Paused: a horizontal swipe moves the scrub head (Select/Play commits, Back cancels). The head
    /// jumps with the finger and glides on after it leaves. Playing: the swipe only shows the chrome.
    @objc private func handleTransportPan(_ pan: UIPanGestureRecognizer) {
        guard mpv != nil, presentedViewController == nil, !state.playbackErrorShown, !state.isEnded else { return }
        switch pan.state {
        case .began:
            NextEpisodeEngine.consecutiveAutoPlays = 0
            // A swipe has begun: a finger that moves shows no knob, and a glide still running stops.
            cancelScrubTail()
            knobWork?.cancel()
            knobWork = nil
            // The scrub itself starts once the finger has really travelled (`changed`): a click on an
            // edge drifts a little under the finger and must stay a skip.
            if !state.isPaused { flashControls() }
        case .changed:
            guard state.isPaused else { return }
            if !state.isScrubbing {
                let travel = abs(Double(pan.translation(in: view).x))
                let sinceEdgePress = ProcessInfo.processInfo.systemUptime - lastEdgePressUptime
                guard travel >= Self.scrubStartTravel, sinceEdgePress > Self.edgeDriftWindowSec else { return }
                beginScrub()
            }
            guard state.isScrubbing else { return }
            let dx = Double(pan.translation(in: view).x)
            pan.setTranslation(.zero, in: view)
            let width = max(Double(view.bounds.width), 1)
            let speed = abs(Double(pan.velocity(in: view).x)) / width
            let seconds = dx / width * Self.scrubGain(speed: speed) * max(state.durationSec, 1)
            moveScrubTarget(by: seconds)
        case .ended, .cancelled, .failed:
            finishScrubGesture()
        default:
            break
        }
    }

    // MARK: - Siri-remote transport

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        lastPressUptime = ProcessInfo.processInfo.systemUptime
        for press in presses {
            // "Focus" stays on the skip chip only for Select (skip) and Up (on to the buttons).
            if press.type != .select, press.type != .upArrow, state.skipChipFocused {
                state.skipChipFocused = false
            }
            // Keyboard: Space toggles play (HIG Playing video).
            if let key = press.key, key.keyCode == .keyboardSpacebar {
                playPausePressed()
                handled = true
                continue
            }
            switch press.type {
            case .playPause:
                // The Up Next countdown pauses with the video.
                playPausePressed()
                handled = true
            case .select:
                selectPressed()
                handled = true
            case .leftArrow:
                arrowPressBegan(-1); handled = true
            case .rightArrow:
                arrowPressBegan(1); handled = true
            case .downArrow:
                if state.upNextDown?() == true {
                    // Up Next card: play now ("Choose a Source" when none was found).
                    handled = true
                } else if state.isScrubbing {
                    // Mid-scrub, Down does nothing (spec §6.9.4); Select/Play or Back resolve it first.
                    handled = true
                } else if presentedViewController == nil {
                    // Same gesture as the native player: Down opens the content tabs — during a
                    // skip prompt too (F6: Select skips now).
                    if !state.isEnded, !state.playbackErrorShown { openChrome(.tabs) }
                    handled = true
                }
            case .upArrow:
                if state.isScrubbing {
                    // Mid-scrub, Up does nothing either; Select/Play or Back resolve it first.
                    handled = true
                } else if presentedViewController == nil {
                    // The system player's grammar: the first Up shows the bar, the next one moves
                    // focus up to its buttons (Subtitles, Audio, the app's menus) - by way of the skip
                    // chip when one is up.
                    if !state.isEnded, !state.playbackErrorShown {
                        upRequested()
                    } else {
                        flashControls()
                    }
                    handled = true
                }
            case .menu:
                if menuPressed() {
                    // A layer closed: the player stays, and nothing above may see the release.
                    swallowMenuRelease = true
                }
                handled = true
            default:
                break
            }
        }
        if handled {
            // Any remote interaction proves someone's watching — reset the Still Watching counter.
            NextEpisodeEngine.consecutiveAutoPlays = 0
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        if swallowMenuRelease, presses.contains(where: { $0.type == .menu }) {
            swallowMenuRelease = false
            handled = true
        }
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            arrowPressEnded(cancelled: false); handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        if swallowMenuRelease, presses.contains(where: { $0.type == .menu }) {
            swallowMenuRelease = false
            handled = true
        }
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            arrowPressEnded(cancelled: true); handled = true
        }
        if !handled { super.pressesCancelled(presses, with: event) }
    }

    /// Back, one layer per press (PLY-A2, F3, spec gap 1). Returns true when a layer closed and the
    /// player stays; false when the press left the player.
    private func menuPressed() -> Bool {
        // Up Next card: dismiss it and keep watching the credits (PLY-A4/F5).
        if state.upNextMenu?() == true { return true }
        // The error card and the end screen own Back: never swallow it under them.
        if state.playbackErrorShown || state.isEnded {
            onExit?()
            return false
        }
        if state.showStreamInfo {
            state.showStreamInfo = false
            return true
        }
        // The chrome's focus layer normally takes Back itself (it is presented over this controller).
        if state.panelOpen, presentedViewController != nil { return true }
        if state.isScrubbing {
            cancelScrub()
            return true
        }
        if state.scan != nil {
            // Back during a hold: the head goes back where the picture stopped.
            endScan(commit: false)
            return true
        }
        if state.controlsVisible || state.pauseChromeShown || state.skimVisible {
            hideChrome()
            return true
        }
        onExit?()
        return false
    }

    private func selectPressed() {
        if state.upNextSelect?() == true {
            // Up Next card: play the next episode now (PLY-A4/F5).
            return
        }
        if state.isScrubbing {
            // Commit the scrub and play from there, like the system player.
            commitScrub(resume: true)
            return
        }
        if state.scan != nil {
            endScan(commit: true)
            return
        }
        if let prompt = state.skipPrompt, state.skipChipFocused {
            // Skip Intro / Recap / Outro, once "focus" was moved onto the chip with Up (F6).
            state.skipChipFocused = false
            performSkip(prompt)
            return
        }
        // Select is Pause / Play, whatever is on screen: a chip that stays up for a whole intro must
        // not take the pause away.
        playOrPause()
    }

    /// Play/Pause as the remote answers it: commits a scrub, stops a hold, else toggles. Also what the
    /// chrome's focus layer calls (`MPVPlaybackState.togglePlayPause`) for a press that lands while focus
    /// sits in the bar or in a tab.
    func playPausePressed() {
        if state.isScrubbing {
            commitScrub(resume: true)
            return
        }
        if state.scan != nil {
            endScan(commit: true)
            return
        }
        playOrPause()
    }

    /// Pause freezes the picture now and the chrome follows after its delay (`updatePauseReveal`);
    /// Play brings the chrome back for its idle time, in the quick cascade.
    private func playOrPause() {
        leaveScrubChrome()
        let pausing = !cachedProps().paused
        togglePause()
        if !pausing { flashControls() }
    }

    private func performSkip(_ prompt: SkipPrompt) {
        seekForSkip(targetSec: prompt.targetSec, isCredits: prompt.isCredits,
                    skipsToPostCredits: prompt.skipsToPostCredits)
        state.skipPrompt = nil
        flashControls()
    }

    /// The seek behind a manual and an automatic skip alike.
    private func seekForSkip(targetSec: Double, isCredits: Bool, skipsToPostCredits: Bool, automatic: Bool = false) {
        // Skip Outro on credits that run to the end of the file = the next episode now (Up Next),
        // not a seek onto the last frame. Credits followed by a scene seek to the scene instead.
        if isCredits, !skipsToPostCredits, state.upNextSkipCredits?(targetSec, automatic) == true { return }
        // Clamp against duration: a skip-outro target past EOF wedges mpv.
        // durationSec is still 0 before the first duration event — seek unclamped then.
        let target = state.durationSec > 0 ? min(targetSec, state.durationSec - 0.5) : targetSec
        seekAbsolute(target)
    }

    /// Back with the chrome up: hide the transport bar, and while paused the pause card too (F3).
    private func hideChrome() {
        hideWork?.cancel()
        hideWork = nil
        cancelSkim()
        leaveScrubChrome()
        state.skipChipFocused = false
        state.controlsVisible = false
        state.barTinted = false
        if state.isPaused { state.pauseChromeDismissed = true }
    }

    // MARK: Arrows: click, hold, scan

    /// An arrow went down. Click or hold is decided by how long it stays down: a click acts on the
    /// release, a hold once `holdThresholdSec` has passed.
    private func arrowPressBegan(_ dir: Double) {
        // Going backward means the user is still watching — abandon next-episode autoplay.
        if dir < 0 { state.upNextCancel?() }
        lastEdgePressUptime = ProcessInfo.processInfo.systemUptime
        seekTimer?.invalidate()
        seekDirection = dir
        seekHoldCount = 0
        let timer = Timer(timeInterval: Self.holdThresholdSec, repeats: false) { [weak self] _ in
            self?.arrowHoldBegan()
        }
        RunLoop.main.add(timer, forMode: .common)
        seekTimer = timer
    }

    private func arrowHoldBegan() {
        guard seekDirection != 0, mpv != nil else { return }
        seekHoldCount = 1
        seekTimer = nil
        if state.isScrubbing {
            // A hold on top of a touch-surface scrub steps the head once, like a click would; the
            // scrub still waits for Select / Play, and Back still cancels it.
            moveScrubTarget(by: seekDirection * Self.clickSeekSec)
            return
        }
        // Fast-forward / rewind: the picture freezes and the head runs for as long as the edge is held.
        beginScan(seekDirection)
    }

    private func arrowPressEnded(cancelled: Bool) {
        guard seekDirection != 0 else { return }
        let dir = seekDirection
        let wasHold = seekHoldCount > 0
        seekTimer?.invalidate()
        seekTimer = nil
        seekDirection = 0
        seekHoldCount = 0
        if wasHold {
            // A hold ends with the finger: the picture goes where the head got to (a cancelled press
            // goes back to where it stopped).
            if state.scan != nil { endScan(commit: !cancelled) }
            return
        }
        guard !cancelled else { return }
        arrowClicked(dir)
    }

    private func arrowClicked(_ dir: Double) {
        if state.scan != nil {
            endScan(commit: true)
            return
        }
        if state.isScrubbing {
            moveScrubTarget(by: dir * Self.clickSeekSec)
            return
        }
        skip(by: dir * Self.clickSeekSec)
        showSkipGlyph(dir)
        revealSkim()
    }

    /// The ±10 s skip: one exact seek to the current time ± 10 s, with the play / pause state left as
    /// it was (docs/player-spec.md, "Skip"). The head and the time move at once, as the system bar's
    /// do — they used to wait for the core's own position events, which are held back while a seek
    /// is in flight — and the clicks in a row start from where the last one aimed, so they add up
    /// exactly (+10, +20, +30) whatever the decoder has caught up with.
    func skip(by seconds: Double) {
        guard mpv != nil else { return }
        var origin = cachedProps().position
        // A resume seek still in flight: the playhead has not got to where the file is resuming yet.
        if let resume = resumeTargetSec, origin + 5 < resume { origin = resume }
        var target = max(origin + seconds, 0)
        // A skip forward past the end lands on the last half second, which then ends the file.
        if state.durationSec > 0 { target = min(target, max(state.durationSec - 0.5, 0)) }
        // Skipping back replays a section: the third back skip of a run turns subtitles on for it.
        if seconds < 0 { registerBackSkip() } else { backSkipRun = 0 }
        // The bar's fill takes its lavender after a click (18.085 s of the owner's recording).
        state.barTinted = true
        updateProps { $0.position = target }
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) { state.positionSec = target }
        seekForSkipClick(to: target)
    }

    /// The seek behind a ±10 s click. A lone click is one exact seek, as before. Clicks in quick
    /// succession (or while the last seek is still out) would each ask the decoder for an exact
    /// frame, and every one of them restarts from the previous keyframe - on a 4K stream that piles up
    /// and the picture lands late. The head and the time already show the total; the core is sent
    /// keyframe seeks while the clicks keep coming, and one exact seek `skipSettleDelaySec` after the
    /// last of them.
    private func seekForSkipClick(to target: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let props = cachedProps()
        let burst = now - lastSkipClickUptime < Self.skipBurstGapSec || props.seekReplies > 0 || props.seeking
        lastSkipClickUptime = now
        skipExactWork?.cancel()
        skipExactWork = nil
        guard burst else {
            postSeek(String(format: "%.3f", target), mode: "absolute+exact")
            return
        }
        postSeek(String(format: "%.3f", target), mode: "absolute+keyframes")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mpv != nil else { return }
            self.skipExactWork = nil
            self.postSeek(String(format: "%.3f", target), mode: "absolute+exact")
        }
        skipExactWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.skipSettleDelaySec, execute: work)
    }

    /// The system's skip glyph: the circular arrow with the seconds in it, on the right of the elapsed
    /// time for a forward click and on its left for a back one. It lives `glyphLifetimeSec` and
    /// there is no running total (docs/player-spec.md, "Skip").
    func showSkipGlyph(_ dir: Double, seconds: Double = PlayerSpec.Remote.skipSeconds) {
        let direction = dir < 0 ? -1 : 1
        let previous = state.skipHint
        state.skipHint = SkipHint(id: (previous?.id ?? 0) &+ 1, direction: direction,
                                  seconds: Int(seconds.rounded()))
        skipHintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.state.skipHint = nil }
        skipHintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerSpec.Skip.glyphLifetimeSec, execute: work)
    }

    /// A ±10 s click with the chrome away brings up the bar alone (bar, labels and glyph: no title,
    /// buttons, pills or clock), which hides `PlayerSpec.Chrome.skimLifetime` after the last click.
    /// With the full chrome up a click restarts nothing: the chrome hid 0.72 s after one.
    func revealSkim() {
        guard !chromeIsShowing, !state.panelOpen else { return }
        if !state.skimVisible { state.chromeCascade = .show }
        state.skimVisible = true
        skimWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.skimWork = nil
            self.state.skimVisible = false
            if !self.state.controlsVisible { self.state.barTinted = false }
        }
        skimWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerSpec.Chrome.skimLifetime, execute: work)
    }

    private func cancelSkim() {
        skimWork?.cancel()
        skimWork = nil
        if state.skimVisible { state.skimVisible = false }
    }

    // MARK: Hold (rewind / fast-forward)

    /// A hold begins: the picture freezes on the frame it stopped on (the core is paused, and the
    /// player still reads as playing), the head runs by its own clock (`MPVScan`: three tiers, a badge
    /// after 0.2 s, a digit from the second tier on) and the full chrome stays up for the whole hold.
    /// Nothing is seeked until the release: there is no thumbnail and no picture on the way.
    private func beginScan(_ dir: Double) {
        guard state.scan == nil, mpv != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        skipExactWork?.cancel()
        skipExactWork = nil
        scanResumesPlayback = !cachedProps().paused
        if scanResumesPlayback {
            scanPausedCore = true
            requestPause(true)
        }
        state.scan = MPVScan(direction: dir < 0 ? -1 : 1, startPosition: state.displayPosition(at: now),
                             startUptime: now, duration: state.durationSec)
        flashControls()
    }

    /// The release (or Select, or Play/Pause): the picture goes where the head got to — one exact
    /// seek, the spinner on the badge's side until it has landed — and playback goes on if it was
    /// going. `commit: false` (Back) leaves things where the picture stopped.
    func endScan(commit: Bool) {
        guard let scan = state.scan else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let target = commit ? scan.position(at: now) : scan.startPosition
        let resume = scanResumesPlayback
        state.scan = nil
        scanPausedCore = false
        scanResumesPlayback = false
        if abs(target - scan.startPosition) >= 0.5 {
            // Optimistic: the bar sits on the new time until the seek's own events confirm it.
            updateProps { $0.position = target }
            state.positionSec = target
            seekAbsolute(target, exact: true)
            seekSettleMinUntil = now + 0.12
            seekSettleDeadline = now + 5
            state.seekSettleDirection = scan.direction
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.pollSeekSettle() }
        }
        if resume { requestPause(false) }
        refreshState()
        flashControls()
    }

    /// The spinner of a hold's release goes once its seek has been answered and the picture is
    /// there: not before `seekSettleMinUntil`, and at `seekSettleDeadline` whatever happens.
    func settleSeekSpinner(_ snap: PropSnapshot, now: TimeInterval) {
        guard state.seekSettleDirection != nil else { return }
        let answered = snap.seekReplies == 0 && !snap.seeking
        if (answered && now >= seekSettleMinUntil) || now >= seekSettleDeadline {
            state.seekSettleDirection = nil
        }
    }

    /// Looks again every tenth of a second until the spinner has gone (the state poll runs twice a
    /// second, which would hold it up to half a second after the picture).
    private func pollSeekSettle() {
        guard state.seekSettleDirection != nil else { return }
        settleSeekSpinner(cachedProps(), now: ProcessInfo.processInfo.systemUptime)
        guard state.seekSettleDirection != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.pollSeekSettle() }
    }

    // MARK: Scrubbing (state in `MPVPlaybackState`)

    /// Starts a scrub at the playhead. No-op while one is running.
    private func beginScrub() {
        guard state.scrubTargetSec == nil else { return }
        if state.scan != nil { endScan(commit: true) }
        let origin = state.positionSec
        state.scrubOriginSec = origin
        state.scrubTargetSec = origin
        // A swipe takes the title, the buttons and the pills off too (a flick can start before the
        // touch has been answered), and a finger that swipes rests no knob on the playhead.
        touchWork?.cancel()
        touchWork = nil
        revealPausedChromeNow()
        if !state.scrubChrome {
            state.chromeCascade = .show
            state.scrubChrome = true
        }
        knobWork?.cancel()
        knobWork = nil
        state.knobShown = false
    }

    private func clampedScrubTarget(_ value: Double) -> Double {
        var next = max(value, 0)
        if state.durationSec > 0 { next = min(next, max(state.durationSec - 1, 0)) }
        return next
    }

    private func moveScrubTarget(by seconds: Double) {
        guard let target = state.scrubTargetSec, seconds.isFinite else { return }
        let next = clampedScrubTarget(target + seconds)
        state.scrubTargetSec = next
        // What the finger did in its last moments decides how far the head glides on after it.
        let now = ProcessInfo.processInfo.systemUptime
        scrubMoves.append((uptime: now, seconds: next - target))
        scrubMoves.removeAll { now - $0.uptime > 0.5 }
        armScrubIdle()
    }

    /// The finger left: the head glides on by a share of what it moved in the last tenth of a
    /// second, exponentially (`PlayerSpec.Scrub`).
    private func finishScrubGesture() {
        guard let target = state.scrubTargetSec else {
            scrubMoves.removeAll()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let recent = scrubMoves.filter { now - $0.uptime <= 0.1 }.reduce(0.0) { $0 + $1.seconds }
        scrubMoves.removeAll()
        let limit = max(state.durationSec, 1) * PlayerSpec.Scrub.tailMaxShareOfDuration
        let tail = min(max(recent * PlayerSpec.Scrub.tailShare, -limit), limit)
        guard abs(tail) >= 0.5 else { return }
        startScrubTail(from: target, to: clampedScrubTarget(target + tail))
    }

    private func startScrubTail(from origin: Double, to end: Double) {
        cancelScrubTail()
        let start = ProcessInfo.processInfo.systemUptime
        let tau = PlayerSpec.Scrub.tailTimeConstantSec
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, self.state.scrubTargetSec != nil else {
                timer.invalidate()
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if elapsed >= tau * 5 {
                timer.invalidate()
                self.scrubTailTimer = nil
                self.state.scrubTargetSec = end
                return
            }
            self.state.scrubTargetSec = origin + (end - origin) * (1 - exp(-elapsed / tau))
        }
        RunLoop.main.add(timer, forMode: .common)
        scrubTailTimer = timer
    }

    private func cancelScrubTail() {
        scrubTailTimer?.invalidate()
        scrubTailTimer = nil
    }

    /// One exact seek to the scrub head; `resume` also plays from there (Select / Play). The full
    /// chrome comes back (title, buttons and pills fade in within 167 ms) for its idle time.
    private func commitScrub(resume: Bool) {
        guard let target = state.scrubTargetSec else { return }
        let origin = state.scrubOriginSec ?? target
        clearScrub()
        leaveScrubChrome()
        if abs(target - origin) >= 0.5 {
            if target < origin { state.upNextCancel?() }
            // Optimistic: the bar sits on the new time until the seek's own events confirm it.
            updateProps { $0.position = target }
            state.positionSec = target
            seekAbsolute(target, exact: true)
        }
        if resume, cachedProps().paused { setPlaybackPaused(false) }
        flashControls()
    }

    /// Back mid-scrub: nothing was seeked, so the playhead is still at the original time.
    private func cancelScrub() {
        clearScrub()
        leaveScrubChrome()
        flashControls()
    }

    private func clearScrub() {
        cancelScrubTail()
        scrubMoves.removeAll()
        state.scrubTargetSec = nil
        state.scrubOriginSec = nil
    }

    /// Stops every remote-driven transport activity: held-arrow timers, a scrub in progress (dropped,
    /// no seek), a hold and the skip glyph. The core calls it when the player leaves the screen or
    /// fails.
    func endSeek() {
        seekTimer?.invalidate()
        seekTimer = nil
        seekDirection = 0
        seekHoldCount = 0
        if state.isScrubbing { clearScrub() }
        if state.scan != nil {
            // Leaving: no seek, no resume — the core is paused or about to be.
            state.scan = nil
            scanPausedCore = false
            scanResumesPlayback = false
        }
        state.seekSettleDirection = nil
        state.fingerDown = false
        touchWork?.cancel()
        touchWork = nil
        leaveScrubChrome()
        skimWork?.cancel()
        skimWork = nil
        state.skimVisible = false
        skipHintWork?.cancel()
        skipHintWork = nil
        skipExactWork?.cancel()
        skipExactWork = nil
        state.skipHint = nil
        state.skipChipFocused = false
    }

    // MARK: Playback

    func togglePause() {
        guard mpv != nil else { return }
        setPlaybackPaused(!cachedProps().paused)
    }

    private func setPlaybackPaused(_ paused: Bool) {
        guard mpv != nil else { return }
        // Optimistic UI: the glyph and the transport reflect the new state at once; the core is asked
        // through `commandQueue` (never a call that can wait on it), and its answer confirms it.
        requestPause(paused)
        refreshState()
    }

    /// End screen "Play Again": back to the start and resume playing.
    func replay() {
        guard mpv != nil else { return }
        endSeek()
        // A replay is a new viewing: Automatic Skipping may skip the intro again.
        autoSkipTracker.reset()
        seekAbsolute(0)
        // The seek first, then the unpause (both posted, in that order); the cache follows at once so
        // the end-of-file state does not outlive the request.
        requestPause(false)
        updateProps { $0.eof = false }
        state.isEnded = false
        state.endedNaturally = true
        state.completedByHandOff = false
        state.positionSec = 0            // the next poll tick reports the real position
        loadStartPositionSec = 0
        // The intro/outro handled on the first watch must be skippable again.
        autoSkipTracker.reset()
        // The end screen's presentation closed the Trakt session (viewDidDisappear): a replay is a
        // new viewing, so it scrobbles again from the start — the other trackers too.
        traktSessionClosed = false
        traktScrobbleRequested = false
        traktScrobbleItem = nil
        otherTrackersOpen = false
        traktStartPending = false
        resumeTargetSec = nil
        startTraktScrobble()
        flashControls()
        becomeFirstResponder()
    }

    /// Relative seek, asynchronous (held-arrow and Now Playing callers must not park the main thread
    /// on the core lock). `exact` decodes to the precise time instead of the nearest keyframe.
    func seekBy(_ seconds: Double, exact: Bool = false) {
        skipExactWork?.cancel()
        skipExactWork = nil
        postSeek(String(format: "%.3f", seconds), mode: exact ? "relative+exact" : "relative")
    }

    func seekAbsolute(_ seconds: Double, exact: Bool = false) {
        skipExactWork?.cancel()
        skipExactWork = nil
        postSeek(String(format: "%.3f", seconds), mode: exact ? "absolute+exact" : "absolute")
    }

    // MARK: Chrome presentation

    /// Brings the full chrome up (or keeps it up) for `PlayerChromeMetrics.autoHideDelay` after this
    /// interaction. The parts come in through the quick cascade (167 ms), unless the chrome was
    /// already up. A ±10 s click is not an interaction in this sense while the chrome is up (the
    /// chrome hid 0.72 s after one), so `arrowClicked` never calls it.
    func flashControls() {
        let wasShowing = chromeIsShowing
        // Whatever was waiting for its delay is here now.
        revealPausedChromeNow()
        if !wasShowing { state.chromeCascade = .show }
        state.controlsVisible = true
        // Any interaction brings back the pause chrome Back had put away (F3).
        if state.pauseChromeDismissed { state.pauseChromeDismissed = false }
        // The bar alone becomes the bar of the full chrome.
        cancelSkim()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Scrubbing, holding or under the focus layer: the bar stays (spec §6.9.3). Paused,
            // `pauseChromeShown` holds it by itself, so the flag is cleared here as well: a resume that
            // did not come through the remote (an interruption, Now Playing) must not leave the bar up.
            if !self.state.isScrubbing, self.state.scan == nil, !self.state.panelOpen {
                self.state.skipChipFocused = false
                self.state.controlsVisible = false
                self.state.barTinted = false
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerChromeMetrics.autoHideDelay, execute: work)
    }

    /// The chrome of a pause that is still waiting for its delay comes in now, and the one Back put
    /// away comes back (an interaction).
    private func revealPausedChromeNow() {
        if state.pauseChromeDismissed { state.pauseChromeDismissed = false }
        guard state.isPaused, !state.pauseChromeRevealed else { return }
        pauseRevealWork?.cancel()
        pauseRevealWork = nil
        state.pauseChromeRevealed = true
    }

    /// The pause chrome comes in `PlayerSpec.Chrome.pauseRevealDelaySec` after the picture froze
    /// (1.6 s to 1.883 s of the owner's recording), in the pause cascade; at once when the chrome was
    /// already up. Called by every state tick, so it follows a pause from any source.
    func updatePauseReveal() {
        guard state.isPaused else {
            pauseRevealWork?.cancel()
            pauseRevealWork = nil
            // Playing again: the bar alone gives way to the chrome of play.
            if state.scrubChrome { leaveScrubChrome() }
            return
        }
        guard !state.pauseChromeRevealed, pauseRevealWork == nil else { return }
        if state.controlsVisible || state.skimVisible || state.panelOpen {
            state.pauseChromeRevealed = true
            return
        }
        state.chromeCascade = .pause
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pauseRevealWork = nil
            if self.state.isPaused { self.state.pauseChromeRevealed = true }
        }
        pauseRevealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerSpec.Chrome.pauseRevealDelaySec, execute: work)
    }
}
