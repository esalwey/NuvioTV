import Foundation

// The pure rules behind the player's skip affordances, shared by BOTH engines (the mpv screen and
// the native AVPlayer screen) so a segment behaves identically on either:
//
//  - which prompt ("Skip Intro", "Skip to Post-Credits", ...) the playhead is offered, and where it
//    seeks (`SkipPlanner`, a port of the phone app's `InternalSkipAction`);
//  - which segments are skipped on their own, once each, when the viewer picked them under
//    Settings > Playback > Automatic Skipping (`AutoSkipTracker`).
//
// No UIKit, no AVFoundation, no Kotlin types: unit-testable with canned segments.

/// Where a skip lands and whether a scene follows the credits it skips.
struct SkipAction: Equatable {
    /// Absolute seek target in seconds (already clamped to the file's duration when it is known).
    let targetSec: Double
    /// The skip lands on, or in front of, a post-credits scene: an explicit "post-credits" segment,
    /// or more than `UpNextTrigger.postCreditsGapSec` of tail after the credits.
    let skipsToPostCredits: Bool
}

enum SkipPlanner {
    static let postCreditsType = "post-credits"
    static let movieCreditsType = "movie-credits"

    /// Provider types are compared trimmed and lower-cased.
    static func normalized(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The Automatic Skipping kind a provider segment type belongs to ("intro", "recap", "outro" or
    /// "movie-credits"), or nil for a type that is never skipped on its own ("post-credits",
    /// unknown types). Mirrors the shared `AutoSkipSegmentType.fromSkipIntervalType`.
    static func autoSkipKind(forType type: String) -> String? {
        switch normalized(type) {
        case "op", "opening", "mixed-op", "intro": return "intro"
        case "recap": return "recap"
        case "ed", "ending", "mixed-ed", "outro", "credits": return "outro"
        case movieCreditsType: return "movie-credits"
        default: return nil
        }
    }

    /// Port of the phone app's `internalSkipAction`. nil = this segment offers no skip: a
    /// post-credits scene is content to watch, never something to skip, and a movie's end credits
    /// need real seek times (an open-ended sentinel end is not one).
    static func action(for segment: SkipSegment, in segments: [SkipSegment], durationSec: Double) -> SkipAction? {
        let type = normalized(segment.type)
        if type == postCreditsType { return nil }
        let isMovieCredits = type == movieCreditsType
        if isMovieCredits && !hasValidSeekTimes(segment) { return nil }
        let duration = durationSec.isFinite && durationSec > 0 ? durationSec : 0
        // Only credits can be followed by a scene.
        let canHavePostCredits = isMovieCredits || UpNextTrigger.outroTypes.contains(type)
        let scene: SkipSegment? = canHavePostCredits
            ? segments
                .filter {
                    normalized($0.type) == postCreditsType && hasValidSeekTimes($0)
                        && $0.start >= segment.end && (duration <= 0 || $0.start < duration)
                }
                .min { $0.start < $1.start }
            : nil
        let hasTail = canHavePostCredits && hasValidSeekTimes(segment) && duration > 0
            && duration - segment.end > UpNextTrigger.postCreditsGapSec
        var target = scene?.start ?? segment.end
        // Anime-Skip's last timestamp has no end (a huge sentinel): that is the end of the file.
        if duration > 0 { target = min(target, duration) }
        return SkipAction(targetSec: target, skipsToPostCredits: scene != nil || hasTail)
    }

    /// The prompt for the segment the playhead is in (nil outside every segment). The last second of
    /// a segment is excluded so the affordance disappears cleanly (`PlayerChipStyle`).
    static func prompt(position: Double, durationSec: Double, segments: [SkipSegment]) -> SkipPrompt? {
        for segment in segments where isInside(position, segment) {
            guard let action = action(for: segment, in: segments, durationSec: durationSec) else { continue }
            return SkipPrompt(
                label: label(forType: segment.type, skipsToPostCredits: action.skipsToPostCredits),
                targetSec: action.targetSec,
                isCredits: UpNextTrigger.outroTypes.contains(normalized(segment.type)),
                skipsToPostCredits: action.skipsToPostCredits
            )
        }
        return nil
    }

    /// The chip title. Every credits type Up Next knows (AniSkip "ed"/"mixed-ed", IntroDB "outro")
    /// reads "Skip Outro"; credits followed by a scene read "Skip to Post-Credits".
    static func label(forType type: String, skipsToPostCredits: Bool) -> String {
        let type = normalized(type)
        if skipsToPostCredits { return String(localized: "Skip to Post-Credits") }
        if UpNextTrigger.outroTypes.contains(type) { return String(localized: "Skip Outro") }
        if type == movieCreditsType { return String(localized: "Skip Credits") }
        if type == "recap" { return String(localized: "Skip Recap") }
        return String(localized: "player.skip.intro", defaultValue: "Skip Intro",
                      comment: "Player chip that jumps past a show's intro (both engines).")
    }

    /// The confirmation shown after a segment was skipped on its own.
    static func autoSkipMessage(forKind kind: String) -> String {
        switch kind {
        case "recap": return String(localized: "Recap skipped")
        case "outro": return String(localized: "Outro skipped")
        case "movie-credits": return String(localized: "Credits skipped")
        default: return String(localized: "Intro skipped")
        }
    }

    static func isInside(_ position: Double, _ segment: SkipSegment) -> Bool {
        position >= segment.start && position < segment.end - PlayerChipStyle.lastSecondExclusion
    }

    /// Finite, ordered, and an end that fits a millisecond Int64 (the phone's `hasValidSeekTimes`).
    static func hasValidSeekTimes(_ segment: SkipSegment) -> Bool {
        segment.start.isFinite && segment.end.isFinite && segment.start >= 0 && segment.end > segment.start
            && segment.end * 1000 < Double(Int64.max)
    }
}

/// Decides, tick by tick, when a segment the viewer asked to skip automatically is skipped.
///
/// Each segment is skipped at most once, and a viewer who seeks keeps the last word:
///  - a jump of the playhead the player did not make itself (a click-seek, a scrub, a chapter jump,
///    Start Over, a manual "Skip Intro") marks the segments it leaves and lands in as handled, so
///    seeking back into an intro never skips it again;
///  - nothing is skipped while paused or scrubbing (`isPlaying`);
///  - the player's own seek is waited out (`pendingTarget`), so landing on the next segment of a
///    recap-then-intro chain is not mistaken for the viewer's seek.
struct AutoSkipTracker {
    struct Skip: Equatable {
        let segment: SkipSegment
        let action: SkipAction
        /// "intro", "recap", "outro" or "movie-credits".
        let kind: String
    }

    /// A playhead move larger than this between two 0.5 s ticks is a seek (a 4x fast-forward moves
    /// 2 s per tick).
    static let seekJumpSec: Double = 3
    /// How close to its target the playhead must come for the player's own seek to count as landed.
    static let settleToleranceSec: Double = 3
    /// Give up waiting for a seek that never landed after this long.
    static let settleTimeoutSec: TimeInterval = 4

    private struct Key: Hashable {
        let start: Double
        let end: Double
        let type: String

        init(_ segment: SkipSegment) {
            start = segment.start
            end = segment.end
            type = segment.type
        }
    }

    private var handled: Set<Key> = []
    private var lastPosition: Double?
    private var pendingTarget: Double?
    private var pendingDeadline: TimeInterval = 0

    /// A new set of segments (another episode, or the first load): start over.
    mutating func reset() {
        handled = []
        lastPosition = nil
        pendingTarget = nil
        pendingDeadline = 0
    }

    /// One position tick. Returns the segment to skip now, if any; the caller seeks to
    /// `action.targetSec` (or hands the credits over to Up Next) and shows the confirmation.
    /// `enabledKinds` is only read when a segment is actually a candidate.
    mutating func evaluate(
        position: Double,
        durationSec: Double,
        now: TimeInterval,
        isPlaying: Bool,
        segments: [SkipSegment],
        enabledKinds: @autoclosure () -> Set<String>
    ) -> Skip? {
        guard position.isFinite else { return nil }

        if let target = pendingTarget {
            let landed = abs(position - target) <= Self.settleToleranceSec
            if landed || now >= pendingDeadline { pendingTarget = nil }
            if landed {
                lastPosition = position
                return nil
            }
            if pendingTarget != nil { return nil }   // still travelling
            // Timed out without landing: classify this tick like any other.
        }

        let previous = lastPosition
        lastPosition = position
        if let previous, abs(position - previous) > Self.seekJumpSec {
            markHandled(at: previous, in: segments)
            markHandled(at: position, in: segments)
            return nil
        }

        guard isPlaying, !segments.isEmpty else { return nil }
        for segment in segments where SkipPlanner.isInside(position, segment) {
            let key = Key(segment)
            guard !handled.contains(key),
                  let kind = SkipPlanner.autoSkipKind(forType: segment.type),
                  enabledKinds().contains(kind),
                  let action = SkipPlanner.action(for: segment, in: segments, durationSec: durationSec)
            else { continue }
            handled.insert(key)
            pendingTarget = action.targetSec
            pendingDeadline = now + Self.settleTimeoutSec
            return Skip(segment: segment, action: action, kind: kind)
        }
        return nil
    }

    private mutating func markHandled(at position: Double, in segments: [SkipSegment]) {
        for segment in segments where position >= segment.start && position < segment.end {
            handled.insert(Key(segment))
        }
    }
}

/// A tracker held by a SwiftUI view: a reference, so the bookkeeping done on every position tick is
/// not a state change that re-renders the screen.
final class AutoSkipTrackerBox {
    var tracker = AutoSkipTracker()
}
