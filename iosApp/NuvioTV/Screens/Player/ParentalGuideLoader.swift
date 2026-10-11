import Foundation
import SharedCore

/// The IMDb parents-guide lookup both the details page (content chips) and the player (the
/// overlay shown as playback starts) use: which id to ask for, the labels, and the warnings the
/// shared `ParentalGuideRepository` data maps to.
enum ParentalGuideLoader {
    /// Display labels handed to the shared `buildParentalWarnings`.
    static let labels = ParentalGuideLabels(
        nudity: String(localized: "Nudity"),
        violence: String(localized: "Violence"),
        profanity: String(localized: "Profanity"),
        alcohol: String(localized: "Alcohol & Drugs"),
        frightening: String(localized: "Frightening Scenes"),
        severe: String(localized: "Severe"),
        moderate: String(localized: "Moderate"),
        mild: String(localized: "Mild")
    )

    /// The first IMDb id (`tt…`) any of the candidates carries (a meta id, a video id such as
    /// "tt0944947:1:2", the addon's IMDb id).
    static func imdbId(from candidates: [String?]) -> String? {
        for candidate in candidates {
            if let id = ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: candidate) { return id }
        }
        return nil
    }

    /// The title's warnings (at most five, most severe first); empty when the guide has none or
    /// could not be fetched. `completion` runs on the main queue.
    static func fetchWarnings(imdbId: String, completion: @escaping ([ParentalWarning]) -> Void) {
        ParentalGuideRepository.shared.getParentalGuide(imdbId: imdbId) { result, _ in
            DispatchQueue.main.async {
                guard let result else {
                    completion([])
                    return
                }
                completion(ParentalGuideRepositoryKt.buildParentalWarnings(guide: result, labels: labels))
            }
        }
    }
}
