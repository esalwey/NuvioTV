import XCTest
@testable import NuvioTV
import SharedCore

/// FEAT-34: unit tests for `SagaCardArt`, the pure helpers behind `SagaCard`'s artwork-source and
/// logo-lookup-gating decisions (`DesignSystem/SagaCard.swift`). No view host — these exercise
/// plain functions over `MetaPreview`.
final class SagaCardTests: XCTestCase {

    private func makeItem(name: String = "Movie", poster: String? = nil, banner: String? = nil,
                          logo: String? = nil, releaseInfo: String? = nil) -> MetaPreview {
        MetaPreview(
            id: "1", type: "movie", name: name,
            poster: poster, banner: banner, logo: logo,
            posterShape: .landscape,
            description: nil, releaseInfo: releaseInfo, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: []
        )
    }

    // MARK: - artworkURL

    func testArtworkURLPrefersBannerOverPoster() {
        let item = makeItem(poster: "https://example.com/poster.jpg", banner: "https://example.com/banner.jpg")
        XCTAssertEqual(SagaCardArt.artworkURL(for: item), "https://example.com/banner.jpg")
    }

    func testArtworkURLFallsBackToPosterWhenBannerMissing() {
        let item = makeItem(poster: "https://example.com/poster.jpg", banner: nil)
        XCTAssertEqual(SagaCardArt.artworkURL(for: item), "https://example.com/poster.jpg")
    }

    func testArtworkURLFallsBackToPosterWhenBannerEmpty() {
        let item = makeItem(poster: "https://example.com/poster.jpg", banner: "")
        XCTAssertEqual(SagaCardArt.artworkURL(for: item), "https://example.com/poster.jpg")
    }

    func testArtworkURLNilWhenBothEmpty() {
        let item = makeItem(poster: nil, banner: nil)
        XCTAssertNil(SagaCardArt.artworkURL(for: item))
    }

    func testArtworkURLNilWhenBothBlank() {
        let item = makeItem(poster: "", banner: "")
        XCTAssertNil(SagaCardArt.artworkURL(for: item))
    }

    // MARK: - needsLogoLookup

    func testNeedsLogoLookupFalseWhenLogoSet() {
        let item = makeItem(logo: "https://example.com/logo.png")
        XCTAssertFalse(SagaCardArt.needsLogoLookup(item))
    }

    func testNeedsLogoLookupTrueWhenLogoNil() {
        let item = makeItem(logo: nil)
        XCTAssertTrue(SagaCardArt.needsLogoLookup(item))
    }

    func testNeedsLogoLookupTrueWhenLogoEmpty() {
        let item = makeItem(logo: "")
        XCTAssertTrue(SagaCardArt.needsLogoLookup(item))
    }

    // `TitleLogoStore.shouldCommit` (formerly `SagaLogoStore.shouldCommit`) moved to
    // `TitleLogoStoreTests` (FEAT-42) alongside the rest of the store's pure-function coverage —
    // this file keeps only what is specific to `SagaCardArt`, the view-local helpers.
}
