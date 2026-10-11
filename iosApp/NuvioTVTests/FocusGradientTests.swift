import XCTest
@testable import NuvioTV

/// The focused-item gradient: how a color is picked from artwork, the cache behind it, and how a
/// collection's view mode maps to a folder layout.
@MainActor
final class FocusGradientTests: XCTestCase {

    // MARK: - Color rules

    /// Java's `"abc".hashCode()` is 96354 and `"hello".hashCode()` is 99162322, so a given title gets
    /// the same fallback hue here as in the Android TV app.
    func testStableHashMatchesJavaStringHashCode() {
        XCTAssertEqual(FocusGradientColor.stableHash(""), 0)
        XCTAssertEqual(FocusGradientColor.stableHash("abc"), 96354)
        XCTAssertEqual(FocusGradientColor.stableHash("hello"), 99162322)
    }

    func testStableHashWrapsLikeAnUnsigned32BitValue() {
        // "polygenelubricants".hashCode() is Int.MIN_VALUE in Java: 0x80000000 unsigned.
        XCTAssertEqual(FocusGradientColor.stableHash("polygenelubricants"), 0x8000_0000)
    }

    func testSeedColorIsStableAndNeverHarsh() {
        let base = FocusGradientRGB(r: 0.14, g: 0.14, b: 0.14)
        let first = FocusGradientColor.seedColor(seed: "tt0111161", base: base)
        let second = FocusGradientColor.seedColor(seed: "tt0111161", base: base)
        XCTAssertEqual(first, second)
        let l = FocusGradientColor.luminance(first)
        XCTAssertGreaterThanOrEqual(l, 0.0)
        XCTAssertLessThanOrEqual(l, 0.72)
        // An empty seed has no hue to offer: just the neutral base, lifted.
        let neutral = FocusGradientColor.seedColor(seed: "", base: base)
        XCTAssertEqual(neutral, FocusGradientColor.stabilize(base))
    }

    func testStabilizeLiftsDarkAndTamesLightColors() {
        let dark = FocusGradientRGB(r: 0.02, g: 0.02, b: 0.02)
        XCTAssertGreaterThan(FocusGradientColor.luminance(FocusGradientColor.stabilize(dark)),
                             FocusGradientColor.luminance(dark))
        let light = FocusGradientRGB(r: 1, g: 1, b: 0.95)
        XCTAssertLessThan(FocusGradientColor.luminance(FocusGradientColor.stabilize(light)),
                          FocusGradientColor.luminance(light))
        let mid = FocusGradientRGB(r: 0.8, g: 0.6, b: 0.5)
        XCTAssertEqual(FocusGradientColor.stabilize(mid), mid)
    }

    private func pixels(_ colors: [(UInt8, UInt8, UInt8, UInt8)]) -> [UInt8] {
        colors.flatMap { [$0.0, $0.1, $0.2, $0.3] }
    }

    func testSaturatedPixelsOutweighGreyOnes() throws {
        let grey: (UInt8, UInt8, UInt8, UInt8) = (128, 128, 128, 255)
        let red: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 255)
        let color = try XCTUnwrap(FocusGradientColor.prominent(rgba: pixels([grey, grey, grey, red]), width: 2, height: 2))
        XCTAssertGreaterThan(color.r, color.g)
        XCTAssertGreaterThan(color.r, color.b)
        XCTAssertGreaterThan(color.r, 0.5)
    }

    func testNearBlackAndTransparentPixelsAreIgnored() throws {
        let black: (UInt8, UInt8, UInt8, UInt8) = (4, 4, 4, 255)
        let clear: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 255, 0)
        let green: (UInt8, UInt8, UInt8, UInt8) = (0, 200, 0, 255)
        let color = try XCTUnwrap(FocusGradientColor.prominent(rgba: pixels([black, clear, green, black]), width: 2, height: 2))
        XCTAssertGreaterThan(color.g, color.r)
        XCTAssertGreaterThan(color.g, color.b)
    }

    func testNothingToWeighGivesNoColor() {
        let black: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)
        XCTAssertNil(FocusGradientColor.prominent(rgba: pixels([black, black, black, black]), width: 2, height: 2))
        XCTAssertNil(FocusGradientColor.prominent(rgba: [], width: 0, height: 0))
        XCTAssertNil(FocusGradientColor.prominent(rgba: [1, 2, 3], width: 2, height: 2), "a short buffer is rejected, not read")
    }

    func testHsvCornersMatchTheColorWheel() {
        XCTAssertEqual(FocusGradientColor.hsv(hue: 0, saturation: 1, value: 1), FocusGradientRGB(r: 1, g: 0, b: 0))
        let green = FocusGradientColor.hsv(hue: 120, saturation: 1, value: 1)
        XCTAssertEqual(green.g, 1, accuracy: 0.0001)
        XCTAssertEqual(green.r, 0, accuracy: 0.0001)
        let blue = FocusGradientColor.hsv(hue: 240, saturation: 1, value: 1)
        XCTAssertEqual(blue.b, 1, accuracy: 0.0001)
        XCTAssertEqual(blue.r, 0, accuracy: 0.0001)
    }

    // MARK: - Cache

    func testCacheEvictsTheLeastRecentlyUsedColor() {
        var cache = FocusGradientColorCache()
        let color = FocusGradientRGB(r: 0.5, g: 0.5, b: 0.5)
        for index in 0..<FocusGradientColorCache.capacity {
            cache.set(color, for: "k\(index)")
        }
        XCTAssertEqual(cache.count, FocusGradientColorCache.capacity)

        // Touch the oldest, then overflow: the second-oldest is the one that goes.
        XCTAssertNotNil(cache.value(for: "k0"))
        cache.set(color, for: "overflow")
        XCTAssertEqual(cache.count, FocusGradientColorCache.capacity)
        XCTAssertNotNil(cache.value(for: "k0"))
        XCTAssertNil(cache.value(for: "k1"))
        XCTAssertNotNil(cache.value(for: "overflow"))
    }

    func testArtworkKeyCombinesImageAndSeedAndIgnoresBlankImages() {
        let a = FocusGradientArtwork(imageURL: " https://x/y.jpg ", seed: "tt1")
        XCTAssertEqual(a.imageURL, "https://x/y.jpg")
        XCTAssertEqual(a.cacheKey, "https://x/y.jpg|tt1")
        XCTAssertNil(FocusGradientArtwork(imageURL: "   ", seed: "tt1").imageURL)
        XCTAssertNil(FocusGradientArtwork(imageURL: nil, seed: "tt1").imageURL)
    }

    // MARK: - Folder layout

    func testViewModesMapToALayout() {
        XCTAssertEqual(FolderPresentation(viewModeName: "TABBED_GRID"), .tabbedGrid)
        XCTAssertEqual(FolderPresentation(viewModeName: "ROWS"), .rows)
        XCTAssertEqual(FolderPresentation(viewModeName: "FOLLOW_LAYOUT"), .rows,
                       "Home on tvOS is shelves, so following it means shelves")
        XCTAssertEqual(FolderPresentation(viewModeName: "rows"), .rows)
        XCTAssertEqual(FolderPresentation(viewModeName: "something new"), .tabbedGrid)
    }
}
