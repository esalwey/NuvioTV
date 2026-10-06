import XCTest
import SwiftUI
@testable import NuvioTV

/// Unit tests for `InlineTrailerTileGeometry.inner(outer:band:cornerRadius:)` (`InlineTrailerCard.swift`,
/// BUG-92: "inline trailer on the GIGN card sits offset — dark band between the [ring] and the
/// video"). Pure math, no hosting view needed — the values below are the ones the Wave F design
/// pass itself worked out from `PosterStyle`'s Large numbers (`posterStyle.width`/`height` at
/// Large ≈ 268.9×403.3, `cornerRadius` = `Theme.Radius.card` = 12, ring band = `ringWidth` = 4).
final class InlineTrailerTileGeometryTests: XCTestCase {

    /// Large, expanded (16:9) tile, ring band active: outer 717.0×403.3 (403.3 * 16/9), band 4,
    /// corner radius 12 → inner rect (4, 4, 709.0, 395.3), radius 8.
    func testLargeExpandedTileWithBand() {
        let outer = CGSize(width: 717.0, height: 403.3)
        let result = InlineTrailerTileGeometry.inner(outer: outer, band: 4, cornerRadius: 12)

        XCTAssertEqual(result.rect.origin.x, 4, accuracy: 0.05)
        XCTAssertEqual(result.rect.origin.y, 4, accuracy: 0.05)
        XCTAssertEqual(result.rect.width, 709.0, accuracy: 0.05)
        XCTAssertEqual(result.rect.height, 395.3, accuracy: 0.05)
        XCTAssertEqual(result.radius, 8, accuracy: 0.001)
    }

    /// Large, poster (resting) state, ring band active: outer 268.9×403.3, band 4, radius 12 →
    /// inner rect (4, 4, 260.9, 395.3), radius 8 — identical inset math to `PosterCard`'s own
    /// artwork inset at rest, so the morph starts perfectly concentric.
    func testLargePosterStateWithBand() {
        let outer = CGSize(width: 268.9, height: 403.3)
        let result = InlineTrailerTileGeometry.inner(outer: outer, band: 4, cornerRadius: 12)

        XCTAssertEqual(result.rect.origin.x, 4, accuracy: 0.05)
        XCTAssertEqual(result.rect.origin.y, 4, accuracy: 0.05)
        XCTAssertEqual(result.rect.width, 260.9, accuracy: 0.05)
        XCTAssertEqual(result.rect.height, 395.3, accuracy: 0.05)
        XCTAssertEqual(result.radius, 8, accuracy: 0.001)
    }

    /// `band == 0` (both focus-ring settings off, the shipped default) must be a byte-identical
    /// no-op: inner rect == outer rect at the origin, radius unchanged.
    func testZeroBandIsIdentity() {
        let outer = CGSize(width: 717.0, height: 403.3)
        let result = InlineTrailerTileGeometry.inner(outer: outer, band: 0, cornerRadius: 12)

        XCTAssertEqual(result.rect, CGRect(origin: .zero, size: outer))
        XCTAssertEqual(result.radius, 12, accuracy: 0.001)
    }

    /// A corner radius no larger than the band must floor at 0, never go negative — an already
    /// tight/square-cornered tile (radius 0) with a 4pt band still produces a valid (if literally
    /// square) inner rect.
    func testRadiusNeverNegative() {
        let outer = CGSize(width: 100, height: 60)
        let result = InlineTrailerTileGeometry.inner(outer: outer, band: 4, cornerRadius: 0)

        XCTAssertEqual(result.radius, 0, accuracy: 0.001)
        XCTAssertEqual(result.rect, CGRect(x: 4, y: 4, width: 92, height: 52))

        // A radius exactly equal to the band lands at 0, not negative.
        let exact = InlineTrailerTileGeometry.inner(outer: outer, band: 4, cornerRadius: 4)
        XCTAssertEqual(exact.radius, 0, accuracy: 0.001)
    }

    /// A band larger than half of either edge must clamp rather than invert the rect to a
    /// negative width/height — the degenerate-tiny-tile guard the helper's doc promises.
    func testBandLargerThanHalfSizeClamps() {
        let outer = CGSize(width: 20, height: 8)
        // Half of height (4) is the tighter clamp here.
        let result = InlineTrailerTileGeometry.inner(outer: outer, band: 100, cornerRadius: 12)

        XCTAssertEqual(result.rect.origin.x, 4, accuracy: 0.001)
        XCTAssertEqual(result.rect.origin.y, 4, accuracy: 0.001)
        XCTAssertEqual(result.rect.width, 12, accuracy: 0.001)  // 20 - 2*4
        XCTAssertEqual(result.rect.height, 0, accuracy: 0.001)  // 8 - 2*4
        XCTAssertGreaterThanOrEqual(result.rect.width, 0)
        XCTAssertGreaterThanOrEqual(result.rect.height, 0)

        // Half of width is the tighter clamp on a tall/narrow tile.
        let tall = InlineTrailerTileGeometry.inner(outer: CGSize(width: 8, height: 20), band: 100, cornerRadius: 12)
        XCTAssertEqual(tall.rect.width, 0, accuracy: 0.001)
        XCTAssertEqual(tall.rect.height, 12, accuracy: 0.001)
    }
}
