import SwiftUI

/// The behaviour and look of the tvOS system player (`AVPlayerViewController`, tvOS 26 / 27) that the
/// mpv chrome reproduces. docs/player-spec.md is the reference: every value here is cited there with
/// the source it comes from, and a change to one belongs in both places.
///
/// Source tags, as in the document:
///  - [doc]      Apple documentation (support guide, HIG, AVKit)
///  - [WWDC]     an Apple session or sample
///  - [observed] a third-party or user observation, with its URL in the document
///  - [inferred] reasoned from the above, or from the native engine's behaviour on a device
///  - [MEASURE]  nothing public gives a value; it has to be measured on an Apple TV (the document's
///               "Calibrating on a device" lists how), and this is the stand-in until then
///
/// Nothing here is a guess dressed as a fact: a [MEASURE] value says so, and the native engine (the
/// system player itself) is the arbiter of all of them.
nonisolated enum PlayerSpec {

    // MARK: - Remote

    enum Remote {
        /// A click on the left or right edge skips this many seconds; another click skips another 10.
        /// [doc] "Press again to skip another 10 seconds." The seek is exact (current time ± 10 s) and
        /// keeps the play / pause state.
        static let skipSeconds: Double = 10

        /// An edge held at least this long is a hold (scan), not a click. [inferred] A quick press
        /// skips 10 s and a long press scans (tvOS 14.3 and later, [observed] Firecore); the system
        /// threshold itself is [MEASURE].
        static let holdThresholdSec: TimeInterval = 0.45

        /// Scan speeds: a hold starts at 2x, each further press of the same edge steps to 3x then 4x.
        /// [doc] "Press repeatedly to cycle through 2x, 3x and 4x." What a press beyond 4x does (wrap,
        /// stay, reverse) is [MEASURE]; this engine stays on 4x. The opposite edge, Select, Play/Pause
        /// and Back return to normal speed.
        static let scanRates: [Double] = [2, 3, 4]

        /// mpv has no reverse playback and no playback rate to ride on while paused: the head is moved
        /// by a timer, one seek per tick, at the rate's pace. [inferred] (app mechanism, not system)
        static let scanStepIntervalSec: TimeInterval = 0.25

        /// Touch-surface scrub at slow speed: about 1 s per 8 pt of travel, faster swipes accelerate.
        /// [MEASURE]
        static let scrubSecondsPerPoint: Double = 1.0 / 8.0
    }

    // MARK: - Chrome

    enum Chrome {
        /// The bar hides this long after the last interaction while playing; paused, scrubbing or
        /// scanning it stays until the viewer acts. [observed] "roughly 3 to 4 seconds" (Firecore);
        /// the system value is [MEASURE].
        static let autoHideDelay: TimeInterval = 4

        /// The skip hint ("+10 ›") stays up as long as the bar does after the last click, and the
        /// clicks in a row add up while it is up. [doc] says only that repeated clicks skip 10 s each;
        /// that the hint is tied to the bar's auto-hide is [inferred]; the running total's reset is
        /// [MEASURE].
        static let skipHintLifetime: TimeInterval = autoHideDelay

        /// The bar fades in and out with a short slide of its bottom group. [inferred] 0.25 to 0.35 s
        /// (ease in-out) with a slide of a few points; the exact duration and curve are [MEASURE]
        /// (`willTransitionToVisibilityOfTransportBar` on the native engine logs them).
        static let fadeDuration: Double = 0.3
        static let slideOffset: CGFloat = 16
    }
}
