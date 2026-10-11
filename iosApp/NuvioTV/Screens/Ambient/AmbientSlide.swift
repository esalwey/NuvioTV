import CoreGraphics
import Foundation
import SharedCore

/// One title in the Ambient Mode slideshow: its backdrop, its logo when it has one, and a genre line.
struct AmbientSlide: Identifiable, Equatable {
    let id: String
    let title: String
    let backdropURL: URL
    let logoURL: URL?
    let genres: [String]
}

/// A catalog item reduced to what a slide needs, so the picking rules can be tested without the
/// shared model.
struct AmbientCandidate: Equatable {
    let type: String
    let id: String
    let title: String
    /// The wide artwork, or nil when the item only has a portrait poster (a poster cropped to fill
    /// a 16:9 screen is not worth showing).
    let backdrop: String?
    let logo: String?
    let genres: [String]

    var key: String { "\(type):\(id)" }

    init(type: String, id: String, title: String, backdrop: String?, logo: String?, genres: [String]) {
        self.type = type
        self.id = id
        self.title = title
        self.backdrop = backdrop
        self.logo = logo
        self.genres = genres
    }

    init(_ preview: MetaPreview) {
        let banner: String? = preview.banner
        let poster: String? = preview.poster
        let logo: String? = preview.logo
        // `heroBackdropURL` is the Home hero's chain: the addon's banner, else the metahub background
        // for an IMDb id, else the poster. The last step is dropped here.
        let resolved = heroBackdropURL(for: preview)
        let isPosterFallback = (banner?.isEmpty ?? true) && resolved != nil && resolved == poster
        self.init(
            type: preview.type,
            id: preview.id,
            title: preview.name,
            backdrop: isPosterFallback ? nil : resolved,
            logo: logo.flatMap { $0.isEmpty ? nil : $0 },
            genres: preview.genres
        )
    }
}

/// Builds the slide list for one showing of the slideshow.
enum AmbientSlideBuilder {
    static let itemsPerCatalog = 10
    static let maxSlides = 30
    static let maxGenres = 3

    /// The slides for the user's settings, from what Home has already loaded: no extra requests.
    /// With no catalogs chosen the Home hero's titles are used, else the first catalog row.
    static func slides(sections: [HomeCatalogSection], heroItems: [MetaPreview],
                       settings: AmbientModeSettings,
                       shuffled: Bool = true) -> [AmbientSlide] {
        var rows: [[AmbientCandidate]] = []
        let chosen = settings.catalogKeys.compactMap { key in sections.first { $0.key == key } }
        if !chosen.isEmpty {
            rows = chosen.prefix(AmbientModeSettings.maxCatalogs).map { section in
                Array(section.items.prefix(itemsPerCatalog)).map { AmbientCandidate($0) }
            }
        } else if !heroItems.isEmpty {
            rows = [heroItems.map { AmbientCandidate($0) }]
        } else if let first = sections.first(where: { !$0.items.isEmpty }) {
            rows = [Array(first.items.prefix(itemsPerCatalog)).map { AmbientCandidate($0) }]
        }
        return slides(rows: rows, shuffled: shuffled)
    }

    /// Interleaves the rows so every chosen catalog is represented early, drops repeats and items
    /// without wide artwork, and caps the total.
    static func slides(rows: [[AmbientCandidate]], shuffled: Bool = true) -> [AmbientSlide] {
        var seen = Set<String>()
        var result: [AmbientSlide] = []
        for candidate in interleave(rows) where seen.insert(candidate.key).inserted {
            guard let slide = slide(for: candidate) else { continue }
            result.append(slide)
            if result.count == maxSlides { break }
        }
        return shuffled ? result.shuffled() : result
    }

    static func interleave(_ rows: [[AmbientCandidate]]) -> [AmbientCandidate] {
        let longest = rows.map(\.count).max() ?? 0
        var result: [AmbientCandidate] = []
        for index in 0..<longest {
            for row in rows where index < row.count {
                result.append(row[index])
            }
        }
        return result
    }

    static func slide(for candidate: AmbientCandidate) -> AmbientSlide? {
        guard let backdrop = candidate.backdrop?.trimmingCharacters(in: .whitespacesAndNewlines),
              !backdrop.isEmpty, let backdropURL = URL(string: backdrop) else { return nil }
        let logoURL = candidate.logo.flatMap { value -> URL? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(string: trimmed)
        }
        return AmbientSlide(
            id: candidate.key,
            title: candidate.title,
            backdropURL: backdropURL,
            logoURL: logoURL,
            genres: Array(candidate.genres.prefix(maxGenres))
        )
    }
}

/// The slow camera move under a slide: a scale and a drift, expressed as fractions of the screen.
/// The seven moves are the Android TV set; a slide never repeats the previous one.
struct AmbientMotion: Equatable {
    var startScale: CGFloat
    var endScale: CGFloat
    var startX: CGFloat = 0
    var endX: CGFloat = 0
    var startY: CGFloat = 0
    var endY: CGFloat = 0

    static let all: [AmbientMotion] = [
        AmbientMotion(startScale: 1.0, endScale: 1.06),
        AmbientMotion(startScale: 1.07, endScale: 1.01),
        AmbientMotion(startScale: 1.06, endScale: 1.06, startX: -0.025, endX: 0.025),
        AmbientMotion(startScale: 1.06, endScale: 1.06, startX: 0.025, endX: -0.025),
        AmbientMotion(startScale: 1.06, endScale: 1.06, startY: 0.02, endY: -0.02),
        AmbientMotion(startScale: 1.02, endScale: 1.08, endX: -0.025, endY: -0.02),
        AmbientMotion(startScale: 1.02, endScale: 1.08, endX: 0.025, endY: 0.02),
    ]

    /// With Reduce Motion the picture holds still and slides only cross-fade.
    static let still = AmbientMotion(startScale: 1, endScale: 1)

    static func next<G: RandomNumberGenerator>(after previous: AmbientMotion?, using generator: inout G) -> AmbientMotion {
        let pool = all.filter { $0 != previous }
        return pool.randomElement(using: &generator) ?? all[0]
    }

    func scale(at progress: CGFloat) -> CGFloat {
        startScale + (endScale - startScale) * progress
    }

    func offset(at progress: CGFloat, in size: CGSize) -> CGSize {
        CGSize(
            width: (startX + (endX - startX) * progress) * size.width,
            height: (startY + (endY - startY) * progress) * size.height
        )
    }
}

/// How long each part of a slide lasts, in seconds (Android TV values).
enum AmbientTiming {
    static let backdropFadeIn: Double = 0.9
    static let titleDelay: Double = 0.25
    static let titleFadeIn: Double = 0.5
    static let genresDelay: Double = 0.35
    static let genresFadeIn: Double = 0.45
    static let hold: Double = 10
    static let genresFadeOut: Double = 0.25
    static let titleFadeOut: Double = 0.35
    static let backdropFadeOut: Double = 0.7
    static let blackHold: Double = 0.3
    /// Wait before trying again when every slide failed to load.
    static let allFailedRetry: Double = 15

    /// The camera move spans the whole visible life of a slide.
    static var motionDuration: Double {
        backdropFadeIn + titleDelay + titleFadeIn + hold + genresFadeOut + titleFadeOut + backdropFadeOut
    }
}
