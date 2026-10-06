import Combine
import ImageIO
import SwiftUI
import UIKit

/// A lightweight, dependency-free replacement for SwiftUI's `AsyncImage`.
///
/// `AsyncImage` re-fetches on every scroll and keeps no disk cache, which on a poster-heavy tvOS
/// grid causes constant flicker and network churn. `CachedAsyncImage` adds an in-memory `NSCache`
/// plus a dedicated on-disk `URLCache`, shows a shimmer while loading, a film-icon on failure, and
/// fades the image in. Swap it in anywhere the app currently uses `AsyncImage` for content art.
struct CachedAsyncImage<Failure: View>: View {
    private let url: URL?
    private let contentMode: ContentMode
    /// BUG-59 (reveal-gate wave): when true, the loaded image is scanned once for letterbox/
    /// pillarbox bars baked into its pixels (`ArtworkLetterbox` — TMDB backdrops are sometimes
    /// trailer stills, bars and all) and overscaled to crop them. OFF by default so every existing
    /// call site renders byte-identically; the caller that turns it on (the inline trailer tile)
    /// must clip, exactly as it must for the video zoom underneath (`InlineTrailerCard`'s
    /// `.clipShape`).
    private let cropsBakedLetterboxBars: Bool
    /// BUG-41: what to show once `loader.failed` is true. Defaults to `DefaultFailureImage` (the
    /// grey surface + film glyph every call site rendered before this parameter existed) via the
    /// `Failure == DefaultFailureImage` initializers below, so every pre-existing call site keeps
    /// compiling — and rendering — unchanged. Callers with a more meaningful fallback (a title, a
    /// person glyph, a company name) pass their own `failure:` builder instead.
    private let failureContent: () -> Failure

    @StateObject private var loader = CachedImageLoader()
    /// 1.0 until (and unless) `ArtworkLetterbox` measures real bars in the loaded image.
    @State private var barCropZoom: CGFloat = 1

    init(url: URL?, contentMode: ContentMode = .fill, cropsBakedLetterboxBars: Bool = false,
         @ViewBuilder failure: @escaping () -> Failure) {
        self.url = url
        self.contentMode = contentMode
        self.cropsBakedLetterboxBars = cropsBakedLetterboxBars
        self.failureContent = failure
    }

    /// Convenience for the many Kotlin-bridged `String` URL fields; empty/nil → no image.
    init(string: String?, contentMode: ContentMode = .fill, cropsBakedLetterboxBars: Bool = false,
         @ViewBuilder failure: @escaping () -> Failure) {
        if let string, !string.isEmpty {
            self.url = URL(string: string)
        } else {
            self.url = nil
        }
        self.contentMode = contentMode
        self.cropsBakedLetterboxBars = cropsBakedLetterboxBars
        self.failureContent = failure
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // `scaleEffect(1)` is the identity for every call site that doesn't opt in.
                    .scaleEffect(barCropZoom)
            } else if loader.failed {
                failureContent()
            } else if url == nil {
                // Nothing to load — flat surface rather than an endless shimmer.
                Theme.Palette.surface
            } else {
                ShimmerView()
            }
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { _, newURL in loader.load(newURL) }
        // BUG-59: measure the loaded image's baked bars off-main, once per URL (memoized in
        // `ArtworkLetterbox`). Keyed on the image (NSObject identity) so a URL change that swaps
        // the image re-runs, and a re-render that doesn't, doesn't.
        .task(id: loader.image) {
            guard cropsBakedLetterboxBars else { return }
            guard let image = loader.image, let key = url?.absoluteString else {
                barCropZoom = 1
                return
            }
            if let hit = ArtworkLetterbox.cachedZoom(forKey: key) {
                barCropZoom = hit
                return
            }
            let measured = await Task.detached(priority: .utility) {
                ArtworkLetterbox.zoom(for: image, cacheKey: key)
            }.value
            guard !Task.isCancelled, loader.image === image else { return }
            withAnimation(.easeOut(duration: 0.25)) { barCropZoom = measured }
        }
    }
}

extension CachedAsyncImage where Failure == DefaultFailureImage {
    /// Every call site that predates BUG-41's `failure:` parameter — unchanged signature, unchanged
    /// grey-surface-plus-film-glyph rendering on a failed load.
    init(url: URL?, contentMode: ContentMode = .fill, cropsBakedLetterboxBars: Bool = false) {
        self.init(url: url, contentMode: contentMode, cropsBakedLetterboxBars: cropsBakedLetterboxBars,
                   failure: { DefaultFailureImage() })
    }

    init(string: String?, contentMode: ContentMode = .fill, cropsBakedLetterboxBars: Bool = false) {
        self.init(string: string, contentMode: contentMode, cropsBakedLetterboxBars: cropsBakedLetterboxBars,
                   failure: { DefaultFailureImage() })
    }
}

/// The pre-BUG-41 failure surface (grey `Theme.Palette.surface` + a film glyph) — content art has
/// no more specific fallback to offer, so this stays the default for every caller that doesn't pass
/// its own `failure:` builder.
struct DefaultFailureImage: View {
    var body: some View {
        ZStack {
            Theme.Palette.surface
            Image(systemName: "film")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

/// Shared artwork pipeline behind `CachedAsyncImage` (and the Home hero's logo/backdrop
/// prefetcher): a process-wide decoded-image memory cache, a dedicated disk-backed session,
/// ImageIO downsampling, and in-flight request coalescing so concurrent views (or a prefetch
/// plus a view) never download the same URL twice.
enum ArtworkStore {
    /// Process-wide in-memory decoded-image cache. Bounded by decoded bytes, not just count —
    /// 400 unbounded images (a 4K RGBA backdrop is ~32 MB decoded) could exceed the Apple TV
    /// process budget during long catalog browsing (HI-006). NSCache is thread-safe, hence the
    /// `nonisolated(unsafe)` escape hatch for synchronous first-frame lookups from view inits.
    nonisolated(unsafe) private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 128 * 1024 * 1024   // decoded bytes
        return cache
    }()

    /// Largest artwork payload we'll accept from the network (compressed bytes).
    private static let maxDownloadBytes = 20 * 1024 * 1024

    /// Dedicated session with a large disk cache for artwork, isolated from data requests.
    ///
    /// BUG-26: the cache MUST be given its own directory. Constructed without one, this
    /// instance shared the app's default cache directory with `URLCache.shared` (which the
    /// Ktor/Supabase sessions open too) — two `URLCache` instances over one store is
    /// unsupported, and this one silently lost the disk tier: writes appeared in Cache.db but
    /// every lookup missed, so EVERY cold start re-downloaded all artwork over the network
    /// (trace-proven: 50/50 loads `net` on a warm-disk relaunch; the reporter's "takes much
    /// longer to reload all the movies and artwork").
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtworkURLCache", isDirectory: true)
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,   // 32 MB
            diskCapacity: 256 * 1024 * 1024,    // 256 MB
            directory: cacheDir
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        // BUG-95 rig finding (2026-09-08): with the default 60 s request timeout, a stalled image
        // host (i.postimg.cc answered 32 KB in 30 s from the fixture) holds one of the six fetch
        // slots for a full minute per request, and every later fetch — the Home hero's own
        // `.head`-admitted backdrop included — queues behind it, so a folder hero can sit blank
        // long after its (healthy, GitHub-hosted) mosaic could have loaded. 20 s is the inactivity
        // window between bytes, not a total budget, so a slow-but-alive download still completes;
        // a dead host now frees its slot three times sooner. The failed URL is not retried by a
        // loader that is still showing it (`CachedAsyncImage`'s unchanged-URL guard); the next
        // fresh `fetch` for that URL — a new tile, a re-presented hero — starts over.
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// One shared task per URL currently downloading, so awaiters coalesce onto it.
    @MainActor private static var inflight: [URL: Task<UIImage, Error>] = [:]

    /// Caps simultaneous download+decode pipelines. Bounds the *transient* peak of in-flight
    /// decoded bitmaps that the memory cache's limits can't see — dozens of rows appearing at
    /// once (catalog-heavy Home load) would otherwise stack unbounded concurrent decodes
    /// (BUG-11). Slots are held only by the shared work tasks, never by coalesced awaiters,
    /// so the gate cannot deadlock.
    private static let maxConcurrentFetches = 6
    @MainActor private static var activeFetches = 0
    @MainActor private static var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    /// Where a fetch goes when all six slots are busy (Codex r3, P2 on the hero commit).
    ///
    /// `.normal` queues behind everything already waiting, which is what every row poster, card
    /// and prefetch wants. `.head` goes to the FRONT: the Home hero's own backdrop and logo are
    /// the two images `HeroCommitCoordinator.prepare(_:)` blocks the whole first paint on, hero
    /// and rows alike, so a cold Home that queues dozens of poster prefetches must not be able to
    /// push them behind that crowd. Slot accounting is unchanged, so the BUG-11 concurrency bound
    /// and the "slots are held only by the shared work tasks" no-deadlock property both hold.
    enum FetchAdmission {
        case normal
        case head
    }

    @MainActor
    private static func acquireFetchSlot(_ admission: FetchAdmission) async {
        if activeFetches < maxConcurrentFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { continuation in
            switch admission {
            case .normal: fetchWaiters.append(continuation)
            case .head: fetchWaiters.insert(continuation, at: 0)
            }
        }
    }

    @MainActor
    private static func releaseFetchSlot() {
        if fetchWaiters.isEmpty {
            activeFetches -= 1
        } else {
            // Hand the slot straight to the next waiter; activeFetches stays constant.
            fetchWaiters.removeFirst().resume()
        }
    }

    /// Synchronous memory-cache lookup. Safe from any context (NSCache locks internally); lets
    /// views seed their first frame without an async hop, avoiding a placeholder flash.
    static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: url as NSURL)
    }

    /// Fetch + validate + decode + cache one URL. Concurrent calls for the same URL share one
    /// download. Cancelling an awaiting caller does NOT cancel the shared work — the image still
    /// lands in the cache for whoever wants it next.
    ///
    /// `admission` only matters when the six-slot gate is saturated (see `FetchAdmission`); a call
    /// that coalesces onto an already-running download inherits that download's admission, since
    /// there is nothing left to queue.
    @MainActor
    static func fetch(_ url: URL, admission: FetchAdmission = .normal) async throws -> UIImage {
        if let hit = cached(url) {
            #if DEBUG
            LaunchTrace.artwork(.memory)  // BUG-26 attribution
            #endif
            return hit
        }
        if let existing = inflight[url] { return try await existing.value }

        let work = Task<UIImage, Error> {
            await acquireFetchSlot(admission)
            defer { releaseFetchSlot() }
            #if DEBUG
            // BUG-26: classify where this load's bytes come from — a healthy relaunch should be
            // dominated by disk (URLCache) hits; all-network on every cold start would confirm
            // the "something invalidates the artwork cache" theory.
            var traceSource: LaunchTrace.ArtworkSource =
                session.configuration.urlCache?.cachedResponse(for: URLRequest(url: url)) != nil
                    ? .disk
                    : .network
            #endif
            let data: Data
            if url.scheme == "data" {
                // Inline `data:image/...;base64,...` avatars (custom pictures imported from
                // other Nuvio clients) decode locally — there's no network response to
                // validate, and routing a multi-megabyte URL string through the disk-backed
                // URLCache would waste space on a payload that's already fully in memory.
                // Base64-decoding a ~MB payload is synchronous, so hop off the main actor
                // (this Task inherits @MainActor from `fetch`) like the decode below does.
                data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                #if DEBUG
                traceSource = .disk  // local bytes, no network involved
                #endif
            } else {
                let (fetchedData, response) = try await session.data(from: url)

                // Reject unsuccessful responses, non-image payloads, and oversized downloads
                // before spending any decode work on them (HI-006).
                if let http = response as? HTTPURLResponse {
                    guard (200...299).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    if let mime = http.mimeType?.lowercased(), !mime.hasPrefix("image/") {
                        throw URLError(.cannotDecodeContentData)
                    }
                }
                data = fetchedData
            }
            guard data.count <= maxDownloadBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }

            // Decode off the main actor, downsampled to at most the panel's own resolution —
            // decoding artwork at source dimensions is what made the old cache balloon.
            let decoded = try await Task.detached(priority: .userInitiated) {
                try downsample(data: data)
            }.value

            let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 4 * 1024 * 1024
            memory.setObject(decoded, forKey: url as NSURL, cost: cost)
            #if DEBUG
            LaunchTrace.artwork(traceSource)  // BUG-26 attribution
            #endif
            return decoded
        }
        inflight[url] = work
        defer { inflight[url] = nil }
        return try await work.value
    }

    /// Fire-and-forget warm-up for a set of URLs (memory + disk). Home calls this the moment the
    /// hero items arrive so carousel paging and the 8s auto-advance never hit a cold cache.
    @MainActor
    static func prefetch(_ urls: [URL]) {
        for url in urls where cached(url) == nil {
            Task { _ = try? await fetch(url) }
        }
    }

    /// ImageIO downsampling: decodes straight to a bounded thumbnail without ever materializing
    /// the full-size bitmap. 1920 px covers a full-screen 1080p-point layer; posters and cards
    /// render far smaller. Absurd source dimensions are rejected before any real decode work.
    nonisolated fileprivate static func downsample(data: Data) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Double,
           let height = props[kCGImagePropertyPixelHeight] as? Double {
            guard width > 0, height > 0, width <= 12_000, height <= 12_000 else {
                throw URLError(.cannotDecodeContentData)
            }
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1920
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Loads and caches a single image URL for one `CachedAsyncImage`, delegating the shared cache,
/// download, and decode machinery to `ArtworkStore`.
@MainActor
private final class CachedImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    private var currentURL: URL?
    private var task: Task<Void, Never>?

    func load(_ url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        task?.cancel()
        failed = false
        image = nil

        guard let url else { return }

        if let cached = ArtworkStore.cached(url) {
            image = cached
            return
        }

        task = Task { [weak self] in
            let fetched = try? await ArtworkStore.fetch(url)
            if Task.isCancelled { return }
            guard let self, self.currentURL == url else { return }
            if let fetched {
                withAnimation(.easeIn(duration: 0.25)) { self.image = fetched }
            } else {
                self.failed = true
            }
        }
    }

    deinit { task?.cancel() }
}

/// Animated shimmer placeholder shown while an image loads.
struct ShimmerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Theme.Palette.surface
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: animate ? geo.size.width : -geo.size.width * 0.6)
                }
            )
            .clipped()
            .onAppear {
                // Reduce Motion: leave the placeholder static instead of an endlessly sweeping
                // gradient — the loading state is still conveyed by the flat surface fill.
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
            // A loading placeholder, never real content — any accessibility label for the
            // artwork itself is applied by the caller (e.g. the poster's title), separately.
            .accessibilityHidden(true)
    }
}
