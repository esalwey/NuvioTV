import SwiftUI
import SharedCore

/// One provider's score as the Detail page shows it: the provider's logo (Rotten Tomatoes and
/// its audience score swap logos by status: fresh, rotten, certified, hot, stale) and the score.
struct DetailRatingBadge: Identifiable, Equatable {
    let source: String
    let displayName: String
    /// Asset-catalog image name.
    let imageName: String
    let valueText: String
    /// The certified / verified seals are drawn taller than the plain provider marks.
    let isSeal: Bool

    var id: String { source }
    var accessibilityText: String { "\(displayName) \(valueText)" }

    /// Providers in display order, with how each one formats its native scale.
    private static var order: [(source: String, name: String, image: String, format: (Double) -> String)] { [
        ("imdb", "IMDb", "Rating-imdb", oneDecimal),
        ("tmdb", "TMDB", "Rating-tmdb", whole),
        ("trakt", "Trakt", "Rating-trakt", whole),
        ("letterboxd", "Letterboxd", "Rating-letterboxd", oneDecimal),
        ("mal", "MyAnimeList", "Rating-mal", oneDecimal),
        ("tomatoes", "Rotten Tomatoes", "Rating-rotten-tomatoes", percent),
        ("audience", "Rotten Tomatoes Audience", "Rating-audience-score", percent),
        ("metacritic", "Metacritic", "Rating-metacritic", whole),
    ] }

    /// The badges for `ratings`, in display order; providers the list lacks are skipped.
    static func badges(for ratings: [MetaExternalRating]) -> [DetailRatingBadge] {
        order.compactMap { entry -> DetailRatingBadge? in
            guard let rating = ratings.first(where: { $0.source == entry.source }) else { return nil }
            let status = RottenTomatoesRatingKt.rottenTomatoesStatusOf(rating: rating)
            var image = entry.image
            var seal = false
            if let status {
                switch status {
                case RottenTomatoesStatus.certifiedFresh:
                    image = "Rating-rotten-tomatoes-certified"; seal = true
                case RottenTomatoesStatus.rotten:
                    image = "Rating-rotten-tomatoes-rotten"
                case RottenTomatoesStatus.stale:
                    image = "Rating-audience-stale"
                case RottenTomatoesStatus.verifiedHot:
                    image = "Rating-audience-verified-hot"; seal = true
                default:
                    break
                }
            }
            return DetailRatingBadge(
                source: entry.source,
                displayName: entry.name,
                imageName: image,
                valueText: entry.format(rating.value),
                isSeal: seal
            )
        }
    }

    private static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(abs(tenths % 10))"
    }

    private static func whole(_ value: Double) -> String { String(Int(value.rounded())) }

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}

/// The Detail hero's provider scores (MDBList): logo and score per provider, one flat row. Content,
/// so no glass, and not focusable: it is read, never selected. Each badge is a single
/// accessibility element, "Rotten Tomatoes 87%".
struct DetailRatingsStrip: View {
    let ratings: [MetaExternalRating]

    @ScaledMetric(relativeTo: .body) private var logoHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var sealHeight: CGFloat = 44

    var body: some View {
        let badges = DetailRatingBadge.badges(for: ratings)
        if !badges.isEmpty {
            HStack(spacing: Theme.Spacing.xl) {
                ForEach(badges) { badge in
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(badge.imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(height: badge.isSeal ? sealHeight : logoHeight)
                            .accessibilityHidden(true)
                        Text(verbatim: badge.valueText)
                            .font(Theme.Font.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: badge.accessibilityText))
                }
            }
            .lineLimit(1)
        }
    }
}
