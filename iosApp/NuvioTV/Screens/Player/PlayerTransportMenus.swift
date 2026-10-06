import SwiftUI

// One description of the player chrome, shared by BOTH engines so they cannot drift apart again
// (user report, 2026-10: "the native SDR path has the system interface, other formats get a
// different one — it must be the same everywhere"):
//  - the transport-bar items, their order, labels and SF Symbols (`PlayerTransportItem`,
//    `PlayerTransportMenus.items`) — the native screen turns the app-defined ones into
//    `AVPlayerViewController.transportBarCustomMenuItems`; the mpv chrome draws all of them;
//  - the speed and subtitle-timing choices;
//  - the content tabs under the scrubber (`PlayerContentTab`);
//  - the chapter list built from the intro/recap/credits segments (`PlayerChapters`) — the native
//    screen's Chapters tab (`navigationMarkerGroups`) and the mpv Chapters tab;
//  - the chrome timing (`PlayerChromeMetrics`).

/// One button of the transport bar.
enum PlayerTransportItem: String, CaseIterable, Identifiable, Hashable {
    case startOver, sources, playbackSpeed, subtitleTiming, subtitles, audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startOver:
            return String(localized: "player.menu.startOver",
                          defaultValue: "Start Over",
                          comment: "Player transport-bar button: go back to the beginning of the video (0:00).")
        case .sources: return String(localized: "Sources")
        case .playbackSpeed: return String(localized: "Playback Speed")
        case .subtitleTiming:
            return String(localized: "player.menu.subtitleTiming",
                          defaultValue: "Subtitle Timing",
                          comment: "Native player transport-bar menu: shift addon subtitles earlier (-) or later (+).")
        case .subtitles: return String(localized: "Subtitles")
        case .audio: return String(localized: "Audio")
        }
    }

    /// SF Symbol of the item. The app-defined ones are the native transport bar's own images; the
    /// last two stand in for the system player's built-in Subtitles and Audio buttons.
    var symbol: String {
        switch self {
        case .startOver: return "backward.end"
        case .sources: return "rectangle.stack"
        case .playbackSpeed: return "speedometer"
        case .subtitleTiming: return "clock.arrow.circlepath"
        case .subtitles: return "captions.bubble"
        case .audio: return "speaker.wave.2"
        }
    }

    /// The system player's own buttons (not `transportBarCustomMenuItems` on the native engine).
    var isSystemItem: Bool { self == .subtitles || self == .audio }
}

enum PlayerTransportMenus {
    /// Speeds offered, the system player's range.
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// Timing offsets offered (ms; positive = later), subtitles and — mpv only — audio.
    static let delays: [Int] = [-2000, -1000, -500, -250, 0, 250, 500, 1000, 2000]

    /// The app-defined items in transport-bar order (`transportBarCustomMenuItems` on native).
    /// Start Over (PLY-A13) leads: a plain action, available on every title and both engines.
    static func customItems(canChooseSource: Bool, supportsSubtitleDelay: Bool) -> [PlayerTransportItem] {
        var items: [PlayerTransportItem] = [.startOver]
        if canChooseSource { items.append(.sources) }
        items.append(.playbackSpeed)
        if supportsSubtitleDelay { items.append(.subtitleTiming) }
        return items
    }

    /// Everything the bar shows, in the system player's order: the app's items, then the built-in
    /// Subtitles and Audio buttons at the trailing end. The mpv chrome draws exactly this list.
    static func items(canChooseSource: Bool, supportsSubtitleDelay: Bool) -> [PlayerTransportItem] {
        customItems(canChooseSource: canChooseSource, supportsSubtitleDelay: supportsSubtitleDelay)
            + [.subtitles, .audio]
    }

    static func rateTitle(_ rate: Float) -> String {
        LocalizedNumberFormat.speed(Double(rate))
    }

    static func delayTitle(_ ms: Int) -> String {
        LocalizedNumberFormat.signedSeconds(Double(ms) / 1000)
    }

    /// The offered offsets, with the current one added when it is off the grid (a value restored
    /// from an earlier session, or set on mobile).
    static func delayChoices(including current: Int) -> [Int] {
        var choices = delays
        if !choices.contains(current) {
            choices.append(current)
            choices.sort()
        }
        return choices
    }
}

/// The content tabs under the scrubber ("swipe down"), in the order the native screen shows them:
/// the system Info tab, the app's Episodes tab, the system Chapters tab, the app's Stream Info tab.
enum PlayerContentTab: String, Identifiable, Hashable {
    case info, episodes, chapters, streamInfo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return String(localized: "Info")
        case .episodes: return String(localized: "Episodes")
        case .chapters:
            return String(localized: "player.tab.chapters", defaultValue: "Chapters",
                          comment: "Player content tab under the scrubber: the chapter list (intro, episode, credits).")
        case .streamInfo: return String(localized: "Stream Info")
        }
    }
}

/// Chrome timing shared by both engines.
enum PlayerChromeMetrics {
    /// The transport bar hides this long after the last interaction while playing (paused,
    /// scrubbing or fast-forwarding it stays).
    static let autoHideDelay: TimeInterval = 5
}

/// One chapter of the Chapters tab.
struct PlayerChapter: Identifiable, Equatable {
    let start: Double
    let end: Double
    let title: String
    var id: Double { start }
}

enum PlayerChapters {
    /// Chapters from the skip segments: Beginning, Recap, Intro, the episode itself, Credits.
    /// Empty when there is nothing to split (no segments, or a single chapter).
    static func fromSegments(_ segments: [SkipSegment], durationSec: Double?) -> [PlayerChapter] {
        let sorted = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }
        var points: [(start: Double, title: String)] = []
        if sorted[0].start > 2 {
            points.append((0, String(localized: "player.chapter.beginning", defaultValue: "Beginning",
                                     comment: "Native player Chapters tab: the part before the first recap/intro segment.")))
        }
        for (index, segment) in sorted.enumerated() {
            points.append((segment.start, title(for: segment.type)))
            let isCredits = UpNextTrigger.outroTypes.contains(segment.type.lowercased())
            let nextStart = index + 1 < sorted.count ? sorted[index + 1].start : nil
            if !isCredits, nextStart.map({ $0 - segment.end > 2 }) ?? true {
                points.append((segment.end, String(localized: "player.chapter.episode", defaultValue: "Episode",
                                                   comment: "Native player Chapters tab: the episode itself, after the intro or recap.")))
            }
        }
        guard points.count > 1 else { return [] }
        let end = max(durationSec ?? 0, sorted.map(\.end).max() ?? 0)
        return chapters(from: points, end: end)
    }

    /// Chapters from the file's own chapter marks (mpv `chapter-list` starts, the opening one left
    /// out): "Chapter 1" from 0, then one per mark.
    static func fromFileChapters(_ starts: [Double], durationSec: Double) -> [PlayerChapter] {
        let marks = starts.filter { $0 > 1 }.sorted()
        guard !marks.isEmpty else { return [] }
        let all = [0] + marks
        let points = all.enumerated().map { index, start in
            (start: start, title: String(localized: "player.chapter.number", defaultValue: "Chapter \(index + 1)",
                                         comment: "Player Chapters tab: a chapter of the file that has no name of its own."))
        }
        return chapters(from: points, end: max(durationSec, marks.last ?? 0))
    }

    private static func chapters(from points: [(start: Double, title: String)], end: Double) -> [PlayerChapter] {
        points.enumerated().map { index, point in
            let next = index + 1 < points.count ? points[index + 1].start : end
            return PlayerChapter(start: point.start, end: max(next, point.start + 1), title: point.title)
        }
    }

    static func title(for type: String) -> String {
        let type = type.lowercased()
        if UpNextTrigger.outroTypes.contains(type) {
            return String(localized: "player.chapter.credits", defaultValue: "Credits",
                          comment: "Native player Chapters tab: the end credits segment.")
        }
        if type == "recap" {
            return String(localized: "player.chapter.recap", defaultValue: "Recap",
                          comment: "Native player Chapters tab: the previously-on recap segment.")
        }
        return String(localized: "player.chapter.intro", defaultValue: "Intro",
                      comment: "Native player Chapters tab: the opening titles segment.")
    }
}

extension NextEpisodeEngine {
    /// "Sources" in the transport bar replaces this episode's stream: an Up Next countdown must
    /// not hand off underneath the picker. Only when the card is actually up. Both engines.
    func cancelForSourceSwitch() {
        if isCardVisible { dismissForSession() }
    }
}
