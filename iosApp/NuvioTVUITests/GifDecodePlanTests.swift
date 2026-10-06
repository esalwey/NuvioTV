import XCTest

/// Pure-logic coverage for BUG-39's frame-vs-resolution trade (beta.12) — see
/// `AnimatedGifDecoder.GifDecodePlanner` in `NuvioTV/DesignSystem/AnimatedGifImage.swift`.
///
/// Deliberately does NOT launch `XCUIApplication` — plain, fast asserts against the planning
/// function. Same reason this file MIRRORS the production logic instead of importing it as
/// `StreamBadgeColorTests.swift` explains at length: `NuvioTVUITests` is a UI-testing bundle in its
/// own runner process, so `@testable import NuvioTV` links nothing. The planner was written as pure
/// Swift (no ImageIO/UIKit) precisely so this mirror can be exact. Keep it in sync by hand with
/// `GifDecodePlanner` (+ `AnimatedGifDecoder.decodeBudgetBytes` / `decodeLimits`) whenever that
/// logic changes; if `NuvioTV` ever grows a hosted unit-test target, move these there and delete
/// the mirror.
final class GifDecodePlanTests: XCTestCase {

    // MARK: - Mirror of AnimatedGifDecoder.GifDecodePlanner

    private struct Limits {
        let ceiling: Int; let preferredMinSide: Int; let minSide: Int; let budgetBytes: Int
        func clamped(toSourceLongEdge edge: Int?) -> Limits {
            guard let edge, edge > 0, edge < ceiling else { return self }
            return Limits(ceiling: edge, preferredMinSide: preferredMinSide, minSide: minSide, budgetBytes: budgetBytes)
        }
    }
    private struct Plan: Equatable { let side: Int; let keepCount: Int; let minKeptFrames: Int }

    private let maxSubsampledFrameDelayCentiseconds = 5 // BUG-39 (beta.13): was 12
    private let estimatedRowAlignmentBytes = 32

    private func frameBytes(side: Int, aspect: Double) -> Int {
        let width: Int
        let height: Int
        if aspect >= 1 {
            width = side
            height = max(1, Int((Double(side) / aspect).rounded()))
        } else {
            width = max(1, Int((Double(side) * aspect).rounded()))
            height = side
        }
        let row = width * 4
        let alignedRow = (row + estimatedRowAlignmentBytes - 1) / estimatedRowAlignmentBytes * estimatedRowAlignmentBytes
        return alignedRow * height
    }

    private func minKeptFrames(count: Int, delays: [Int]) -> Int {
        guard count > 0 else { return 0 }
        let total = delays.reduce(0, +)
        let byRate = (total + maxSubsampledFrameDelayCentiseconds - 1) / maxSubsampledFrameDelayCentiseconds
        return min(count, max(1, byRate))
    }

    private func largestSide(fitting frames: Int, aspect: Double, lo: Int, hi: Int, budget: Int) -> Int? {
        guard hi >= lo, frames > 0 else { return nil }
        let pixelsPerFrame = Double(budget) / (4.0 * Double(frames))
        let estimate = aspect >= 1
            ? (pixelsPerFrame * aspect).squareRoot()
            : (pixelsPerFrame / aspect).squareRoot()
        var side = min(hi, Int(estimate))
        while side >= lo {
            if frames * frameBytes(side: side, aspect: aspect) <= budget { return side }
            side -= 1
        }
        return nil
    }

    private func framesFitting(side: Int, aspect: Double, budget: Int) -> Int {
        budget / max(frameBytes(side: side, aspect: aspect), 1)
    }

    private func plan(count: Int, aspect rawAspect: Double, delays: [Int], limits: Limits) -> Plan {
        let aspect = rawAspect.isFinite && rawAspect > 0 ? rawAspect : 1.0
        let ceiling = max(limits.ceiling, 1)
        let minSide = max(1, min(limits.minSide, ceiling))
        let preferred = max(minSide, min(limits.preferredMinSide, ceiling))
        let budget = max(limits.budgetBytes, 1)
        let minKept = minKeptFrames(count: count, delays: delays)
        guard count > 0 else { return Plan(side: ceiling, keepCount: 0, minKeptFrames: 0) }

        if let side = largestSide(fitting: count, aspect: aspect, lo: preferred, hi: ceiling, budget: budget) {
            return Plan(side: side, keepCount: count, minKeptFrames: minKept)
        }
        let keepAtPreferred = min(count, framesFitting(side: preferred, aspect: aspect, budget: budget))
        if keepAtPreferred >= minKept {
            return Plan(side: preferred, keepCount: keepAtPreferred, minKeptFrames: minKept)
        }
        if let side = largestSide(fitting: minKept, aspect: aspect, lo: minSide, hi: preferred, budget: budget) {
            return Plan(side: side, keepCount: minKept, minKeptFrames: minKept)
        }
        let keepAtFloor = max(1, min(count, framesFitting(side: minSide, aspect: aspect, budget: budget)))
        return Plan(side: minSide, keepCount: keepAtFloor, minKeptFrames: minKept)
    }

    // MARK: - Mirror of AnimatedGifDecoder.decodeBudgetBytes / decodeLimits

    private let maxDecodedBytesPerGif = 12 * 1024 * 1024
    private let minFramePixelSize = 200
    private let maxFramePixelSize = 400

    private func decodeBudgetBytes(scale: CGFloat) -> Int {
        let cappedScale = max(1.0, min(scale.isFinite ? scale : 1.0, 2.0))
        let growth = 1.0 + 0.5 * (cappedScale - 1.0)
        return Int((Double(maxDecodedBytesPerGif) * growth).rounded())
    }

    private func targetDecodePixelCeiling(for targetSize: CGSize, scale: CGFloat) -> Int {
        let cappedScale = min(scale, 2.0)
        let pixelCap = Int((CGFloat(maxFramePixelSize) * cappedScale).rounded())
        let longEdge = max(targetSize.width, targetSize.height)
        guard longEdge.isFinite, longEdge > 0 else { return pixelCap }
        let pixels = Int((longEdge * cappedScale).rounded())
        return min(pixelCap, max(minFramePixelSize, pixels))
    }

    private func decodeLimits(for targetSize: CGSize, scale: CGFloat) -> Limits {
        let ceiling = targetDecodePixelCeiling(for: targetSize, scale: scale)
        let longEdge = max(targetSize.width, targetSize.height)
        let pointSide = longEdge.isFinite && longEdge > 0 ? Int(longEdge.rounded()) : ceiling
        return Limits(
            ceiling: ceiling,
            preferredMinSide: min(ceiling, max(minFramePixelSize, pointSide)),
            minSide: minFramePixelSize,
            budgetBytes: decodeBudgetBytes(scale: scale)
        )
    }

    // The default-PosterStyle landscape collection tile (`FolderTile`: 220 × 16/9 ≈ 391 × 220 pt),
    // which is what the 2026-08-11 device pass measured BUG-39 on.
    private let landscapeTile = CGSize(width: 220 * 16 / 9, height: 220)
    private let squareTile = CGSize(width: 220, height: 220)
    private let portraitTile = CGSize(width: 220, height: 330)
    private let deviceGifAspect = 1.75   // 200×114 px frames at the 200 px floor = 7113600 / 78 bytes

    // MARK: - Budget

    func testBudget_isBaseOnHD_and1_5xOn4K_andCappedAbove2x() {
        XCTAssertEqual(decodeBudgetBytes(scale: 1), 12 * 1024 * 1024)
        XCTAssertEqual(decodeBudgetBytes(scale: 2), 18 * 1024 * 1024)
        XCTAssertEqual(decodeBudgetBytes(scale: 3), 18 * 1024 * 1024)
        XCTAssertEqual(decodeBudgetBytes(scale: .nan), 12 * 1024 * 1024)
    }

    func testLimits_landscapeTile4K() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        XCTAssertEqual(l.ceiling, 782)          // the device probe's `ceiling=782`
        XCTAssertEqual(l.preferredMinSide, 391) // 1 px per point
        XCTAssertEqual(l.minSide, 200)
        XCTAssertEqual(l.budgetBytes, 18 * 1024 * 1024)
    }

    func testLimits_HD_preferredEqualsCeiling() {
        let l = decodeLimits(for: landscapeTile, scale: 1)
        XCTAssertEqual(l.ceiling, 391)
        XCTAssertEqual(l.preferredMinSide, 391)
        XCTAssertEqual(l.budgetBytes, 12 * 1024 * 1024)
    }

    // MARK: - The device-measured case

    /// The pre-trade code decoded this GIF at 200×114 px × 78 frames (`side=200 ceiling=782
    /// sourceFrames=90 keptFrames=78 bytes=7113600` on the Living Room 4K). BUG-39 (beta.13): with
    /// the frame-rate floor at 5 cs a 10 cs source keeps ALL 90 frames (uniform cadence) and tier 4
    /// spends the budget on the side instead — 301 px wide × 90 frames, still 2.3× the pixels per
    /// frame of the 200 px baseline. (beta.12 shipped 328 px × 75 frames; the reporter called the
    /// subsample "beaucoup plus saccadés".)
    func testDeviceCase_90frameLandscape_10cs_4K() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        let p = plan(count: 90, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 90), limits: l)
        XCTAssertEqual(p, Plan(side: 301, keepCount: 90, minKeptFrames: 90))
        XCTAssertLessThanOrEqual(90 * frameBytes(side: 301, aspect: deviceGifAspect), l.budgetBytes)
        // And it did not leave more than one frame's worth of budget unspent.
        XCTAssertGreaterThan(90 * frameBytes(side: 302, aspect: deviceGifAspect), l.budgetBytes - frameBytes(side: 302, aspect: deviceGifAspect))
    }

    /// Same GIF, faster source (5 cs/frame — 20 fps): sits exactly ON the new floor, so not one
    /// frame may be dropped; tier 4 lands the same 301 px × 90. (beta.12: 391 px × 53 frames on an
    /// irregular 5/10 cs cadence — the judder BUG-39 was re-reported for.)
    func testDeviceCase_90frameLandscape_5cs_4K_keepsAllFrames_tier4() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        let p = plan(count: 90, aspect: deviceGifAspect, delays: Array(repeating: 5, count: 90), limits: l)
        XCTAssertEqual(p, Plan(side: 301, keepCount: 90, minKeptFrames: 90))
    }

    /// HD panel, same GIF: 245 px wide × all 90 frames (aspect-awareness alone lifted the old 200;
    /// beta.12 was 270 × 75).
    func testDeviceCase_90frameLandscape_10cs_HD() {
        let l = decodeLimits(for: landscapeTile, scale: 1)
        let p = plan(count: 90, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 90), limits: l)
        XCTAssertEqual(p, Plan(side: 245, keepCount: 90, minKeptFrames: 90))
    }

    /// BUG-39: tier 3 (drop frames while holding the preferred side) now only ever engages for
    /// sources FASTER than the 5 cs floor — a 4 cs (25 fps) source may lose a fifth of its frames.
    func testTier3_only_for_sub5csSources() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        // 120 frames × 4 cs at the device aspect: too big for 391 px with every frame; the floor is
        // 480 cs / 5 = 96 kept frames.
        let p = plan(count: 120, aspect: deviceGifAspect, delays: Array(repeating: 4, count: 120), limits: l)
        XCTAssertEqual(p.minKeptFrames, 96)
        XCTAssertLessThan(p.keepCount, 120)
        XCTAssertGreaterThanOrEqual(p.keepCount, 96)
    }

    /// BUG-39: the common GIF cadences (5 cs = 20 fps, 10 cs = 10 fps) never lose a frame before
    /// the side has been driven all the way down to the floor (tier 5).
    func testAllFramesKept_forCommonDelays() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        for delay in [5, 6, 8, 10, 12] {
            for count in [30, 60, 90, 150] {
                let p = plan(count: count, aspect: deviceGifAspect, delays: Array(repeating: delay, count: count), limits: l)
                if p.side > l.minSide {
                    XCTAssertEqual(p.keepCount, count, "delay=\(delay) count=\(count) dropped frames above the floor side: \(p)")
                }
            }
        }
    }

    // MARK: - Tiers

    func testTier1_shortGif_fullCeiling_allFrames() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        let p = plan(count: 10, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 10), limits: l)
        XCTAssertEqual(p, Plan(side: 782, keepCount: 10, minKeptFrames: 10))
    }

    func testTier2_squareTile_allFramesAboveHDParity() {
        let l = decodeLimits(for: squareTile, scale: 2)   // ceiling 440, preferred 220
        let p = plan(count: 60, aspect: 1.0, delays: Array(repeating: 10, count: 60), limits: l)
        XCTAssertEqual(p, Plan(side: 280, keepCount: 60, minKeptFrames: 60))
        XCTAssertGreaterThanOrEqual(p.side, l.preferredMinSide)
    }

    func testTier2_portraitTile_aspectBelowOne() {
        let l = decodeLimits(for: portraitTile, scale: 2)   // ceiling 660, preferred 330
        let p = plan(count: 40, aspect: 2.0 / 3.0, delays: Array(repeating: 8, count: 40), limits: l)
        XCTAssertEqual(p, Plan(side: 420, keepCount: 40, minKeptFrames: 40))
        // Portrait: the long edge is the HEIGHT, so bytes are width(=side×aspect) × side.
        XCTAssertEqual(frameBytes(side: 420, aspect: 2.0 / 3.0), 1120 * 420)
    }

    func testTier5_pathologicalLength_floorSide_keepsWhatFits() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        let p = plan(count: 400, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 400), limits: l)
        XCTAssertEqual(p, Plan(side: 200, keepCount: 206, minKeptFrames: 400))
        XCTAssertLessThanOrEqual(206 * frameBytes(side: 200, aspect: deviceGifAspect), l.budgetBytes)
    }

    // MARK: - Invariants

    func testEveryPlan_fitsBudget_andRespectsClamps() {
        let l4k = decodeLimits(for: landscapeTile, scale: 2)
        let lhd = decodeLimits(for: squareTile, scale: 1)
        for limits in [l4k, lhd] {
            for count in [1, 3, 12, 30, 78, 90, 150, 600] {
                for aspect in [0.5, 2.0 / 3.0, 1.0, 1.75, 2.4] {
                    for delay in [2, 5, 10, 20, 100] {
                        let p = plan(count: count, aspect: aspect, delays: Array(repeating: delay, count: count), limits: limits)
                        XCTAssertLessThanOrEqual(p.keepCount * frameBytes(side: p.side, aspect: aspect), limits.budgetBytes,
                                                 "count=\(count) aspect=\(aspect) delay=\(delay) → \(p)")
                        XCTAssertGreaterThanOrEqual(p.side, limits.minSide)
                        XCTAssertLessThanOrEqual(p.side, limits.ceiling)
                        XCTAssertGreaterThanOrEqual(p.keepCount, 1)
                        XCTAssertLessThanOrEqual(p.keepCount, count)
                        // Frames are only dropped once resolution has already fallen to HD parity.
                        if p.keepCount < count { XCTAssertLessThanOrEqual(p.side, limits.preferredMinSide) }
                        // Resolution only goes below HD parity once the frame floor is binding.
                        if p.side < limits.preferredMinSide { XCTAssertLessThanOrEqual(p.keepCount, p.minKeptFrames) }
                    }
                }
            }
        }
    }

    func testDegenerateInputs() {
        let l = decodeLimits(for: landscapeTile, scale: 2)
        XCTAssertEqual(plan(count: 0, aspect: 1, delays: [], limits: l), Plan(side: 782, keepCount: 0, minKeptFrames: 0))
        // Non-finite / non-positive aspect → treated as square.
        XCTAssertEqual(plan(count: 10, aspect: .nan, delays: Array(repeating: 10, count: 10), limits: l),
                       plan(count: 10, aspect: 1, delays: Array(repeating: 10, count: 10), limits: l))
        XCTAssertEqual(plan(count: 10, aspect: 0, delays: Array(repeating: 10, count: 10), limits: l),
                       plan(count: 10, aspect: 1, delays: Array(repeating: 10, count: 10), limits: l))
        // Missing delays (parser failure) → rate floor is 1 frame, plan still valid.
        let p = plan(count: 30, aspect: 1, delays: [], limits: l)
        XCTAssertEqual(p.minKeptFrames, 1)
        XCTAssertLessThanOrEqual(p.keepCount * frameBytes(side: p.side, aspect: 1), l.budgetBytes)
    }

    /// ImageIO never upscales: a 300×171 source on the 782-ceiling tile is planned at a 300 ceiling,
    /// where all 90 frames fit at the source's own size — no frames are traded for pixels the
    /// source doesn't have. (Unclamped, the planner would have dropped to 75 frames at 328.)
    func testSourceSmallerThanTile_clampsCeiling_keepsAllFrames() {
        let l = decodeLimits(for: landscapeTile, scale: 2).clamped(toSourceLongEdge: 300)
        XCTAssertEqual(l.ceiling, 300)
        let p = plan(count: 90, aspect: deviceGifAspect, delays: Array(repeating: 10, count: 90), limits: l)
        XCTAssertEqual(p, Plan(side: 300, keepCount: 90, minKeptFrames: 90))
        // A source larger than the ceiling leaves the limits untouched.
        XCTAssertEqual(decodeLimits(for: landscapeTile, scale: 2).clamped(toSourceLongEdge: 1280).ceiling, 782)
        XCTAssertEqual(decodeLimits(for: landscapeTile, scale: 2).clamped(toSourceLongEdge: nil).ceiling, 782)
    }

    func testMinKeptFrames_isDurationOverFiveCentiseconds() {
        XCTAssertEqual(minKeptFrames(count: 90, delays: Array(repeating: 10, count: 90)), 90)  // ≥ floor: keep all
        XCTAssertEqual(minKeptFrames(count: 90, delays: Array(repeating: 5, count: 90)), 90)   // exactly the floor
        XCTAssertEqual(minKeptFrames(count: 90, delays: Array(repeating: 4, count: 90)), 72)   // 360 cs / 5
        XCTAssertEqual(minKeptFrames(count: 5, delays: Array(repeating: 100, count: 5)), 5)    // never above count
        XCTAssertEqual(minKeptFrames(count: 5, delays: Array(repeating: 2, count: 5)), 2)      // 10 cs / 5
    }
}
