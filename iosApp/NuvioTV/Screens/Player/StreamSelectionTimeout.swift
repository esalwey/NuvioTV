import Foundation

/// The shared "Stream Selection Timeout" setting (`streamAutoPlayTimeoutSeconds`) as Up Next reads
/// it, with the phone's semantics (`StreamsRepository`):
///  - 0, "Instant": choose as soon as a suitable stream arrives, from whatever the add-ons that
///    answered have sent so far; no waiting period.
///  - 1 to 30: wait that long for the add-ons, then choose from what arrived. Before it ends, the
///    choice waits for every source in scope to finish (or an early same-group match).
///  - `Int.MAX_VALUE`, "Unlimited": like Instant, but with a long hard stop so a hung add-on cannot
///    hold Up Next for ever.
nonisolated struct StreamSelectionTimeout: Equatable, Sendable {
    /// `Int.MAX_VALUE` in the shared Kotlin settings.
    static let unlimitedValue = Int(Int32.max)
    /// The hard stop of the unlimited wait, in seconds.
    static let unlimitedHardStopSec: Double = 60
    /// Grace past a bounded timeout (and past Instant) for add-ons that are still answering.
    static let graceSec: Double = 12

    enum Mode: Equatable, Sendable {
        /// Choose on every response; no waiting period.
        case onEveryResponse
        /// Wait this long, then choose from what arrived.
        case bounded(seconds: Int)
    }

    let mode: Mode
    /// The longest Up Next waits for add-ons before it settles with what exists (or "no stream").
    let hardStopSec: Double

    init(settingSeconds: Int) {
        if settingSeconds <= 0 {
            mode = .onEveryResponse
            hardStopSec = Self.graceSec
        } else if settingSeconds >= Self.unlimitedValue {
            mode = .onEveryResponse
            hardStopSec = Self.unlimitedHardStopSec
        } else {
            let seconds = min(max(settingSeconds, 1), 30)
            mode = .bounded(seconds: seconds)
            hardStopSec = Double(seconds) + Self.graceSec
        }
    }

    /// Seconds before the first selection from partial results; nil = no waiting period (the
    /// selection runs as responses arrive).
    var softTimeoutSec: Int? {
        if case .bounded(let seconds) = mode { return seconds }
        return nil
    }

    /// A response may be chosen from before every source finished, once nothing more is to be
    /// waited for.
    var choosesOnEveryResponse: Bool { mode == .onEveryResponse }
}
