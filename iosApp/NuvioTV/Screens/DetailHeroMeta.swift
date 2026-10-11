import Foundation

/// Plain-string presentation rules for the Detail hero's secondary lines: the status badge, the
/// "Created by / Directed by" credit line and the optional full release date. Kept free of SwiftUI
/// and of the shared framework so the rules read (and can be tested) on their own; `DetailView`
/// feeds them strings and lays out the result.
enum DetailHeroMeta {
    /// Short badge text for a TMDB / add-on `status`, or nil when the status is not worth a badge.
    /// "Released" is dropped on purpose: the year already says it, and the Apple TV product page
    /// only calls out the states that differ from the default (a series that is still running,
    /// has ended, was cancelled, or a title that is not out yet). Unknown values show as given.
    static func statusLabel(_ rawStatus: String?) -> String? {
        let trimmed = (rawStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "released":
            return nil
        case "ended":
            return String(localized: "Ended")
        case "continuing", "returning series":
            return String(localized: "Ongoing")
        case "current":
            return String(localized: "Current")
        case "cancelled", "canceled":
            return String(localized: "Cancelled")
        case "planned":
            return String(localized: "Planned")
        case "rumored":
            return String(localized: "Rumored")
        case "in production":
            return String(localized: "In Production")
        case "post production":
            return String(localized: "Post Production")
        default:
            return trimmed
        }
    }

    /// The most senior credit as one line: directors (a series' creators, which TMDB reports in the
    /// same field) first, writers as the fallback. At most two names; nil when there are none.
    static func creditLine(directors: [String], writers: [String], isSeries: Bool) -> String? {
        let directorNames = joinedNames(directors)
        if !directorNames.isEmpty {
            return isSeries
                ? String(localized: "Created by \(directorNames)")
                : String(localized: "Directed by \(directorNames)")
        }
        let writerNames = joinedNames(writers)
        if !writerNames.isEmpty {
            return String(localized: "Written by \(writerNames)")
        }
        return nil
    }

    /// `yyyy-MM-dd` (the shared `MetaDetails.releaseDate`) as a long date in the viewer's locale,
    /// e.g. "July 16, 2010". The day is a calendar day, so it is read and formatted in UTC and never
    /// shifts with the time zone. Nil when the value is not a full date.
    static func fullReleaseDate(_ isoDate: String?) -> String? {
        guard let isoDate else { return nil }
        let parts = isoDate.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day),
              let utc = TimeZone(identifier: "UTC")
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        return date.formatted(
            Date.FormatStyle(date: .long, time: .omitted, locale: .autoupdatingCurrent, calendar: calendar, timeZone: utc)
        )
    }

    private static func joinedNames(_ names: [String]) -> String {
        names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: ", ")
    }
}
