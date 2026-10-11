import Combine
import Foundation

/// What decides whether the idle clock may run at all. Every term is a plain value so the rule
/// itself is testable; `AmbientEnvironmentProbe` reads the live app for the real ones.
struct AmbientConditions: Equatable {
    /// The user switched Ambient Mode on.
    var enabled = false
    /// A profile is open and the tab shell is showing (not the welcome gate or "Who's watching?").
    var shellActive = false
    /// The scene is in the foreground.
    var appActive = true
    /// Something else asked the system to keep the screen awake: the players, Remote Setup.
    var idleTimerHeldByOthers = false
    /// A sheet, alert or full-screen cover is up (the players, the trailer, the stream picker).
    var coverPresented = false
    /// A trailer preview is playing on Home.
    var trailerPlaying = false
    /// VoiceOver drives the remote differently; an overlay that swallows presses would trap it.
    var voiceOverRunning = false

    var isEligible: Bool {
        enabled && shellActive && appActive && !idleTimerHeldByOthers && !coverPresented
            && !trailerPlaying && !voiceOverRunning
    }
}

/// What the app-wide input hook should do with one remote event.
///
/// A press that wakes the slideshow must not also activate whatever Home has focused underneath, so
/// the wake-up press is swallowed, and so is the rest of that same gesture (its release, a swipe's
/// remaining movement). `swallowDeadline` bounds that tail: a release that never arrives (the app
/// lost the remote mid-press) can not leave the remote dead.
struct AmbientInputGate: Equatable {
    /// One remote event, reduced to what the gate needs.
    struct Input: Equatable {
        /// Every press or touch in the event has ended or been cancelled.
        var endsInteraction: Bool
    }

    struct Decision: Equatable {
        /// Drop the event instead of delivering it.
        var swallow: Bool
        /// The slideshow should go away.
        var dismiss: Bool
    }

    /// The longest a swallowed gesture is waited out.
    static let swallowWindow: TimeInterval = 1.5

    private(set) var swallowDeadline: Date?

    mutating func process(_ input: Input, showing: Bool, now: Date) -> Decision {
        if showing {
            swallowDeadline = input.endsInteraction ? nil : now.addingTimeInterval(Self.swallowWindow)
            return Decision(swallow: true, dismiss: true)
        }
        if let deadline = swallowDeadline {
            if now > deadline {
                swallowDeadline = nil
            } else {
                if input.endsInteraction { swallowDeadline = nil }
                return Decision(swallow: true, dismiss: false)
            }
        }
        return Decision(swallow: false, dismiss: false)
    }
}

/// Owns the idle clock and the "slideshow is up" flag.
///
/// Remote activity is fed in by `AmbientInputMonitor` (an app-wide hook on `UIApplication`, since
/// SwiftUI gives a root view no way to see every press). A single loop wakes at most every
/// `maxWake` seconds, asks the live app whether the idle clock may run (`conditions`), and shows the
/// slideshow once the user's delay has passed. While anything else owns the screen the clock is
/// held at zero, so the delay always counts from the moment Home became the front screen again.
@MainActor
final class AmbientIdleController: ObservableObject {
    static let shared = AmbientIdleController()

    /// The slideshow is on screen.
    @Published private(set) var isShowing = false
    /// The slides it plays, fixed for one showing.
    @Published private(set) var slides: [AmbientSlide] = []

    private(set) var lastActivity: Date
    private var gate = AmbientInputGate()
    private let clock: () -> Date
    private var loop: Task<Void, Never>?

    /// The shell flag is set by the app root; the rest are read from the live app on every tick.
    var shellActive = false
    var appActive = true
    var settingsProvider: () -> AmbientModeSettings = { AmbientModeSettingsModel.shared.settings }
    var environmentProvider: () -> AmbientConditions = { AmbientEnvironmentProbe.current() }
    var slideProvider: () -> [AmbientSlide] = { [] }

    /// The longest the loop sleeps, so a changed delay or a closed player is noticed promptly.
    static let maxWake: TimeInterval = 15
    static let minWake: TimeInterval = 0.5

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
        self.lastActivity = clock()
    }

    // MARK: - Input

    /// Any remote event: restarts the clock. Returns true when the event must be swallowed.
    func intercept(_ input: AmbientInputGate.Input) -> Bool {
        let now = clock()
        lastActivity = now
        let decision = gate.process(input, showing: isShowing, now: now)
        if decision.dismiss { dismiss() }
        return decision.swallow
    }

    func noteActivity() {
        lastActivity = clock()
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        lastActivity = clock()
    }

    // MARK: - Clock

    /// One evaluation of the clock. Returns how long to sleep before the next one.
    @discardableResult
    func tick(now: Date? = nil, settings: AmbientModeSettings? = nil,
              conditions: AmbientConditions? = nil) -> TimeInterval {
        let now = now ?? clock()
        let settings = settings ?? settingsProvider()
        var conditions = conditions ?? environmentProvider()
        conditions.enabled = settings.enabled
        conditions.shellActive = shellActive
        conditions.appActive = appActive

        guard conditions.isEligible else {
            // Something else owns the screen (or the feature is off): hold the clock at zero.
            if isShowing { dismiss() }
            lastActivity = now
            return Self.maxWake
        }
        if isShowing { return Self.maxWake }

        let remaining = settings.timeout - now.timeIntervalSince(lastActivity)
        if remaining > 0 {
            return min(max(remaining, Self.minWake), Self.maxWake)
        }
        let next = slideProvider()
        guard !next.isEmpty else {
            // Nothing to show yet (catalogs still loading); look again soon rather than every tick.
            return Self.maxWake
        }
        slides = next
        isShowing = true
        return Self.maxWake
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.tick() else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if isShowing { dismiss() }
    }
}
