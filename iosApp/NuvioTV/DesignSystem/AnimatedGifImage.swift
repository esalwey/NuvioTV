import Combine
import ImageIO
import SwiftUI
import UIKit

/// Renders an animated GIF as a looping `UIImageView`, with the folder's static cover art shown
/// underneath while the GIF downloads/decodes and on any decode failure — the tile is never
/// blank. SwiftUI's `Image(uiImage:)` only ever draws an animated `UIImage`'s first frame, so
/// playback needs `UIImageView.startAnimating()`, hence the `UIViewRepresentable` wrapper.
///
/// Ported from the mobile Kotlin/Native reference,
/// `composeApp/src/iosMain/kotlin/com/nuvio/app/features/home/components/CollectionCardRemoteImage.ios.kt`:
/// `gifImageWithData` (ImageIO frame extraction + `UIImage.animatedImage(with:duration:)`),
/// `parseGifFrameDurations` (per-frame Graphic Control Extension delay parsing), and
/// `expandedGifFrames` (GCD-based frame-reference duplication so unequal per-frame delays still
/// play back correctly on a single fixed-duration `UIImage` animation).
///
/// BUG-19 (4th attempt — the first three moved decode work around without removing the actual
/// main-thread cost per focus step). The measured symptom was a 700–830 ms freeze of EVERY visible
/// tile on each D-pad step, i.e. a main-thread hang, not a slow animation. Four levers, all of
/// which had to land together:
///   1. the GIF `URLSession`'s `URLCache` had no `directory:`, so it silently had no disk tier at
///      all (same defect ArtworkStore hit — see the `session` comment below);
///   2. the memory cache's cost accounting made every realistic entry larger than the whole
///      budget, so it was evicted on insert and the "cached" path never hit (see `AnimatedGifCache`);
///   3. fetch + cache-write ran on the main actor (only the CGImage expansion hopped off);
///   4. the view was mounted/unmounted by focus, so every step tore down a whole pipeline (freeing
///      the expanded frame array on the main thread in `dismantleUIView`) and built a new one.
/// The view is now mounted for the tile's whole lifetime and focus only toggles
/// `isAnimating`/opacity — see `FolderTile` in `CollectionsUI.swift`.
struct AnimatedGifImage: View {
    private let url: URL?
    private let fallbackURLString: String?
    private let contentMode: ContentMode
    private let isAnimating: Bool
    private let targetSize: CGSize

    @StateObject private var loader = AnimatedGifLoader()

    /// - Parameters:
    ///   - string: the animated GIF's URL (Kotlin-bridged `String?`; empty/nil → no animation).
    ///   - fallback: the folder's static cover, shown underneath while the GIF loads and if it
    ///     never resolves to an animated image (bad URL, decode failure, non-GIF data). Pass `nil`
    ///     when the caller already mounts the cover itself (`FolderTile` does, so the cover isn't
    ///     torn down and re-decoded alongside the GIF).
    ///   - isAnimating: BUG-19 — drives playback AND visibility without changing view identity.
    ///     `false` keeps the decoded frames alive in this view's loader but stops the
    ///     `UIImageView` and fades the GIF out to reveal the cover underneath. The first
    ///     transition to `true` is also what lazily kicks off the download/decode: a 15-tile row
    ///     must not decode 15 GIFs at mount.
    ///   - targetSize: BUG-39 — the tile's actual rendered size, in points (e.g. `FolderTile`
    ///     passes its own `tileWidth`/`tileHeight`). Lets `AnimatedGifDecoder` downsample to
    ///     roughly what's actually displayed instead of a fixed worst-case pixel guess, so the
    ///     same 12 MiB per-GIF frame budget buys several times more frames at typical collection-
    ///     tile size — see `AnimatedGifDecoder.targetDecodePixelCeiling`. Captured once, at the
    ///     first `prepare()` call this loader makes for a given URL (see `AnimatedGifLoader.
    ///     prepare`'s doc for why a LATER `targetSize` change — e.g. the user live-editing the
    ///     Poster Style width in Settings — deliberately does NOT trigger a re-decode.
    init(
        string: String?,
        fallback: String?,
        contentMode: ContentMode = .fill,
        isAnimating: Bool = true,
        targetSize: CGSize
    ) {
        if let string, !string.isEmpty {
            self.url = URL(string: string)
        } else {
            self.url = nil
        }
        self.fallbackURLString = fallback
        self.contentMode = contentMode
        self.isAnimating = isAnimating
        self.targetSize = targetSize
    }

    /// Visible only once there is something to show AND the tile wants animation — until then the
    /// cover (this view's own fallback, or the caller's) shows through.
    private var gifVisible: Bool { isAnimating && loader.image != nil }

    var body: some View {
        ZStack {
            if let fallbackURLString, !fallbackURLString.isEmpty {
                CachedAsyncImage(string: fallbackURLString, contentMode: contentMode)
            }

            // Always mounted (BUG-19 lever 4): no `if` around this view, so focus changes never
            // create/destroy a UIImageView and never free the expanded frame array on the main
            // thread. `image` is nil until the decode lands.
            AnimatedUIImageView(
                image: loader.image,
                contentMode: contentMode,
                isAnimating: isAnimating
            )
            .opacity(gifVisible ? 1 : 0)
            .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.15), value: gifVisible)
        .onAppear {
            loader.prepare(url, targetSize: targetSize)
            if isAnimating { loader.loadIfNeeded() }
        }
        .onChange(of: url) { _, newURL in
            loader.prepare(newURL, targetSize: targetSize)
            if isAnimating { loader.loadIfNeeded() }
        }
        .onChange(of: isAnimating) { _, animating in
            // Lazy first focus: the decode starts here, not at mount.
            if animating { loader.loadIfNeeded() }
        }
    }
}

/// Thin `UIViewRepresentable` around `UIImageView` — the only UIKit type that actually plays an
/// animated `UIImage`'s frames back.
///
/// BUG-19: playback is now driven by the `isAnimating` INPUT rather than by the view's existence.
/// `makeUIView`/`dismantleUIView` therefore run once per tile instead of once per focus step, and
/// an unfocused tile costs exactly one stopped `UIImageView` holding an already-decoded image.
private struct AnimatedUIImageView: UIViewRepresentable {
    let image: UIImage?
    let contentMode: ContentMode
    let isAnimating: Bool

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: UIImageView) {
        if view.image !== image {
            // Reassigning `image` while animating leaves UIImageView's frame timer pointing at the
            // old frame array; stop first (this is the Kotlin reference's `updateGifImage` order).
            if view.isAnimating { view.stopAnimating() }
            view.image = image
        }
        if isAnimating, image != nil {
            if !view.isAnimating { view.startAnimating() }
        } else if view.isAnimating {
            // Stopped, NOT dismantled: the frames stay retained by the loader/cache so re-focusing
            // this tile is a `startAnimating()` call, not a fresh download+decode.
            view.stopAnimating()
        }
    }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: ()) {
        uiView.stopAnimating()
        uiView.image = nil
    }
}

/// Loads, decodes, and caches one animated-GIF URL for one `AnimatedGifImage`. Shaped like this
/// file's neighbor `CachedImageLoader` (`CachedAsyncImage.swift`): a `@MainActor`
/// `ObservableObject` that cancels its in-flight work when superseded or deallocated.
///
/// BUG-19: split into `prepare` (free — point at a URL, answer synchronously from the memory
/// cache, never start work) and `loadIfNeeded` (starts the one download+decode, at most once per
/// URL). `prepare` alone must stay cheap because every tile in a row calls it at mount.
@MainActor
private final class AnimatedGifLoader: ObservableObject {
    @Published var image: UIImage?

    private var currentURL: URL?
    /// BUG-39: the render target this loader will decode `currentURL` at, set once per URL by
    /// `prepare` (see its doc). Deliberately NOT re-read on every `loadIfNeeded` call from `body`
    /// — it's captured at `prepare` time and stays pinned for that URL's whole lifetime.
    private var currentTargetSize: CGSize = .zero
    private var task: Task<Void, Never>?
    /// Whether `loadIfNeeded` has already spent (or is spending) a fetch on `currentURL`. This is
    /// a RETRY LATCH, not a one-shot flag: on a failed decode it is cleared again (see below) so
    /// the tile's next focus retries, up to `maxLoadAttempts` total tries for this URL — only
    /// after the cap is reached does it stay latched, so a permanently-dead URL stops
    /// re-downloading on every focus.
    private var didRequestLoad = false
    /// Attempts already spent on `currentURL`. Reset only when `prepare` points the loader at a
    /// genuinely new URL (see below), so this counts total tries per URL, not per call.
    private var attemptCount = 0
    /// Retry cap (FINDING 1): a transient network error or truncated download must not permanently
    /// latch `didRequestLoad` — that left `image == nil` forever with no future focus ever trying
    /// again. But an unconditional retry-on-every-focus would hammer a permanently-dead URL
    /// forever too. Three attempts splits the difference: enough to ride out a flaky connection,
    /// bounded enough that a truly broken URL settles on the static cover for good.
    private static let maxLoadAttempts = 3

    /// Point the loader at a URL WITHOUT starting any network/decode work. A synchronous memory
    /// cache hit is taken immediately (that's the whole reason the cache exists — see
    /// `AnimatedGifCache`'s cost arithmetic, which previously made every hit a miss).
    ///
    /// BUG-39: `targetSize` is stored ONLY when `url` is actually new (the early-return guard
    /// below). If the caller's `targetSize` changes later without the URL changing — e.g. the
    /// user live-edits the Poster Style width in Settings while this tile is already decoded or
    /// mid-decode — this method is a no-op and the stale `currentTargetSize` from the first call
    /// keeps driving `loadIfNeeded`. That is deliberate: a target-size change is not worth a
    /// re-decode. Forcing one would mean every visible tile re-fetches and re-decodes its GIF the
    /// moment a settings slider moves, which is exactly the kind of main-thread/network churn
    /// BUG-19 spent four attempts eliminating from the FOCUS path — doing it from the SETTINGS
    /// path instead would just move the hang, not remove it. The visible cost is that a tile
    /// keeps whatever resolution it first decoded at until its GIF URL itself changes (a new
    /// folder, a refreshed feed, etc.), which is unnoticeable given collection-tile GIFs are
    /// already palette-quantised and low-detail.
    func prepare(_ url: URL?, targetSize: CGSize) {
        guard url != currentURL else { return }
        currentURL = url
        currentTargetSize = targetSize
        task?.cancel()
        task = nil
        didRequestLoad = false
        attemptCount = 0
        image = AnimatedGifCache.cached(url)
    }

    /// Lazily start the fetch+decode — called on the tile's FIRST focus, not at mount.
    func loadIfNeeded() {
        guard let url = currentURL, image == nil, !didRequestLoad else { return }
        didRequestLoad = true

        if let cached = AnimatedGifCache.cached(url) {
            image = cached
            return
        }

        attemptCount += 1
        let isFinalAttempt = attemptCount >= Self.maxLoadAttempts
        let targetSize = currentTargetSize

        task = Task { [weak self] in
            let decoded = await AnimatedGifDecoder.decode(url, targetSize: targetSize)
            if Task.isCancelled { return }
            guard let self, self.currentURL == url else { return }
            if let decoded {
                self.image = decoded
            } else if !isFinalAttempt {
                // FINDING 1 fix: clear the latch so the NEXT focus (not this one — no busy-retry)
                // re-attempts the fetch+decode. Once `attemptCount` hits the cap, fall through and
                // leave the latch set: `image` stays nil and the caller's fallback cover shows
                // indefinitely instead of refetching a dead URL on every subsequent focus.
                self.didRequestLoad = false
            }
        }
    }

    deinit { task?.cancel() }
}

/// Dedicated animated-image cache — deliberately NOT `ArtworkStore.memory` (`CachedAsyncImage.swift`).
/// That cache's cost accounting assumes one decoded single-frame bitmap per entry; an animated
/// `UIImage` here carries many frames, so it gets its own explicitly-costed budget instead of
/// silently blowing the shared artwork cache's assumptions.
///
/// BUG-19 cost arithmetic (the old numbers made this cache a no-op). Entry cost is now the TRUE
/// sum of every unique decoded frame's bitmap (`AnimatedGifDecoder.decodedGif`), and the decoder
/// caps that sum at the per-GIF budget (`maxDecodedBytesPerGif` = 12 MiB on HD, 18 MiB on 4K —
/// `decodeBudgetBytes`) by trading resolution and unique frames for long GIFs
/// (`GifDecodePlanner`). So:
///
///   * worst case per entry ...... 12 MiB HD / 18 MiB 4K (any long GIF on a large/landscape
///     tile — the planner spends the whole budget when the frame count demands it)
///   * typical square "Services"-style tile (BUG-39: decodes near its own ~220 px tile size, not
///     a blanket 400 px) ... 20 frames × 220×220 RGBA (~194 KB) ≈ 3.9 MB — well under budget, so
///     a GIF like this now keeps EVERY source frame instead of being frame-subsampled
///   * short 10-frame loop at the same tile size ........ 10 × 194 KB ≈ 1.9 MB
///
/// (See `AnimatedGifDecoder.targetDecodePixelCeiling` for the full per-tile-size breakdown; the
/// old fixed-400px numbers this comment used to cite are now only the worst case, not the norm.)
///
///   totalCostLimit = `worstCaseEntries` (16) × the per-GIF budget — 192 MB on HD, 302 MB on 4K
///   (`ensureCostLimit`, set from the first decode's budget). BUG-39 (beta.12) device data showed
///   why it must scale AND cover a whole row: the Living Room's Collections row is 13 GIF tiles
///   and every one plans to within 1.5% of the 4K budget (~18.6 MB), so the old fixed 144 MB held
///   only ~7 of them and the walk BACK re-decoded every tile (one GIF 11× in 11 s at the row
///   end). Eviction only costs a re-decode from the disk-cached bytes, but that is a static-cover
///   flash per step — exactly BUG-19's symptom class. `NSCache` still purges on memory pressure,
///   so this is a ceiling, not a footprint.
///   countLimit 24 covers the Services + Genres rows' visible+prefetched tiles together (the old
///   limit of 12 was per the Kotlin reference's `MaxCachedGifImages`, which is a phone-sized row).
///
/// The old configuration was countLimit 12 / 64 MB against an entry cost of
/// `frameCount × firstFrameBytes` ≈ 86 MB for a 60-frame 800 px collage: every entry exceeded the
/// entire budget, so `NSCache` evicted it during the very `setObject` that inserted it and the
/// synchronous hit path never fired — every focus step re-downloaded and re-decoded.
///
/// `nonisolated(unsafe)` mirrors `ArtworkStore.memory`: `NSCache` locks internally, and the
/// decoder writes to it from a detached task while views read it synchronously.
private enum AnimatedGifCache {
    nonisolated(unsafe) static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 24
        cache.totalCostLimit = worstCaseEntries * 12 * 1024 * 1024   // HD baseline; see `ensureCostLimit`
        return cache
    }()

    /// How many budget-sized entries the cache should hold — one full collections row (13 GIF
    /// tiles measured on device) with headroom. Was 12 (the 144 MB HD figure's basis) before the
    /// beta.12 device read showed a real row overflowing it.
    private static let worstCaseEntries = 16

    /// BUG-39 (beta.12): raise the cost limit to `worstCaseEntries` × the scale-aware per-GIF
    /// budget the decoder actually uses (`AnimatedGifDecoder.decodeBudgetBytes`). Called from
    /// `decode` on the main actor before every decode; only ever grows, so it is idempotent and
    /// cheap. Kept out of the static initializer because the budget needs `UIScreen.main.scale`.
    static func ensureCostLimit(forPerGifBudget budget: Int) {
        let wanted = worstCaseEntries * max(budget, 1)
        if shared.totalCostLimit < wanted { shared.totalCostLimit = wanted }
    }

    /// Synchronous lookup — safe from any context (`NSCache` is thread-safe).
    static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return shared.object(forKey: url as NSURL)
    }
}

/// Fetch + decode pipeline for animated GIFs, with in-flight de-duplication per URL (mirrors
/// `ArtworkStore.fetch`'s `inflight` dictionary shape).
///
/// This file gets its own disk-backed `URLSession` rather than reusing `ArtworkStore.session`
/// (which is `private` to `CachedAsyncImage.swift`), configured the same way
/// (`.returnCacheDataElseLoad`, a bounded `URLCache` **in its own directory**, the same 20 MB
/// download ceiling), so repeated focus/unfocus cycles on one tile hit disk instead of the network.
///
/// BUG-19: only `decode`'s bookkeeping is `@MainActor` now. The download, the ImageIO decode, the
/// frame expansion and the cache write all run on a detached task, so a focus step never waits on
/// them.
private enum AnimatedGifDecoder {
    private static let maxDownloadBytes = 20 * 1024 * 1024
    private static let defaultFrameDelayCentiseconds = 10

    /// BUG-19 lever (a). The `URLCache` MUST be given its own `directory:`. Constructed without
    /// one — as this session was — the instance shares the app's default cache store with
    /// `URLCache.shared` (which the Ktor/Supabase sessions open too); two `URLCache` instances
    /// over one store is unsupported and this one silently lost its disk tier: writes landed in
    /// Cache.db but every lookup missed. That is exactly the defect ArtworkStore hit and fixed in
    /// commit 8ab9fa23 (BUG-26, documented at `CachedAsyncImage.swift:78–95`); the GIF session was
    /// written from the same template *before* that fix and inherited the bug, which is why every
    /// focus step re-downloaded the GIF bytes over the network.
    nonisolated(unsafe) private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GifURLCache", isDirectory: true)
        config.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,     // 8 MB
            diskCapacity: 128 * 1024 * 1024,     // 128 MB of compressed GIF bytes
            directory: cacheDir
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    @MainActor private static var inflight: [URL: Task<UIImage?, Never>] = [:]

    /// De-dupe bookkeeping and the final `UIImage` handoff stay on the main actor; everything
    /// expensive happens inside the detached task.
    ///
    /// BUG-39: `targetSize` (points) is converted to a pixel ceiling HERE, on the main actor,
    /// because it needs `UIScreen.main.scale` — reading it inside the detached task would touch
    /// UIKit off the main thread. The resulting `Int` is a plain Sendable value, so it crosses
    /// into `Task.detached` for free.
    ///
    /// Note on de-dupe: if two tiles with DIFFERENT `targetSize`s race for the same GIF `url`
    /// (e.g. a portrait and a landscape folder both referencing the same shared GIF asset), the
    /// second one's request just awaits the first one's already-in-flight `work` and gets that
    /// decode's resolution, not its own. This is the same "keep the first decode" trade-off as
    /// `prepare`'s target-size latch above, and for the same reason: starting a second concurrent
    /// decode of the same bytes at a different size to chase per-tile pixel-perfection would cost
    /// real main-thread/network work for a difference that's invisible on a palette-quantised GIF.
    @MainActor
    static func decode(_ url: URL, targetSize: CGSize) async -> UIImage? {
        if let cached = AnimatedGifCache.cached(url) { return cached }
        if let existing = inflight[url] {
            return await existing.value
        }

        let limits = decodeLimits(for: targetSize, scale: UIScreen.main.scale)
        AnimatedGifCache.ensureCostLimit(forPerGifBudget: limits.budgetBytes)

        // `Task.detached` (not `Task`): a plain `Task` created here would INHERIT @MainActor, which
        // is what put `fetchData`'s await, the frame expansion and the cache write on the main
        // thread. Only the CGImage decode hopped off before.
        let work = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard let data = try? await fetchData(url) else { return nil }
            guard let result = decodedGif(from: data, limits: limits, probeTag: url.lastPathComponent) else { return nil }
            AnimatedGifCache.shared.setObject(result.image, forKey: url as NSURL, cost: result.cost)
            return result.image
        }
        inflight[url] = work
        defer { inflight[url] = nil }
        return await work.value
    }

    /// BUG-39: pixel ceiling for ImageIO's `kCGImageSourceThumbnailMaxPixelSize`, derived from the
    /// TILE's actual rendered point size instead of the old blanket `maxFramePixelSize` guess
    /// applied to every tile in the app regardless of its real size (that guess is now only the
    /// outer safety cap, below).
    ///
    /// `scale` converts the tile's point size to a pixel budget as if displayed at up to
    /// Retina/4K density; capping the SCALE itself at 2.0 — not just the final pixel count — is
    /// the "2x layout size" ceiling: a hypothetical higher-density screen can't blow the budget
    /// just because `UIScreen.main.scale` reports more than 2. The result is then clamped into
    /// `[minFramePixelSize, maxFramePixelSize]`: the floor protects a degenerate near-zero/NaN
    /// `targetSize` (defensive only — `FolderTile` computes its `targetSize` synchronously from
    /// `PosterStyle`, not from a UIKit layout pass, so it's never actually zero in practice) from
    /// producing a useless sliver thumbnail, and the ceiling means no tile can decode at a LARGER
    /// pixel size than the pre-BUG-39 fixed guess — this can only shrink the per-frame cost,
    /// never grow it past the old worst case.
    ///
    /// Concrete numbers for the default `PosterStyle` (220×330 pt portrait tiles, 220×220 pt
    /// square "Services"-style tiles, ~391×220 pt landscape tiles):
    ///   * square tile, scale 1 (Apple TV HD) → 220 px vs the old fixed 400 px: ~3.3× more bytes
    ///     of budget left per frame, so a GIF that used to fit ~20 frames now fits ~65+.
    ///   * portrait tile, scale 1 → 330 px vs 400 px: ~1.5× more frames.
    ///   * landscape tile, scale 1 → 391 px, barely below the 400 px cap: little change.
    ///   * at scale 2 (Apple TV 4K) the cap itself is scale-aware (beta.12): a 330 pt tile may
    ///     decode at up to 660 px instead of being clamped to 400 px (~half its real backing
    ///     store — the "still average" sharpness BUG-39's re-report measured). The per-GIF byte
    ///     budget still clamps longer GIFs below this ceiling exactly as before.
    private nonisolated static func targetDecodePixelCeiling(for targetSize: CGSize, scale: CGFloat) -> Int {
        let cappedScale = min(scale, 2.0)
        // BUG-39 (beta.12): the outer cap is a POINT budget, so it must scale with the panel like
        // the tile's own backing store does. The old `min(maxFramePixelSize, …)` treated 400 as a
        // PIXEL cap, which on a scale-2 (4K) panel decoded every GIF at ~half the tile's real
        // backing resolution — measured luma softness the reporter called "still average". A
        // scale-1 (HD) panel is byte-identical to the old behavior; on 4K, per-frame cost can rise
        // up to 4× for SHORT GIFs only — `GifDecodePlanner` + the enforced running-total check
        // still clamp anything longer, so the per-GIF budget remains the hard bound either way.
        let pixelCap = Int((CGFloat(maxFramePixelSize) * cappedScale).rounded())
        let longEdge = max(targetSize.width, targetSize.height)
        guard longEdge.isFinite, longEdge > 0 else { return pixelCap }
        let pixels = Int((longEdge * cappedScale).rounded())
        return min(pixelCap, max(minFramePixelSize, pixels))
    }

    /// BUG-39 (beta.12, frame-vs-resolution trade): everything `decodedGif` needs to know about
    /// the display target, derived on the main actor (needs `UIScreen.main.scale`) and handed to
    /// the detached decode as one Sendable value.
    ///
    ///   * `ceiling` — `targetDecodePixelCeiling`: the tile's full backing store, the most any
    ///     frame is ever decoded at.
    ///   * `preferredMinSide` — the tile's long edge in POINTS (1 px per point = what an HD panel
    ///     shows), clamped to `[minFramePixelSize, ceiling]`. The planner keeps every frame down
    ///     to this side before it starts dropping frames; below it, sharpness is what the device
    ///     pass measured as "still average" (a 391 pt landscape tile drawing 200 px frames).
    ///   * `budgetBytes` — `decodeBudgetBytes(scale:)`, the per-GIF hard bound.
    private nonisolated static func decodeLimits(for targetSize: CGSize, scale: CGFloat) -> GifDecodePlanner.Limits {
        let ceiling = targetDecodePixelCeiling(for: targetSize, scale: scale)
        let longEdge = max(targetSize.width, targetSize.height)
        let pointSide = longEdge.isFinite && longEdge > 0 ? Int(longEdge.rounded()) : ceiling
        return GifDecodePlanner.Limits(
            ceiling: ceiling,
            preferredMinSide: min(ceiling, max(minFramePixelSize, pointSide)),
            minSide: minFramePixelSize,
            budgetBytes: decodeBudgetBytes(scale: scale)
        )
    }

    /// BUG-39 (beta.12): the per-GIF decoded-bitmap budget, scale-aware. `maxDecodedBytesPerGif`
    /// (12 MiB) was sized for the HD panel; a scale-2 (4K) tile has 4× the backing pixels, and
    /// the device pass showed the budget — not the ceiling — is what clamps real 80–90-frame
    /// collection GIFs to 200 px there. Growing it linearly with the capped scale (12 MiB HD →
    /// 18 MiB 4K) is deliberately HALF the pixel-proportional (scale²) growth: the Apple TV 4K
    /// boxes carry ~1.5–2× the HD box's RAM, so the row-of-tiles worst case
    /// (`AnimatedGifCache` doc: 15 × per-GIF budget) grows no faster than the hardware under it.
    /// HD panels are byte-identical to before.
    private nonisolated static func decodeBudgetBytes(scale: CGFloat) -> Int {
        let cappedScale = max(1.0, min(scale.isFinite ? scale : 1.0, 2.0))
        let growth = 1.0 + 0.5 * (cappedScale - 1.0)
        return Int((Double(maxDecodedBytesPerGif) * growth).rounded())
    }

    private nonisolated static func fetchData(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
        guard !data.isEmpty, data.count <= maxDownloadBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }

        // BUG-19 lever (e): a truncated body still decodes — ImageIO happily returns the frames it
        // could parse and fills the rest with garbage, which is the 2-frame magenta corruption
        // caught on camera. Status + byte count can't see this (a cut-off transfer is still 200 OK
        // with a plausible length), so validate the container itself before anything caches or
        // renders it, and evict the bad bytes from the disk cache so the next focus retries the
        // network instead of replaying the corruption forever.
        guard isCompleteGif(data) else {
            session.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    /// Cheap completeness check on the raw payload: GIF magic, a parseable image source, and
    /// ImageIO's own "I have all the bytes" verdict.
    private nonisolated static func isCompleteGif(_ data: Data) -> Bool {
        guard hasGifHeader([UInt8](data.prefix(6))) else { return false }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        guard CGImageSourceGetStatus(source) == .statusComplete else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    // MARK: - GIF decode (ported from `gifImageWithData` / `expandedGifFrames`)

    private struct DecodedGif {
        let image: UIImage
        /// Sum of EVERY unique frame's decoded bitmap bytes, for `NSCache`'s cost accounting.
        /// (The expanded array repeats frames by reference, so it adds no bitmap memory.)
        let cost: Int
    }

    private struct GifFrame {
        let image: CGImage
        let delayCentiseconds: Int
    }

    /// Outer safety cap on the per-frame downsample ceiling's long edge, regardless of tile size —
    /// in POINTS as of beta.12 (BUG-39 re-report): `targetDecodePixelCeiling` multiplies it by the
    /// capped screen scale, so it is 400 px on an HD panel and 800 px on a 4K one. tvOS lays every
    /// app out in a fixed 1920×1080 POINT space, so even the largest realistic collection tile
    /// (~360–420 pt landscape) tops out around here in points — but treating this as a PIXEL cap
    /// (the pre-beta.12 behavior) decoded every GIF at ~half its backing store on 4K, which is the
    /// measured softness the reporter kept filing.
    ///
    /// BUG-39: before this fix, EVERY tile decoded up to this fixed value regardless of its own
    /// rendered size — a 220 pt square tile paid the same per-frame bitmap cost as a 420 pt
    /// landscape one. `targetDecodePixelCeiling` (near `AnimatedGifDecoder.decode`) now derives
    /// the ACTUAL per-call ceiling from the tile's real `targetSize`, and this constant is only
    /// the upper bound that derivation is clamped to — so no tile can decode at a larger pixel
    /// size than before, but most tiles now decode well below it. See that function's doc for the
    /// concrete before/after numbers.
    private static let maxFramePixelSize = 400
    /// Absolute floor for any frame's decoded long edge — never decode a tile-sized GIF smaller
    /// than this. When even `GifDecodePlanner`'s frame-rate floor can't hold the budget at this
    /// side, the planner drops MORE unique frames rather than going below it (see
    /// `subsampledIndices`) — the floor never lets a single GIF exceed the budget.
    private static let minFramePixelSize = 200
    /// Base (HD-panel) hard budget for ONE decoded GIF's total bitmap memory; `decodeBudgetBytes`
    /// scales it for 4K. FINDING B (round 2): actually enforced against the REAL running total of
    /// `bytesPerRow × height` for every frame as it decodes (see the budget check in
    /// `decodedGif`) — the planner's up-front resolution/frame-count choice estimates row strides
    /// (`GifDecodePlanner.frameBytes`) and could still be off by a few bytes per row, so it alone
    /// is not the hard bound; the decode-time check is what makes this literally true for the
    /// stored cache entry. A row of tiles keeps its decoded frames alive while mounted (that's the
    /// point of the fix), so the per-GIF number, not just the cache total, is what bounds a
    /// 15-tile row: 15 × 12 MiB = 180 MiB (HD) / 15 × 18 MiB = 270 MiB (4K) is a real worst case
    /// now, and in practice the `LazyHStack` unmounts scrolled-away tiles well before that.
    private static let maxDecodedBytesPerGif = 12 * 1024 * 1024

    /// BUG-39 (beta.12, frame-vs-resolution trade) — the pure planning half of `decodedGif`: given
    /// a GIF's frame count, aspect ratio and per-frame delays, plus the display `Limits`, pick the
    /// decode side (long edge, px) and how many unique frames to keep so the result fits the
    /// budget with the LEAST visible loss.
    ///
    /// Why a planner at all: the pre-beta.12 code assumed square frames (`side² × 4`), so a
    /// landscape tile's frames (391×220 pt → 200×114 px at the floor) used only ~59% of the budget
    /// (device pass: `bytes=7113600` of 12 MiB); and once frames stopped fitting it dropped
    /// straight to the 200 px floor before giving up a single frame — resolution was always
    /// sacrificed first, unboundedly, and there was no notion of "too soft to be worth it".
    ///
    /// The tiered trade, cheapest visible loss first:
    ///   1. every frame at the full backing store (`ceiling`), if it fits;
    ///   2. else every frame at the largest side that fits, but no lower than `preferredMinSide`
    ///      (1 px per point — HD parity — the sharpness floor below which the reporter's
    ///      complaint starts);
    ///   3. else hold `preferredMinSide` and DROP FRAMES, evenly across the animation, down to
    ///      `minKeptFrames` (the GIF's own total duration ÷ `maxSubsampledFrameDelayCentiseconds`
    ///      — an ~8 fps floor, so a 10 cs/frame source keeps ~80% of its frames, a 5 cs/frame
    ///      source can lose half and still play smoothly);
    ///   4. else hold `minKeptFrames` and shrink the side again, down to `minSide` (200 px);
    ///   5. else (pathological length) hold `minSide` and drop frames further — the pre-beta.12
    ///      behavior, now the last resort instead of the second.
    /// Kept frames' delays are summed over the frames they stand in for (`decodedGif`), so total
    /// playback duration is unchanged in every tier.
    ///
    /// Pure Swift on purpose (no ImageIO/UIKit): `NuvioTVUITests/GifDecodePlanTests.swift`
    /// mirrors it exactly — keep the two in sync by hand.
    nonisolated enum GifDecodePlanner {
        struct Limits: Sendable {
            let ceiling: Int
            let preferredMinSide: Int
            let minSide: Int
            let budgetBytes: Int

            /// ImageIO thumbnails never upscale past the source, so a GIF authored smaller than
            /// the tile can't be decoded at `ceiling` no matter what — cap the ceiling at the
            /// source's long edge or the planner would trade away frames for resolution that
            /// doesn't exist. (`plan` re-clamps `preferredMinSide`/`minSide` under the new ceiling.)
            func clamped(toSourceLongEdge edge: Int?) -> Limits {
                guard let edge, edge > 0, edge < ceiling else { return self }
                return Limits(ceiling: edge, preferredMinSide: preferredMinSide, minSide: minSide, budgetBytes: budgetBytes)
            }
        }

        struct Plan: Equatable, Sendable {
            /// `kCGImageSourceThumbnailMaxPixelSize` for every kept frame.
            let side: Int
            /// Unique source frames to decode (`≤ sourceCount`); `subsampledIndices` picks which.
            let keepCount: Int
            /// The frame-rate floor the plan honored (diagnostic — surfaces in the probe line).
            let minKeptFrames: Int
        }

        /// Frame-rate floor for tier 3: after subsampling, no kept frame should stand in for more
        /// than this much source time (~20 fps). Below that, a movie-clip loop reads as a slideshow,
        /// which is a worse 10-foot artifact than moderate softness — so the planner spends
        /// resolution again (tier 4) before it goes past this.
        ///
        /// BUG-39 (beta.13): was 12 cs (~8 fps). The beta.12 device read on the Living Room 4K
        /// said "sharper and smooth enough"; the reporter's AppleTV11,1 said "beaucoup plus
        /// saccadés" — the tier-3 subsample of a 5 cs source (90 → 53 frames on an IRREGULAR
        /// 5/10 cs cadence) is judder, and it was trading the smoothness that closed BUG-19 for
        /// the last ~20 % of resolution. At 5 cs every ≥5 cs source keeps ALL its frames (uniform
        /// cadence) and tier 4 lowers the side instead: the device case lands ≈300 px / 90 frames
        /// rather than 391 px / 53 — still 1.5× beta.11's 200 px.
        static let maxSubsampledFrameDelayCentiseconds = 5
        /// Estimated `CGImage` row-stride alignment. Thumbnail bitmaps come back with padded
        /// `bytesPerRow`; estimating with 32-byte alignment keeps the plan at or slightly above
        /// the real cost, so the decode-time hard check almost never has to truncate.
        static let estimatedRowAlignmentBytes = 32

        /// Estimated decoded bytes of one frame whose long edge is `side` px at `aspect`
        /// (source width ÷ height, > 0). Landscape sources have their width on the long edge,
        /// portrait ones their height.
        static func frameBytes(side: Int, aspect: Double) -> Int {
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

        /// The fewest unique frames the plan may keep for a GIF whose clamped per-frame delays
        /// (centiseconds) are `delays`: its total duration spread no thinner than
        /// `maxSubsampledFrameDelayCentiseconds` per kept frame, at least 1, at most `count`.
        static func minKeptFrames(count: Int, delays: [Int]) -> Int {
            guard count > 0 else { return 0 }
            let total = delays.reduce(0, +)
            let byRate = (total + maxSubsampledFrameDelayCentiseconds - 1) / maxSubsampledFrameDelayCentiseconds
            return min(count, max(1, byRate))
        }

        /// Largest side in `[lo, hi]` at which `frames` frames fit the budget, or nil if even
        /// `lo` doesn't.
        static func largestSide(fitting frames: Int, aspect: Double, lo: Int, hi: Int, budget: Int) -> Int? {
            guard hi >= lo, frames > 0 else { return nil }
            let pixelsPerFrame = Double(budget) / (4.0 * Double(frames))
            // Long-edge estimate from the unpadded pixel area; the loop below corrects for
            // rounding and row alignment.
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

        /// How many frames fit the budget at `side` (may be 0).
        static func framesFitting(side: Int, aspect: Double, budget: Int) -> Int {
            budget / max(frameBytes(side: side, aspect: aspect), 1)
        }

        static func plan(count: Int, aspect rawAspect: Double, delays: [Int], limits: Limits) -> Plan {
            let aspect = rawAspect.isFinite && rawAspect > 0 ? rawAspect : 1.0
            let ceiling = max(limits.ceiling, 1)
            let minSide = max(1, min(limits.minSide, ceiling))
            let preferred = max(minSide, min(limits.preferredMinSide, ceiling))
            let budget = max(limits.budgetBytes, 1)
            let minKept = minKeptFrames(count: count, delays: delays)
            guard count > 0 else { return Plan(side: ceiling, keepCount: 0, minKeptFrames: 0) }

            // Tiers 1–2: all frames, side in [preferred, ceiling].
            if let side = largestSide(fitting: count, aspect: aspect, lo: preferred, hi: ceiling, budget: budget) {
                return Plan(side: side, keepCount: count, minKeptFrames: minKept)
            }
            // Tier 3: hold the preferred side, drop frames down to the rate floor.
            let keepAtPreferred = min(count, framesFitting(side: preferred, aspect: aspect, budget: budget))
            if keepAtPreferred >= minKept {
                return Plan(side: preferred, keepCount: keepAtPreferred, minKeptFrames: minKept)
            }
            // Tier 4: hold the rate floor, shrink the side down to the absolute floor.
            if let side = largestSide(fitting: minKept, aspect: aspect, lo: minSide, hi: preferred, budget: budget) {
                return Plan(side: side, keepCount: minKept, minKeptFrames: minKept)
            }
            // Tier 5: absolute floor, keep whatever fits (at least 1 — the decode-time hard check
            // fails the whole GIF if even one frame overflows).
            let keepAtFloor = max(1, min(count, framesFitting(side: minSide, aspect: aspect, budget: budget)))
            return Plan(side: minSide, keepCount: keepAtFloor, minKeptFrames: minKept)
        }
    }

    /// FINDING 5: evenly-spaced source-frame indices to keep when `GifDecodePlanner` decides to
    /// keep fewer unique frames than the source has. Spreads the kept frames across the whole
    /// animation (not just the first N) so subsampling doesn't visibly favor the start.
    private nonisolated static func subsampledIndices(totalCount: Int, keepCount: Int) -> [Int] {
        guard keepCount < totalCount, keepCount > 0 else { return Array(0..<totalCount) }
        let stride = Double(totalCount) / Double(keepCount)
        var indices: [Int] = []
        indices.reserveCapacity(keepCount)
        var seen = Set<Int>()
        for i in 0..<keepCount {
            let index = min(Int(Double(i) * stride), totalCount - 1)
            if seen.insert(index).inserted {
                indices.append(index)
            }
        }
        return indices.isEmpty ? [0] : indices
    }

    /// Source pixel size of the first frame, from the container's own properties — no decode.
    /// `nil` if ImageIO can't say (the planner then assumes square and an unclamped ceiling,
    /// which is the pre-beta.12 behavior).
    private nonisolated static func sourcePixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private nonisolated static func decodedGif(from data: Data, limits: GifDecodePlanner.Limits, probeTag: String = "") -> DecodedGif? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let delays = parseFrameDurations(data)

        // BUG-39 (beta.12): decide UP FRONT how to spend the budget — see `GifDecodePlanner` for
        // the tiered resolution-vs-frames trade. The planner is fed the same clamped per-source
        // delays the summation loops below use, so its frame-rate floor and the kept frames'
        // aggregate delays agree.
        //
        // FINDING B (round 2): the planner's `frameBytes` is still an ESTIMATE of `bytesPerRow ×
        // height` (row alignment guessed, not measured), so it only steers the choice; it is NOT
        // what enforces the budget — the running `decodedBytesTotal` check in the decode loop
        // below is the actual, literal enforcement point.
        let clampedDelays = (0..<count).map { i -> Int in
            let raw = i < delays.count ? delays[i] : defaultFrameDelayCentiseconds
            return min(max(raw, minExpandedFrameDelayCentiseconds), maxRawFrameDelayCentiseconds)
        }
        let sourceSize = sourcePixelSize(source)
        let aspect = sourceSize.map { Double($0.width) / Double($0.height) } ?? 1.0
        let planLimits = limits.clamped(toSourceLongEdge: sourceSize.map { max($0.width, $0.height) })
        let plan = GifDecodePlanner.plan(count: count, aspect: aspect, delays: clampedDelays, limits: planLimits)
        let frameIndices = subsampledIndices(totalCount: count, keepCount: plan.keepCount)
        let decodeSide = plan.side
        let budgetBytes = max(limits.budgetBytes, 1)

        var frames: [GifFrame] = []
        frames.reserveCapacity(frameIndices.count)
        // FINDING B (round 2): the actual, ENFORCED running total of decoded bitmap bytes — the
        // sum of `bytesPerRow × height` for every frame actually kept, updated as each frame
        // decodes (see the budget check below). This, not the planner's estimate, is what makes
        // the "the budget is an enforced bound" doc comment on `maxDecodedBytesPerGif` literally true.
        var decodedBytesTotal = 0

        // BUG-19: `CGImageSourceCreateImageAtIndex` returns LAZILY-decoded images — the actual
        // bitmap decompression then happened on the MAIN thread at render time, once per frame
        // at full GIF resolution, which is exactly the scroll stutter the tester reported (every
        // D-pad step focuses a new tile and starts a fresh animation). Thumbnail creation with
        // ShouldCacheImmediately decodes each frame HERE, on this detached task, downsampled to
        // tile size — the render path then just blits ready bitmaps.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSide,
        ]

        for (position, index) in frameIndices.enumerated() {
            // Per-frame completeness (lever e): an individually incomplete frame is the magenta
            // garbage. Fail the whole decode so the caller falls back to the static cover.
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else { return nil }
            // No lazy `CGImageSourceCreateImageAtIndex` fallback any more: it would reintroduce
            // main-thread decompression at render time for exactly the frames we couldn't decode
            // cheaply here. Better a static cover than a stuttering tile.
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions as CFDictionary) else {
                return nil
            }

            // FINDING B (round 2): `bytesPerRow` is CGImage's real (padded/aligned) row stride,
            // which can exceed the unpadded `side × 4` the pre-decode estimate above assumed.
            // Check the ACTUAL cost against the ACTUAL running total before this frame is kept —
            // once keeping it would push the total over `maxDecodedBytesPerGif`, stop decoding
            // (normally keep at least the first frame, guarded by `!frames.isEmpty`) and fold this
            // frame's delay AND every remaining source frame's delay into the last frame that was
            // actually kept, so total playback duration is preserved even though fewer unique
            // bitmaps end up stored.
            let frameBytes = cgImage.bytesPerRow * cgImage.height
            // Defensive guard: the scale-aware downsample ceiling on `decodeSide` (≤400px per
            // point of scale) should make this unreachable in practice, but the budget is
            // documented as a hard bound, so a
            // pathological first frame that alone exceeds it must fail the whole decode (→ static
            // cover) rather than being kept unconditionally by the `!frames.isEmpty` exemption below.
            if frames.isEmpty && frameBytes > budgetBytes {
                return nil
            }
            if !frames.isEmpty && decodedBytesTotal + frameBytes > budgetBytes {
                var extraDelay = 0
                for skipped in index..<count {
                    let raw = skipped < delays.count ? delays[skipped] : defaultFrameDelayCentiseconds
                    extraDelay += min(max(raw, minExpandedFrameDelayCentiseconds), maxRawFrameDelayCentiseconds)
                }
                let last = frames.removeLast()
                let mergedDelay = min(last.delayCentiseconds + extraDelay, maxAggregateFrameDelayCentiseconds)
                frames.append(GifFrame(image: last.image, delayCentiseconds: mergedDelay))
                break
            }

            // FINDING A / FINDING 5: when `frameIndices` is a subsample, this kept frame stands
            // in for itself AND every source frame skipped after it, so its delay is the SUM of
            // that run's RAW delays — fewer unique bitmaps, same total playback duration. Each
            // raw contribution is clamped to `[minExpandedFrameDelayCentiseconds,
            // maxRawFrameDelayCentiseconds]` BEFORE summing (protection against one pathological
            // source frame's delay); the aggregate itself is then bounded separately by the much
            // more generous `maxAggregateFrameDelayCentiseconds` sanity ceiling — NOT by the same
            // per-frame bound, or a heavily-subsampled GIF's kept frames get truncated back down
            // to roughly single-frame timing and the whole animation plays too fast.
            let nextIndex = position + 1 < frameIndices.count ? frameIndices[position + 1] : count
            var delay = 0
            for skipped in index..<nextIndex {
                let raw = skipped < delays.count ? delays[skipped] : defaultFrameDelayCentiseconds
                delay += min(max(raw, minExpandedFrameDelayCentiseconds), maxRawFrameDelayCentiseconds)
            }
            frames.append(GifFrame(image: cgImage, delayCentiseconds: min(max(delay, minExpandedFrameDelayCentiseconds), maxAggregateFrameDelayCentiseconds)))
            decodedBytesTotal += frameBytes
        }
        guard !frames.isEmpty else { return nil }

        let (expandedImages, tickCentiseconds) = expandedFrames(frames)
        let durationSeconds = Double(expandedImages.count * tickCentiseconds) / 100.0
        guard let animated = UIImage.animatedImage(with: expandedImages, duration: durationSeconds) else {
            return nil
        }

        // FINDING B (round 2): `decodedBytesTotal` is the exact, already-enforced sum of every
        // kept frame's actual bitmap bytes (see the budget check above) — use it directly as the
        // cache cost instead of recomputing `bytesPerRow × height` again here.
        if GifDecodeProbe.enabled {
            // BUG-39: the reporter's "still average" sharpness is a function of `decodeSide` vs the
            // tile's real backing store, and of how hard the budget squeezed this particular GIF —
            // numbers nobody can read off a screenshot. beta.12 device data on the pre-trade code:
            // `side=200 ceiling=782 sourceFrames=90 keptFrames=78 bytes=7113600`. The trade adds
            // `preferred` (the 1 px/pt sharpness floor), `minKept` (the ~8 fps frame floor),
            // `aspect` and `budget` so the device pass can read WHICH tier the planner landed in.
            // `file=` (URL last path component) tells a device read whether repeated lines are one
            // GIF re-decoding (cache miss) or a row of same-shaped GIFs — the 2026-08-16 read
            // could not distinguish 11 look-alike Genres tiles from a thrashing tile without it.
            NSLog("[GifDecode] side=%d ceiling=%d preferred=%d sourceFrames=%d keptFrames=%d minKept=%d source=%dx%d budget=%d bytes=%d file=%@",
                  decodeSide, planLimits.ceiling, limits.preferredMinSide, count, frames.count,
                  plan.minKeptFrames, sourceSize?.width ?? 0, sourceSize?.height ?? 0, budgetBytes, decodedBytesTotal, probeTag)
        }
        return DecodedGif(image: animated, cost: max(decodedBytesTotal, 1))
    }

    /// BUG-39 probe knob, same house pattern as `TrailerProbe`/`HomeGeometryProbe`:
    ///
    ///     defaults write com.nuvio.media.NuvioTV debug.gifDecodeProbe -bool YES
    ///
    /// Deliberately not `#if DEBUG` — testers run release sideloads and `log show` is the only
    /// diagnostic channel that comes back from a device pass.
    private enum GifDecodeProbe {
        nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.gifDecodeProbe")
    }

    /// FINDING 6: floor for any frame's delay (raw OR aggregate) BEFORE it enters the GCD-tick
    /// computation below. GIF89a allows any 1–65535 cs delay per RAW frame, so a pathological
    /// file with e.g. a 1 cs frame next to a 65535 cs frame produces `gcd(1, 65535) == 1`: a 1 cs
    /// tick times a many-second total duration expands to hundreds of thousands of retained
    /// `UIImage` references (all pointing at the same handful of unique bitmaps, but each
    /// reference still costs array/object overhead and blows the decode-time peak). This floor
    /// keeps the tick itself from ever going below 2 cs. FINDING A (round 2): the matching UPPER
    /// bound is now split in two — see `maxRawFrameDelayCentiseconds` (applied pre-summation) and
    /// `maxAggregateFrameDelayCentiseconds` (applied post-summation) below — because a single
    /// shared 1000 cs ceiling on both raw and summed delays was truncating heavily-subsampled
    /// GIFs' aggregate frame delays back down to roughly one raw frame's worth.
    private static let minExpandedFrameDelayCentiseconds = 2
    /// FINDING A (round 2): this [2, 1000] cs clamp is protection against a pathological single
    /// GIF frame's raw delay (GIF89a allows 1–65535 cs) — apply it to each RAW per-source-frame
    /// delay BEFORE frames are subsampled and their delays summed (see the `delay +=` loops in
    /// `decodedGif`). It must NOT be reapplied to the SUMMED aggregate a kept frame ends up
    /// carrying: a kept frame standing in for e.g. 20 skipped source frames legitimately needs an
    /// aggregate delay up to ~20× a single frame's, and truncating that back down to 1000 cs made
    /// heavily-subsampled GIFs play substantially faster than their true duration.
    private static let maxRawFrameDelayCentiseconds = 1000
    /// FINDING A (round 2): separate, much more generous ceiling applied to the SUMMED aggregate
    /// delay a single kept frame carries after subsampling — purely a sanity bound on the
    /// expansion arithmetic below (so one absurd aggregate can't multiply `expandedCount` past
    /// anything reasonable before the `maxExpandedFrameCount` cap even gets a chance to look at
    /// it), not a playback-accuracy clamp. 60 s is far beyond any real per-tile GIF's per-frame
    /// hold time; anything hitting this ceiling is already pathological and falls through to the
    /// `maxExpandedFrameCount` uniform-delay fallback below.
    private static let maxAggregateFrameDelayCentiseconds = 60 * 100
    /// FINDING 6: hard ceiling on the TOTAL expanded array length, independent of the clamps above
    /// (a GIF with many frames, each individually reasonable, can still multiply out past this
    /// once ticked). Chosen well above any real per-tile animation's natural frame count so it
    /// only ever fires on pathological/adversarial input.
    private static let maxExpandedFrameCount = 1200

    /// Ported from `expandedGifFrames`: GIF allows each frame its own delay, but
    /// `UIImage.animatedImage(with:duration:)` only takes one total duration divided evenly
    /// across the image array — so frames with a longer delay are repeated (by reference, so no
    /// extra bitmap memory) to fill out their share of a common "tick" (the GCD of all delays).
    private nonisolated static func expandedFrames(_ frames: [GifFrame]) -> (images: [UIImage], tickCentiseconds: Int) {
        // FINDING A (round 2): `GifFrame.delayCentiseconds` already IS the post-summation
        // aggregate (raw per-source delays were clamped to `maxRawFrameDelayCentiseconds` and
        // summed in `decodedGif`, then bounded by `maxAggregateFrameDelayCentiseconds`) — only
        // floor it here, never re-clamp it down to the raw per-frame ceiling, or a kept frame
        // standing in for many skipped ones gets its aggregate truncated right back to roughly a
        // single frame's worth and the whole animation plays too fast.
        let delays = frames.map { max($0.delayCentiseconds, minExpandedFrameDelayCentiseconds) }
        let tick = delays.dropFirst().reduce(delays.first ?? defaultFrameDelayCentiseconds) { greatestCommonDivisor($0, $1) }

        let expandedCount = delays.reduce(0) { $0 + max($1 / tick, 1) }
        guard expandedCount <= maxExpandedFrameCount else {
            // FINDING 6: exact per-frame timing would blow the cap even after clamping — fall
            // back to one reference per unique frame at a uniform delay (the clamped average),
            // matching `UIImage.animatedImage`'s own even-division behavior. Visually
            // indistinguishable from correct timing for the pathological inputs that hit this
            // path; nowhere close for any real tile GIF, which never reaches this branch.
            let averageDelay = max(delays.reduce(0, +) / max(delays.count, 1), minExpandedFrameDelayCentiseconds)
            return (frames.map { UIImage(cgImage: $0.image) }, averageDelay)
        }

        var expanded: [UIImage] = []
        expanded.reserveCapacity(expandedCount)
        for (frame, delay) in zip(frames, delays) {
            let uiImage = UIImage(cgImage: frame.image)
            let repeatCount = max(delay / tick, 1)
            expanded.append(contentsOf: Array(repeating: uiImage, count: repeatCount))
        }
        return (expanded, tick)
    }

    private nonisolated static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return max(x, 1)
    }

    // MARK: - Per-frame delay parsing (ported from `parseGifFrameDurations`)

    private nonisolated static func parseFrameDurations(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, hasGifHeader(bytes) else { return [] }

        var index = 6
        guard index + 7 <= bytes.count else { return [] }

        let logicalScreenPacked = Int(bytes[index + 4])
        index += 7

        if logicalScreenPacked & 0x80 != 0 {
            let globalColorTableSize = 3 * (1 << ((logicalScreenPacked & 0x07) + 1))
            index += globalColorTableSize
        }

        var frameDurations: [Int] = []
        var pendingDelay: Int?

        while index < bytes.count {
            switch Int(bytes[index]) {
            case 0x21:
                guard index + 1 < bytes.count else { return frameDurations }
                let label = Int(bytes[index + 1])
                if label == 0xF9 {
                    guard index + 7 < bytes.count else { return frameDurations }
                    let delay = readUnsignedShort(bytes, index + 4)
                    pendingDelay = delay <= 0 ? defaultFrameDelayCentiseconds : delay
                    index += 8
                } else {
                    index += 2
                    index = skipSubBlocks(bytes, index)
                }

            case 0x2C:
                guard index + 9 < bytes.count else { return frameDurations }
                let imageDescriptorPacked = Int(bytes[index + 9])
                index += 10

                if imageDescriptorPacked & 0x80 != 0 {
                    let localColorTableSize = 3 * (1 << ((imageDescriptorPacked & 0x07) + 1))
                    index += localColorTableSize
                }

                guard index < bytes.count else { return frameDurations }
                index += 1
                index = skipSubBlocks(bytes, index)

                frameDurations.append(pendingDelay ?? defaultFrameDelayCentiseconds)
                pendingDelay = nil

            default:
                return frameDurations
            }
        }

        return frameDurations
    }

    private nonisolated static func hasGifHeader(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 6 &&
            bytes[0] == UInt8(ascii: "G") &&
            bytes[1] == UInt8(ascii: "I") &&
            bytes[2] == UInt8(ascii: "F") &&
            bytes[3] == UInt8(ascii: "8") &&
            (bytes[4] == UInt8(ascii: "7") || bytes[4] == UInt8(ascii: "9")) &&
            bytes[5] == UInt8(ascii: "a")
    }

    private nonisolated static func skipSubBlocks(_ bytes: [UInt8], _ start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let blockSize = Int(bytes[index])
            index += 1
            if blockSize == 0 { return index }
            index += blockSize
        }
        return index
    }

    private nonisolated static func readUnsignedShort(_ bytes: [UInt8], _ start: Int) -> Int {
        guard start + 1 < bytes.count else { return 0 }
        return Int(bytes[start]) | (Int(bytes[start + 1]) << 8)
    }
}
