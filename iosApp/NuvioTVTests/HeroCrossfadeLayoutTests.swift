import XCTest
import SwiftUI
@testable import NuvioTV
import SharedCore
import UIKit

/// Unit tests for BUG-95 (beta.18) — Steven's report: "when the image that needs to be displayed
/// is not the same size as the previous one, it waits until we move onto it before
/// repositioning/cropping itself, so we see the repositioning happen." Filmed on a folder backdrop
/// with Show Hero off (the FEAT-15 focus panel, `nuvioStyle` forced on): blank panel with plain
/// text title → logo crossfading in → the folder's mosaic backdrop appears heavily cropped →
/// settles less cropped ~35 frames later.
///
/// Root cause (`Screens/HomeView.swift`): `HeroCrossfadeImage.body` is a `ZStack` whose only
/// children were the optional `current`/`previous` `Image`s. With neither resolved yet (a folder
/// hero's very first paint, mid-fetch — `HeroArtResolver.folderDeadline` is 1.5s), the ZStack had
/// NO children at all and so no size of its own; a childless SwiftUI stack ignores whatever size
/// its parent proposes and reports its own minimal default instead. The moment the first bitmap
/// landed, the stack gained its first real child and its size jumped from that collapsed default
/// straight to the full proposed frame — inside `HeroArtResolver.commit`'s `withAnimation`, so
/// SwiftUI interpolated the jump and `.scaledToFill()` computed its crop against a box that was
/// still growing on every intermediate frame of that 0.3s animation.
///
/// The fix adds a `Color.clear` ZStack child in `HeroCrossfadeImage.body`: a `Color` always reports
/// the FULL proposed size regardless of whether any bitmap sibling exists, so the ZStack's own size
/// is now invariant across every state the crossfade passes through. These tests probe the ACTUAL
/// SwiftUI layout algorithm via `UIHostingController.sizeThatFits(in:)` (no window or app launch
/// needed) rather than a hand-written stand-in for it — the bug lived entirely in how SwiftUI sizes
/// a stack with a `Color.clear` child versus without one, which is not arithmetic this file owns,
/// so a pure math helper could not have caught a regression here.
@MainActor
final class HeroCrossfadeLayoutTests: XCTestCase {

    /// The exact proposal `HomeHeroBackdrop.backdrop` gives this view in Nuvio-style/focus-panel
    /// mode (`heroNuvioArtworkWidth` × `heroBackdropHeight`) — the geometry the tester's video was
    /// filmed under (Show Hero off forces `nuvioStyle` on for the FEAT-15 panel).
    private var proposed: CGSize {
        CGSize(width: Theme.Size.heroNuvioArtworkWidth, height: Theme.Size.heroBackdropHeight)
    }

    private func makeImage(size: CGFloat = 4) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    // MARK: - Fix #1: the container's size no longer depends on bitmap presence

    /// The direct regression probe: before the fix, this exact construction (image-driven mode,
    /// `image: nil`, nothing resolved yet) reported a collapsed size — SwiftUI's default for a
    /// childless stack, nowhere near `proposed`. After the fix it must claim the FULL proposed
    /// size on its very first layout pass, precisely because there is no longer a "before the
    /// first bitmap lands" state that differs geometrically from "after".
    func testEmptyContainerReportsTheFullProposedSizeNotACollapsedOne() {
        let controller = UIHostingController(rootView: HeroCrossfadeImage(image: nil, identity: "bug95-empty:1"))
        controller.view.backgroundColor = .clear

        let measured = controller.sizeThatFits(in: proposed)

        XCTAssertEqual(measured.width, proposed.width, accuracy: 0.5,
                       "an empty HeroCrossfadeImage (no bitmap yet) must claim the full proposed width, not collapse — got \(measured), proposed \(proposed)")
        XCTAssertEqual(measured.height, proposed.height, accuracy: 0.5,
                       "an empty HeroCrossfadeImage (no bitmap yet) must claim the full proposed height, not collapse — got \(measured), proposed \(proposed)")
    }

    /// The bug was specifically a JUMP between two different sizes at two different moments of the
    /// same view's life — a folder's `current`/`previous` both start nil and one of them is filled
    /// in moments later. Measuring both states independently and asserting they are IDENTICAL is
    /// the direct proof that no such jump remains, regardless of animation: there is nothing left
    /// for any transaction (ambient or explicit) to interpolate between.
    func testContainerSizeIsIdenticalWithAndWithoutABitmap() {
        let empty = UIHostingController(rootView: HeroCrossfadeImage(image: nil, identity: "bug95-cmp:empty"))
        let filled = UIHostingController(rootView: HeroCrossfadeImage(image: makeImage(), identity: "bug95-cmp:filled"))

        let emptySize = empty.sizeThatFits(in: proposed)
        let filledSize = filled.sizeThatFits(in: proposed)

        XCTAssertEqual(emptySize.width, filledSize.width, accuracy: 0.5,
                       "the container's width must not depend on bitmap presence — empty=\(emptySize) filled=\(filledSize)")
        XCTAssertEqual(emptySize.height, filledSize.height, accuracy: 0.5,
                       "the container's height must not depend on bitmap presence — empty=\(emptySize) filled=\(filledSize)")
        XCTAssertEqual(filledSize.width, proposed.width, accuracy: 0.5)
        XCTAssertEqual(filledSize.height, proposed.height, accuracy: 0.5)
    }

    /// Same probe at a second, differently-shaped proposal (a folder cover's aspect versus a title
    /// backdrop's) — the fix must not be an accident of one particular size.
    func testContainerSizeIsIdenticalAtASecondProposedSize() {
        let secondProposal = CGSize(width: 640, height: 640)
        let empty = UIHostingController(rootView: HeroCrossfadeImage(image: nil, identity: "bug95-cmp2:empty"))
        let filled = UIHostingController(rootView: HeroCrossfadeImage(image: makeImage(), identity: "bug95-cmp2:filled"))

        let emptySize = empty.sizeThatFits(in: secondProposal)
        let filledSize = filled.sizeThatFits(in: secondProposal)

        XCTAssertEqual(emptySize.width, filledSize.width, accuracy: 0.5)
        XCTAssertEqual(emptySize.height, filledSize.height, accuracy: 0.5)
    }

    // MARK: - The commit's own no-op guard ("presentation diff")
    //
    // `HeroArtResolver.commit` is private, so it cannot be driven directly from a unit test — the
    // task's own fallback for exactly this shape ("if [commit's animation behavior is] untestable
    // without a seam, extract the presentation diff into a pure function and test that instead").
    // `HeroPresentation`'s `Equatable` conformance IS that diff: `commit`'s
    // `guard next != presented else { return }` is the single gate deciding whether ANY update
    // (the resolver's own `withAnimation`, or a future caller's) happens at all — a presentation
    // that reads as equal must never reach that assignment, animated or not. Testing "commit
    // produces no animated transaction" directly is not possible via XCTest (SwiftUI's Transaction/
    // Animation state is not introspectable from outside the render pass it applies to), so this is
    // the closest in-scope, pure surface to it; see the fix's own code comment on `commit` for why
    // the withAnimation there was kept rather than removed.

    private func makeItem(id: String = "1", type: String = "movie", name: String = "Movie") -> MetaPreview {
        MetaPreview(
            id: id, type: type, name: name,
            poster: nil, banner: "https://example.com/banner.jpg", logo: "https://example.com/logo.png",
            posterShape: .poster,
            description: nil, releaseInfo: nil, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: []
        )
    }

    func testIdenticalPresentationsAreEqual() {
        let item = makeItem()
        let backdrop = makeImage()
        let logo = makeImage()
        let a = HeroPresentation(item: item, backdrop: backdrop, logo: logo, identity: "movie:1")
        let b = HeroPresentation(item: item, backdrop: backdrop, logo: logo, identity: "movie:1")
        XCTAssertEqual(a, b, "same item, same bitmap references, same identity must diff as equal — a repeat commit of this must be a no-op")
    }

    func testDifferentIdentityIsNeverEqual() {
        let item = makeItem()
        let backdrop = makeImage()
        let a = HeroPresentation(item: item, backdrop: backdrop, logo: nil, identity: "movie:1")
        let b = HeroPresentation(item: item, backdrop: backdrop, logo: nil, identity: "movie:2")
        XCTAssertNotEqual(a, b, "a different identity is a genuine new hero regardless of matching bitmaps")
    }

    /// `HeroPresentation` compares images by REFERENCE (`ArtworkStore` hands out one decoded
    /// instance per URL), so two pixel-identical-but-distinct bitmaps must still diff as a change —
    /// this is what lets a re-resolved backdrop for the SAME title commit as a genuine repaint.
    func testDifferentBackdropReferenceAtTheSameIdentityIsNotEqual() {
        let item = makeItem()
        let a = HeroPresentation(item: item, backdrop: makeImage(), logo: nil, identity: "movie:1")
        let b = HeroPresentation(item: item, backdrop: makeImage(), logo: nil, identity: "movie:1")
        XCTAssertNotEqual(a, b, "two distinct UIImage instances must not compare equal even with identical pixels")
    }

    /// A payload-only change (e.g. a late TMDB synopsis gap-fill) at the same identity and the same
    /// artwork is exactly the "same=1... but only text refreshed" shape `HeroArtResolver.present`'s
    /// same-identity branch handles separately from `commit` — but the RAW diff here must still
    /// read as a change (`item.isEqual` sees the new name), which is what lets that branch decide
    /// whether to log anything, rather than `commit`'s blunt guard silently swallowing it.
    func testDifferentItemPayloadAtTheSameIdentityIsNotEqual() {
        let backdrop = makeImage()
        let a = HeroPresentation(item: makeItem(name: "Old Title"), backdrop: backdrop, logo: nil, identity: "movie:1")
        let b = HeroPresentation(item: makeItem(name: "New Title"), backdrop: backdrop, logo: nil, identity: "movie:1")
        XCTAssertNotEqual(a, b, "a renamed item at the same identity must still diff as a change")
    }

    // MARK: - Fix #2 (BUG-95, 2026-09-08): the leaves are UIKit-backed, not SwiftUI `Image`

    /// Recursively finds every `UIImageView` under `root` — `HeroBitmapLayer`'s hosted view is
    /// nested inside whatever SwiftUI's `UIViewRepresentable` bridging wraps it in, so a direct
    /// `subviews` check is not enough.
    private func findImageViews(_ root: UIView) -> [UIImageView] {
        var found: [UIImageView] = []
        if let imageView = root as? UIImageView {
            found.append(imageView)
        }
        for subview in root.subviews {
            found.append(contentsOf: findImageViews(subview))
        }
        return found
    }

    /// Hosts `rootView` inside a real `UIWindow` (a `UIHostingController` needs to be window-backed
    /// for `layoutIfNeeded()` to drive a real layout pass all the way down to the UIKit-backed
    /// `HeroBitmapLayer` leaves — `sizeThatFits(in:)`, which the rest of this file uses, only
    /// measures the SwiftUI side and never actually lays out the hosted `UIImageView`s). `.frame`
    /// is set to `proposed` directly rather than proposed through the hosting controller, matching
    /// how `HomeHeroBackdrop.backdrop`'s real call site constrains this view — a fixed-size parent
    /// frame, not a `sizeThatFits` negotiation. The hosting controller otherwise applies tvOS
    /// safe-area insets (80 pt horizontal, 60 pt vertical total) to its root view, shrinking the
    /// content box and making the assertion measure the wrong dimensions.
    @discardableResult
    private func hostAndLayout(_ rootView: HeroCrossfadeImage, in proposed: CGSize) -> UIHostingController<HeroCrossfadeImage> {
        let controller = UIHostingController(rootView: rootView)
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        let window = UIWindow(frame: CGRect(origin: .zero, size: proposed))
        window.rootViewController = controller
        controller.view.frame = CGRect(origin: .zero, size: proposed)
        window.isHidden = false
        controller.view.layoutIfNeeded()
        return controller
    }

    /// Direct regression probe for the `HeroBitmapLayer` swap itself: seeds `current` from
    /// `HeroCrossfadeImage.init(image:identity:)` (which seeds `current` synchronously — see that
    /// initializer) with a 16:9 bitmap, lays it out at `proposed`, and asserts the hosted
    /// `UIImageView`'s `bounds` exactly matches the container — never the bitmap's own 160×90 size —
    /// then repeats with a 1:1 bitmap at the same proposal. Before the fix (`Image(uiImage:)
    /// .resizable().scaledToFill()`) there was no UIKit view to bound-check at all; after it, the
    /// `UIImageView`'s bounds are driven purely by the container frame regardless of the bitmap's
    /// aspect ratio, which is the whole point of the UIKit-backed leaf (see `HeroBitmapLayer`'s doc
    /// comment in HomeView.swift).
    func testBitmapLayerBoundsMatchTheContainerForBothAspects() {
        let widescreen = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        }
        let square = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }

        for (label, img) in [("16x9", widescreen), ("1x1", square)] {
            let controller = hostAndLayout(
                HeroCrossfadeImage(image: img, identity: "bug95-layer:\(label)"),
                in: proposed
            )
            let imageViews = findImageViews(controller.view)
            XCTAssertEqual(imageViews.count, 1,
                           "\(label): expected exactly one hosted UIImageView (the seeded 'current' HeroBitmapLayer) — found \(imageViews.count)")
            guard let imageView = imageViews.first else { continue }
            XCTAssertEqual(imageView.bounds.size.width, proposed.width, accuracy: 0.5,
                           "\(label): UIImageView width must match the container's proposed width, not the \(img.size) bitmap's own size — got \(imageView.bounds.size)")
            XCTAssertEqual(imageView.bounds.size.height, proposed.height, accuracy: 0.5,
                           "\(label): UIImageView height must match the container's proposed height, not the \(img.size) bitmap's own size — got \(imageView.bounds.size)")
            XCTAssertEqual(imageView.contentMode, .scaleAspectFill,
                           "\(label): HeroBitmapLayer must configure aspect-fill content mode")
            XCTAssertTrue(imageView.clipsToBounds,
                          "\(label): HeroBitmapLayer must clip to bounds — otherwise an aspect-filled image can overflow its frame")
            XCTAssertTrue(imageView.image === img,
                          "\(label): the hosted UIImageView must display the exact seeded bitmap instance")
        }
    }
}
