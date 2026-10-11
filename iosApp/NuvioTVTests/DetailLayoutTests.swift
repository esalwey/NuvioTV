import XCTest
@testable import NuvioTV

/// Settings → Detail Page: the plain-value layer between the shared settings and `DetailView`
/// (section order and gating, mode names), and the maths of the dominant-colour backdrop tint.
@MainActor
final class DetailLayoutTests: XCTestCase {

    // MARK: - DetailLayout

    func testDefaultLayoutIsTheTelevisionPage() {
        let layout = DetailLayout()
        XCTAssertEqual(layout.sections, [.production, .episodes, .cast, .collection, .trailers, .moreLikeThis, .comments, .details])
        XCTAssertTrue(layout.showsActions)
        XCTAssertTrue(layout.showsOverview)
        XCTAssertEqual(layout.backgroundMode, .normal)
        XCTAssertEqual(layout.episodeCardStyle, .horizontal)
        XCTAssertFalse(layout.blurUnwatchedEpisodes)
    }

    func testSectionsFollowTheNamesGivenAndDropUnknownOrRepeatedOnes() {
        let layout = DetailLayout(
            lowerSectionNames: ["CAST", "EPISODES", "ACTIONS", "NOT_A_SECTION", "CAST", "MORE_LIKE_THIS", "DETAILS"],
            showsActions: false,
            showsOverview: true,
            backgroundModeName: "Normal",
            episodeCardStyleName: "Horizontal",
            blurUnwatchedEpisodes: false
        )
        XCTAssertEqual(layout.sections, [.cast, .episodes, .moreLikeThis, .details])
        XCTAssertFalse(layout.showsActions)
    }

    func testEveryLowerSectionHasAKotlinName() {
        let names = ["PRODUCTION", "EPISODES", "CAST", "COLLECTION", "TRAILERS", "MORE_LIKE_THIS", "COMMENTS", "DETAILS"]
        XCTAssertEqual(names.compactMap(DetailSection.init(kotlinName:)).count, DetailSection.allCases.count)
    }

    func testBackgroundModesMapToTheirNamesAndPersistedKeys() {
        XCTAssertEqual(DetailBackgroundMode(kotlinName: "Normal"), .normal)
        XCTAssertEqual(DetailBackgroundMode(kotlinName: "Cinematic"), .cinematic)
        XCTAssertEqual(DetailBackgroundMode(kotlinName: "DominantColor"), .dominantColor)
        XCTAssertEqual(DetailBackgroundMode(kotlinName: "something new"), .normal)
        XCTAssertEqual(DetailBackgroundMode.allCases.map(\.key), ["normal", "cinematic", "dominant_color"])
    }

    func testEpisodeCardStylesMapToTheirNamesAndPersistedKeys() {
        XCTAssertEqual(DetailEpisodeCardStyle(kotlinName: "List"), .list)
        XCTAssertEqual(DetailEpisodeCardStyle(kotlinName: "Horizontal"), .horizontal)
        XCTAssertEqual(DetailEpisodeCardStyle(kotlinName: ""), .horizontal)
        XCTAssertEqual(DetailEpisodeCardStyle.allCases.map(\.key), ["horizontal", "list"])
    }

    // MARK: - DominantBackdropColor

    private func rgba(_ pixels: [(UInt8, UInt8, UInt8, UInt8)]) -> [UInt8] {
        pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] }
    }

    func testTheSaturatedColourOutweighsLetterboxBlackAndWhite() {
        // A quarter red, three quarters near-black bars: the picture's colour is the red.
        var pixels: [(UInt8, UInt8, UInt8, UInt8)] = Array(repeating: (200, 30, 30, 255), count: 25)
        pixels += Array(repeating: (2, 2, 2, 255), count: 60)
        pixels += Array(repeating: (255, 255, 255, 255), count: 15)
        let dominant = DominantBackdropColor.dominantColor(fromRGBA: rgba(pixels))
        XCTAssertNotNil(dominant)
        XCTAssertGreaterThan(dominant?.r ?? 0, 0.7)
        XCTAssertLessThan(dominant?.g ?? 1, 0.2)
    }

    func testAnEmptyOrTransparentBufferHasNoDominantColour() {
        XCTAssertNil(DominantBackdropColor.dominantColor(fromRGBA: []))
        XCTAssertNil(DominantBackdropColor.dominantColor(fromRGBA: rgba(Array(repeating: (200, 30, 30, 0), count: 10))))
    }

    func testTheTintStaysDarkEnoughForWhiteText() {
        let bright = rgba(Array(repeating: (250, 240, 20, 255), count: 40))
        let tint = DominantBackdropColor.tint(fromRGBA: bright)
        XCTAssertNotNil(tint)
        XCTAssertLessThanOrEqual(tint?.luminance ?? 1, DominantBackdropColor.maxLuminance + 0.0001)
    }

    func testBlendTravelsFromTheBackgroundTowardTheTarget() {
        let target = DominantBackdropColor.RGB(r: 1, g: 0, b: 0)
        let none = DominantBackdropColor.blend(DominantBackdropColor.background, toward: target, fraction: 0)
        let all = DominantBackdropColor.blend(DominantBackdropColor.background, toward: target, fraction: 1)
        XCTAssertEqual(none, DominantBackdropColor.background)
        XCTAssertEqual(all.r, target.r, accuracy: 1e-9)
        XCTAssertEqual(all.g, target.g, accuracy: 1e-9)
        XCTAssertEqual(all.b, target.b, accuracy: 1e-9)
        let part = DominantBackdropColor.blend(DominantBackdropColor.background, toward: target, fraction: 0.42)
        XCTAssertGreaterThan(part.r, DominantBackdropColor.background.r)
        XCTAssertLessThan(part.r, 1)
    }
}
