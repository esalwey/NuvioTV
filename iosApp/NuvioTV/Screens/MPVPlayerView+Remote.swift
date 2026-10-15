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
// answers as Apple's player and the native engine, which this one is rebuilt from the spec of. Every
// layer Back can close comes before leaving: Up Next card → Stream Info → scrub (back to the
// original time) → fast-forward / rewind → chrome → exit. Scrubbing state lives in
// `MPVPlaybackState` (extensions hold no stored properties). All timings and sizes are
// `PlayerSpec`'s, each with its source.
//
// What the system player does, and so does this one:
//  - a click on the left / right edge skips exactly ±10 s — the head and the time move at once — and
//    shows the bar with the skip hint in it ("+10 ›", the clicks in a row add up); there is no glyph
//    over the picture. Skipping back also turns subtitles on for the section being replayed;
//  - a hold on an edge starts fast-forward / rewind at 2×, each further press of the same edge steps
//    to 3× then 4×, the opposite edge, Select, Play/Pause or Back return to normal speed; the rate
//    shows next to the elapsed time, the sound is muted;
//  - swiping on the touch surface only shows the bar while playing, and scrubs while paused;
//  - the bar hides a few seconds after the last interaction while playing and stays up while paused.
extension MPVTVPlayerViewController: UIGestureRecognizerDelegate {
    /// Identifies the touch-surface pan this extension installs (installed once per view).
    private static let transportPanName = "nuvio.mpv.transportPan"
    /// An arrow held at least this long is a hold (fast-forward / rewind), not a click.
    private static let holdThresholdSec: TimeInterval = PlayerSpec.Remote.holdThresholdSec
    /// A click left/right: one exact ±10 s seek (a step of the scrub head while scrubbing).
    private static let clickSeekSec: Double = PlayerSpec.Remote.skipSeconds
    /// A hold: 2×, and each further press of the same edge steps to 3×, then 4×.
    private static let fastForwardRates: [Double] = PlayerSpec.Remote.scanRates
    /// Rewind, and any hold while paused, has no playback rate to ride on in mpv: the head is moved
    /// by a timer instead, one seek per tick, at the rate's pace.
    private static let rateStepIntervalSec: TimeInterval = PlayerSpec.Remote.scanStepIntervalSec
    /// Touch-surface scrub at slow speed: about 1 s per 8 pt of travel, faster swipes accelerate.
    private static let scrubSecondsPerPoint: Double = PlayerSpec.Remote.scrubSecondsPerPoint

    /// Down swipe: the content tabs under the scrubber (Info, Episodes, Chapters, Stream Info), as
    /// on the system player.
    @objc func handleSwipeDown() {
        guard presentedViewController == nil, !state.isScrubbing, !state.isEnded, !state.playbackErrorShown else { return }
        openChrome(.tabs)
    }

    /// Up swipe: with the bar showing, focus moves up to its buttons; otherwise the bar shows.
    @objc func handleSwipeUp() {
        guard presentedViewController == nil, !state.isScrubbing, !state.isEnded, !state.playbackErrorShown else { return }
        if chromeIsShowing {
            openChrome(.transport)
        } else {
            flashControls()
        }
    }

    /// The transport bar is on screen (shown by an interaction, or held by a pause).
    private var chromeIsShowing: Bool {
        state.controlsVisible || state.pauseChromeShown
    }

    /// Hands focus to the chrome's focus layer (menus, content tabs): fast-forward / rewind stops, and the
    /// track lists are refreshed (the async walk fills them if this raced the events).
    private func openChrome(_ entry: PlayerChromeEntry) {
        endFastForward()
        refreshTracksAsync()
        onOpenChrome?(entry)
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
                && !state.panelOpen && state.fastForwardRate == nil,
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
            if state.isPaused { beginScrub() }
            pan.setTranslation(.zero, in: view)
            flashControls()
        case .changed:
            guard state.isPaused, state.isScrubbing else { return }
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
                    // focus up to its buttons (Subtitles, Audio, the app's menus).
                    if chromeIsShowing, !state.isEnded, !state.playbackErrorShown {
                        openChrome(.transport)
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

    /// Play/Pause as the remote answers it: commits a scrub, stops a scan, else toggles. Also what the
    /// chrome's focus layer calls (`MPVPlaybackState.togglePlayPause`) for a press that lands while focus
    /// sits in the bar or in a tab.
    func playPausePressed() {
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
        state.controlsVisible = false
        if state.isPaused { state.pauseChromeDismissed = true }
    }

    // MARK: Arrows: click, hold, fast-forward / rewind

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
        if state.isScrubbing {
            // A hold on top of a touch-surface scrub steps the head once, like a click would; the
            // scrub still waits for Select / Play, and Back still cancels it.
            moveScrubTarget(by: seekDirection * Self.clickSeekSec)
            return
        }
        // Fast-forward / rewind (spec gap 2). It keeps going after the release; Select, Play/Pause,
        // Back or the opposite edge return to normal speed.
        startOrStepRate(seekDirection)
    }

    private func arrowPressEnded(cancelled: Bool) {
        guard seekDirection != 0 else { return }
        let dir = seekDirection
        let wasHold = seekHoldCount > 0
        seekTimer?.invalidate()
        seekTimer = nil
        seekDirection = 0
        seekHoldCount = 0
        // A hold already did its work (the rate keeps running after the release).
        guard !wasHold, !cancelled else { return }
        arrowClicked(dir)
    }

    private func arrowClicked(_ dir: Double) {
        if let rate = state.fastForwardRate {
            if rate * dir > 0 {
                // The same edge again: 2× → 3× → 4×.
                startOrStepRate(dir)
            } else {
                // The opposite edge: back to normal speed.
                endFastForward()
                flashControls()
            }
            return
        }
        if state.isScrubbing {
            moveScrubTarget(by: dir * Self.clickSeekSec)
            return
        }
        skip(by: dir * Self.clickSeekSec)
        showSkipHint(dir)
        flashControls()
    }

    /// The ±10 s skip: one exact seek to the current time ± 10 s, with the play / pause state left as
    /// it was (docs/player-spec.md, "Skip"). The head and the time move at once, as the system bar's
    /// do — they used to wait for the core's own position events, which are held back while a seek
    /// is in flight — and the clicks in a row start from where the last one aimed, so they add up
    /// exactly (+10, +20, +30) whatever the decoder has caught up with.
    private func skip(by seconds: Double) {
        guard mpv != nil else { return }
        var origin = cachedProps().position
        // A resume seek still in flight: the playhead has not got to where the file is resuming yet.
        if let resume = resumeTargetSec, origin + 5 < resume { origin = resume }
        var target = max(origin + seconds, 0)
        // A skip forward past the end lands on the last half second, which then ends the file.
        if state.durationSec > 0 { target = min(target, max(state.durationSec - 0.5, 0)) }
        // Skipping back replays a section: the system turns subtitles on for it.
        if seconds < 0 { beginRewindSubtitles(replayingFrom: origin) }
        updateProps { $0.position = target }
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) { state.positionSec = target }
        seekAbsolute(target, exact: true)
    }

    /// The system's skip hint: "+10 ›" (or "‹ -10") in the bar's state slot, the seconds skipped by the
    /// clicks in a row added up. It stays up as long as the bar does after the last click, then the
    /// total starts over (docs/player-spec.md, "Skip": the reset is [MEASURE]).
    private func showSkipHint(_ dir: Double) {
        let direction = dir < 0 ? -1 : 1
        let previous = state.skipHint
        let carried = (previous?.direction == direction) ? (previous?.seconds ?? 0) : 0
        state.skipHint = SkipHint(id: (previous?.id ?? 0) &+ 1, direction: direction,
                                  seconds: carried + Int(Self.clickSeekSec))
        skipHintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.state.skipHint = nil }
        skipHintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerSpec.Chrome.skipHintLifetime, execute: work)
    }

    /// Starts the rate in `dir` (+1 forward, -1 back) at 2×, or steps an already running one in the
    /// same direction up to 3× and 4×. Forward while playing rides mpv's own speed (muted); backward,
    /// and anything while paused, moves the head by timer (`rateStepTick`).
    private func startOrStepRate(_ dir: Double) {
        let rates = Self.fastForwardRates
        var magnitude = rates[0]
        if let current = state.fastForwardRate, current * dir > 0,
           let index = rates.firstIndex(of: abs(current)) {
            magnitude = rates[min(index + 1, rates.count - 1)]
        }
        state.fastForwardRate = dir * magnitude
        rateStepTimer?.invalidate()
        rateStepTimer = nil
        if dir > 0, !state.isPaused {
            state.rateSeekTarget = nil
            applyPlaybackRate(magnitude, muted: true)
        } else {
            // The pictures come from the seeks; playing, the sound is muted and the speed is the
            // normal one, so the timer alone decides where the head is.
            if !state.isPaused { applyPlaybackRate(1, muted: true) }
            if state.rateSeekTarget == nil { state.rateSeekTarget = state.positionSec }
            let timer = Timer(timeInterval: Self.rateStepIntervalSec, repeats: true) { [weak self] _ in
                self?.rateStepTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            rateStepTimer = timer
        }
        flashControls()
    }

    /// One step of a rewind (or of a hold while paused): the head moves by rate × interval and the
    /// core is asked for the picture there (nearest keyframe, which is what trick play shows).
    private func rateStepTick() {
        guard mpv != nil, let rate = state.fastForwardRate, var target = state.rateSeekTarget else {
            endFastForward()
            return
        }
        target += rate * Self.rateStepIntervalSec
        let duration = state.durationSec
        let atEdge = (rate < 0 && target <= 0) || (rate > 0 && duration > 0 && target >= duration - 1)
        if atEdge { target = rate < 0 ? 0 : max(duration - 1, 0) }
        state.rateSeekTarget = target
        // The bar follows at once; the core's own position events catch up behind the seek.
        updateProps { $0.position = target }
        state.positionSec = target
        postSeek(String(format: "%.3f", target), mode: "absolute+keyframes")
        if atEdge {
            endFastForward()
            flashControls()
        }
    }

    /// Back to the speed picked in the panel (1× unless changed), sound on.
    private func endFastForward() {
        rateStepTimer?.invalidate()
        rateStepTimer = nil
        state.rateSeekTarget = nil
        guard state.fastForwardRate != nil else { return }
        state.fastForwardRate = nil
        applyPlaybackRate(state.playbackSpeed, muted: false)
    }

    private func applyPlaybackRate(_ rate: Double, muted: Bool) {
        guard mpv != nil else { return }
        postSet("speed", String(format: "%.2f", rate))
        postSet("mute", flag: muted)
    }

    // MARK: Scrubbing (state in `MPVPlaybackState`)

    /// Starts a scrub at the playhead. No-op while one is running.
    private func beginScrub() {
        guard state.scrubTargetSec == nil else { return }
        endFastForward()
        let origin = state.positionSec
        state.scrubOriginSec = origin
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
    }

    /// Stops every remote-driven transport activity: held-arrow timers, a scrub in progress (dropped,
    /// no seek), fast-forward / rewind and the skip hint. The core calls it when the player leaves the
    /// screen or fails.
    func endSeek() {
        seekTimer?.invalidate()
        seekTimer = nil
        seekDirection = 0
        seekHoldCount = 0
        if state.isScrubbing { clearScrub() }
        endFastForward()
        skipHintWork?.cancel()
        skipHintWork = nil
        state.skipHint = nil
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
        postSeek(String(format: "%.3f", seconds), mode: exact ? "relative+exact" : "relative")
    }

    func seekAbsolute(_ seconds: Double, exact: Bool = false) {
        postSeek(String(format: "%.3f", seconds), mode: exact ? "absolute+exact" : "absolute")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + PlayerChromeMetrics.autoHideDelay, execute: work)
    }
}
