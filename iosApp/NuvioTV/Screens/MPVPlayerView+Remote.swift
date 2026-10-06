import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit
import Libmpv
import SharedCore

// Siri Remote grammar for the mpv engine (PLY-A2/A3/A4, F3/F5/F6/F7, spec §6.9.4): the same answers
// as Apple's player and the native engine. Every layer Back can close comes before leaving:
// Up Next card → Stream Info → scrub (back to the original time) → fast-forward → chrome and pause
// card → exit. Scrubbing state lives in `MPVPlaybackState` (extensions hold no stored properties).
extension MPVTVPlayerViewController: UIGestureRecognizerDelegate {
    /// Identifies the touch-surface pan this extension installs (installed once per view).
    private static let transportPanName = "nuvio.mpv.transportPan"
    /// An arrow held at least this long is a hold (fast-forward / accumulated scrub), not a click.
    private static let holdThresholdSec: TimeInterval = 0.45
    /// Held-arrow scrub: one step per tick, 20 s growing to 60 s (the old accelerating jumps).
    private static let holdStepIntervalSec: TimeInterval = 0.4
    /// A click left/right: one exact ±10 s seek (a step of the scrub head while scrubbing).
    private static let clickSeekSec: Double = 10
    /// Hold right while playing: 2×, and each further right press steps to 3×, then 4×.
    private static let fastForwardRates: [Double] = [2, 3, 4]
    /// Touch-surface scrub at slow speed: about 1 s per 8 pt of travel (spec §6.9.4), faster swipes
    /// accelerate.
    private static let scrubSecondsPerPoint: Double = 1.0 / 8.0

    @objc func handleSwipeDown() {
        guard presentedViewController == nil else { return }
        onOpenPanel?()
    }

    /// Show a skip prompt while the playhead is inside a segment (leaving a 1s tail so the button
    /// disappears cleanly at the end).
    func updateSkipPrompt(position: Double, durationSec: Double) {
        // Upstream 80860602f: an error/placeholder clip (shared short-placeholder rule) offers no skip.
        let placeholder = WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: Int64(durationSec * 1000))
        let active = placeholder ? nil
            : skipSegments.first(where: { position >= $0.start && position < $0.end - PlayerChipStyle.lastSecondExclusion })
        let prompt = active.map {
            SkipPrompt(label: skipLabel(for: $0.type), targetSec: $0.end,
                       isCredits: UpNextTrigger.outroTypes.contains($0.type.lowercased()))
        }
        if prompt != state.skipPrompt { state.skipPrompt = prompt }
    }

    private func skipLabel(for type: String) -> String {
        let type = type.lowercased()
        // Every credits type Up Next knows (AniSkip "ed"/"mixed-ed", IntroDB "outro", …).
        if UpNextTrigger.outroTypes.contains(type) { return String(localized: "Skip Outro") }
        if type == "recap" { return String(localized: "Skip Recap") }
        return String(localized: "player.skip.intro", defaultValue: "Skip Intro",
                      comment: "Player chip that jumps past a show's intro (both engines).")
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

    /// Resting a finger on the touch surface shows the controls (spec gap 3). Showing chrome is not
    /// an action, so this is fine during playback (HIG: never act on a tap).
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .indirect }), presentedViewController == nil,
           !state.playbackErrorShown, !state.isEnded {
            flashControls()
        }
        super.touchesBegan(touches, with: event)
    }

    /// Paused: a horizontal swipe moves the scrub head (Select/Play commits, Back cancels).
    /// Playing: the swipe only shows the chrome.
    @objc private func handleTransportPan(_ pan: UIPanGestureRecognizer) {
        guard mpv != nil, presentedViewController == nil, !state.playbackErrorShown, !state.isEnded else { return }
        switch pan.state {
        case .began:
            NextEpisodeEngine.consecutiveAutoPlays = 0
            if state.isPaused { beginScrub(commitsOnRelease: false) }
            pan.setTranslation(.zero, in: view)
            flashControls()
        case .changed:
            guard state.isPaused, state.isScrubbing, !state.scrubCommitsOnRelease else { return }
            let dx = Double(pan.translation(in: view).x)
            pan.setTranslation(.zero, in: view)
            let speed = abs(Double(pan.velocity(in: view).x))
            let acceleration: Double = speed < 400 ? 1 : (speed < 1200 ? 3 : 8)
            moveScrubTarget(by: dx * Self.scrubSecondsPerPoint * acceleration)
        default:
            break
        }
    }

    // MARK: - Siri-remote transport

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
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
                    // Same gesture as the native player: Down opens the top panel — during a skip
                    // prompt too (F6: Select skips now). Track lists are refreshed on open (the
                    // async walk fills them if this raced the events).
                    endFastForward()
                    refreshTracksAsync()
                    onOpenPanel?()
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
        // The top panel normally takes Back itself (it is presented over this controller).
        if state.panelOpen, presentedViewController != nil { return true }
        if state.isScrubbing {
            cancelScrub()
            return true
        }
        if state.fastForwardRate != nil {
            endFastForward()
            flashControls()
            return true
        }
        if state.controlsVisible || state.pauseChromeShown {
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
        if state.fastForwardRate != nil {
            endFastForward()
            flashControls()
            return
        }
        if let prompt = state.skipPrompt, !state.isPaused {
            // Skip Intro / Recap / Outro answers Select (F6); paused, Select resumes as usual.
            performSkip(prompt)
            return
        }
        togglePause()
        flashControls()
    }

    private func playPausePressed() {
        if state.isScrubbing {
            commitScrub(resume: true)
            return
        }
        if state.fastForwardRate != nil {
            endFastForward()
            flashControls()
            return
        }
        togglePause()
        flashControls()
    }

    private func performSkip(_ prompt: SkipPrompt) {
        // Skip Outro on credits that run to the end of the file = the next episode now (Up Next),
        // not a seek onto the last frame.
        if !(prompt.isCredits && state.upNextSkipCredits?(prompt.targetSec) == true) {
            // Clamp against duration: a skip-outro target past EOF wedges mpv.
            // durationSec is still 0 before the first duration event — seek unclamped then.
            let target = state.durationSec > 0
                ? min(prompt.targetSec, state.durationSec - 0.5)
                : prompt.targetSec
            seekAbsolute(target)
        }
        state.skipPrompt = nil
        flashControls()
    }

    /// Back with the chrome up: hide the transport bar, and while paused the pause card too (F3).
    private func hideChrome() {
        hideWork?.cancel()
        hideWork = nil
        state.controlsVisible = false
        if state.isPaused { state.pauseChromeDismissed = true }
    }

    // MARK: Arrows: click, hold, fast-forward

    /// An arrow went down. Click or hold is decided by how long it stays down: a click acts on the
    /// release, a hold once `holdThresholdSec` has passed.
    private func arrowPressBegan(_ dir: Double) {
        // Going backward means the user is still watching — abandon next-episode autoplay.
        if dir < 0 { state.upNextCancel?() }
        seekTimer?.invalidate()
        seekDirection = dir
        seekHoldCount = 0
        let timer = Timer(timeInterval: Self.holdThresholdSec, repeats: false) { [weak self] _ in
            self?.arrowHoldBegan()
        }
        RunLoop.main.add(timer, forMode: .common)
        seekTimer = timer
        flashControls()
    }

    private func arrowHoldBegan() {
        guard seekDirection != 0, mpv != nil else { return }
        seekHoldCount = 1
        seekTimer = nil
        if seekDirection > 0, !state.isPaused, !state.isScrubbing {
            // Hold right while playing: fast-forward (spec gap 2). It keeps going after the release;
            // Select, Play/Pause, Back or a left press return to normal speed.
            startOrStepFastForward()
            return
        }
        // Rewind, or any hold while paused: accelerating jumps of the scrub head, one exact seek on
        // the release (decision D9: mpv has no fast reverse).
        endFastForward()
        beginScrub(commitsOnRelease: true)
        moveScrubTarget(by: seekDirection * 20)
        let timer = Timer(timeInterval: Self.holdStepIntervalSec, repeats: true) { [weak self] _ in
            guard let self, self.seekDirection != 0 else { return }
            self.seekHoldCount += 1
            let step = Double(min(10 + self.seekHoldCount * 10, 60))  // 30s, 40s … up to 60s
            self.moveScrubTarget(by: self.seekDirection * step)
        }
        RunLoop.main.add(timer, forMode: .common)
        seekTimer = timer
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
            // A held-arrow scrub seeks once, now. (A touch-surface scrub it added to waits for
            // Select/Play; fast-forward keeps running.)
            if state.isScrubbing, state.scrubCommitsOnRelease { commitScrub(resume: false) }
            return
        }
        guard !cancelled else { return }
        arrowClicked(dir)
    }

    private func arrowClicked(_ dir: Double) {
        if state.fastForwardRate != nil {
            // Fast-forwarding: right steps up (2× → 3× → 4×), left returns to normal speed.
            if dir > 0 {
                startOrStepFastForward()
            } else {
                endFastForward()
                flashControls()
            }
            return
        }
        if state.isScrubbing {
            moveScrubTarget(by: dir * Self.clickSeekSec)
            return
        }
        seekBy(dir * Self.clickSeekSec, exact: true)
        flashControls()
    }

    private func startOrStepFastForward() {
        let rates = Self.fastForwardRates
        let next: Double
        if let current = state.fastForwardRate, let index = rates.firstIndex(of: current) {
            next = rates[min(index + 1, rates.count - 1)]
        } else {
            next = rates[0]
        }
        state.fastForwardRate = next
        applyPlaybackRate(next, muted: true)
        flashControls()
    }

    /// Back to the speed picked in the panel (1× unless changed), sound on.
    private func endFastForward() {
        guard state.fastForwardRate != nil else { return }
        state.fastForwardRate = nil
        applyPlaybackRate(state.playbackSpeed, muted: false)
    }

    private func applyPlaybackRate(_ rate: Double, muted: Bool) {
        guard mpv != nil else { return }
        let speed = String(format: "%.2f", rate)
        eventQueue.async { [weak self] in
            self?.command("set", args: ["speed", speed])
            self?.command("set", args: ["mute", muted ? "yes" : "no"])
        }
    }

    // MARK: Scrubbing (state in `MPVPlaybackState`)

    /// Starts a scrub at the playhead. No-op while one is running (a hold adds to a swipe's target).
    private func beginScrub(commitsOnRelease: Bool) {
        guard state.scrubTargetSec == nil else { return }
        let origin = state.positionSec
        state.scrubOriginSec = origin
        state.scrubCommitsOnRelease = commitsOnRelease
        state.scrubTargetSec = origin
    }

    private func moveScrubTarget(by seconds: Double) {
        guard let target = state.scrubTargetSec, seconds.isFinite else { return }
        var next = max(target + seconds, 0)
        if state.durationSec > 0 { next = min(next, max(state.durationSec - 1, 0)) }
        state.scrubTargetSec = next
        flashControls()
    }

    /// One exact seek to the scrub head; `resume` also plays from there (Select / Play).
    private func commitScrub(resume: Bool) {
        guard let target = state.scrubTargetSec else { return }
        let origin = state.scrubOriginSec ?? target
        clearScrub()
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
        flashControls()
    }

    private func clearScrub() {
        state.scrubTargetSec = nil
        state.scrubOriginSec = nil
        state.scrubCommitsOnRelease = false
    }

    /// Stops every remote-driven transport activity: held-arrow timers, a scrub in progress (dropped,
    /// no seek) and fast-forward. The core calls it when the player leaves the screen or fails.
    func endSeek() {
        seekTimer?.invalidate()
        seekTimer = nil
        seekDirection = 0
        seekHoldCount = 0
        if state.isScrubbing { clearScrub() }
        endFastForward()
    }

    // MARK: Playback

    func togglePause() {
        guard mpv != nil else { return }
        setPlaybackPaused(!cachedProps().paused)
    }

    private func setPlaybackPaused(_ paused: Bool) {
        guard mpv != nil else { return }
        // Optimistic UI: reflect the new state immediately; the pause property event confirms it.
        updateProps { $0.paused = paused }
        eventQueue.async { [weak self] in self?.setFlag("pause", paused) }
        refreshState()
    }

    /// End screen "Play Again": back to the start and resume playing.
    func replay() {
        guard mpv != nil else { return }
        endSeek()
        seekAbsolute(0)
        setFlag("pause", false)
        state.isEnded = false
        state.endedNaturally = true
        state.completedByHandOff = false
        state.positionSec = 0            // the next poll tick reports the real position
        loadStartPositionSec = 0
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

    /// Relative seek through `eventQueue` (held-arrow and Now Playing callers must not park the main
    /// thread on the core lock). `exact` decodes to the precise time instead of the nearest keyframe.
    func seekBy(_ seconds: Double, exact: Bool = false) {
        guard mpv != nil else { return }
        let mode = exact ? "relative+exact" : "relative"
        eventQueue.async { [weak self] in
            self?.command("seek", args: [String(format: "%.3f", seconds), mode])
        }
    }

    func seekAbsolute(_ seconds: Double, exact: Bool = false) {
        guard mpv != nil else { return }
        let mode = exact ? "absolute+exact" : "absolute"
        eventQueue.async { [weak self] in
            self?.command("seek", args: [String(format: "%.3f", seconds), mode])
        }
    }

    func flashControls() {
        state.controlsVisible = true
        // Any interaction brings back the pause chrome Back had put away (F3).
        if state.pauseChromeDismissed { state.pauseChromeDismissed = false }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Paused, scrubbing or fast-forwarding: the bar stays (spec §6.9.3).
            if !self.state.isPaused, !self.state.isScrubbing, self.state.fastForwardRate == nil {
                self.state.controlsVisible = false
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
}
