import CryptoKit
import Foundation
import Network
import SharedCore

// UX-4c SABR follow-up: YouTube's SABR rollout means many videos (recent uploads especially) come
// back from innertube with NO hlsManifestUrl and NO muxed formats beyond the 360p progressive —
// only demuxed adaptiveFormats with direct URLs + initRange/indexRange. AVPlayer can't consume bare
// DASH adaptive streams, but it plays byte-range fMP4 HLS (v7) natively. So when the shared
// extractor surfaces an AVPlayer-decodable demuxed pair (H.264 fMP4 + AAC fMP4, in
// `TrailerPlaybackSource.adaptiveVideo/adaptiveAudio`), this repackages it into a local HLS
// playlist set: fetch the two sidx boxes (a few KB), turn their segment tables into
// EXT-X-BYTERANGE media playlists that point AVPlayer straight at googlevideo, and serve the
// playlists (playlists ONLY — no media bytes are proxied) from a loopback NWListener.
//
// Every failure path falls back to `progressiveUrl` (the pre-existing 360p behavior), so this can
// only ever upgrade quality. Server pattern mirrors RemoteSetupServer/LocalHLSServer; ports 8230+
// so an active remux session (8190+) or setup server (8080+) never collides.

nonisolated final class TrailerLocalHLS: @unchecked Sendable {
    static let shared = TrailerLocalHLS()

    private let listenerQueue = DispatchQueue(label: "media.nuvio.trailer-hls-listener")
    private let connQueue = DispatchQueue(label: "media.nuvio.trailer-hls-conn")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var startWaiters: [(UInt16?) -> Void] = []
    /// token → {master.m3u8, video.m3u8, audio.m3u8}. Playlists are a few KB; the cap only exists
    /// so a marathon browsing session can't grow this forever.
    ///
    /// BUG-46/B3: this store and `TrailerResolutionCache` used to disagree about what a token is
    /// worth. The cache hands out a local URL for up to 3h, while a random per-repack token was
    /// evicted after 64 *repacks* — and because re-resolving a title minted a NEW token instead of
    /// overwriting its old one, browsing a few dozen titles could evict a token whose `.resolved`
    /// entry was still live. The player then got a 404 and the title read as broken until the app
    /// restarted. Two halves of the fix: tokens are now DERIVED from the track pair (re-resolving
    /// the same trailer overwrites its own entry, so the token count is bounded by distinct
    /// trailers, not by repacks), and `maxTokens` matches `TrailerResolutionCache.capacity` so the
    /// two stores evict on the same scale. `hasToken(_:)` lets a cache hit check before playing;
    /// the 404 path below stays as the backstop for googlevideo URL expiry inside the playlists.
    private var playlists: [String: [String: Data]] = [:]
    private var tokenOrder: [String] = []
    private static let maxTokens = 200

    /// token → content identity ("id=<videoId>"), captured at mint time in `repack()` from the
    /// same video URL `token(video:audio:)` hashed. Never derivable FROM the token itself (a
    /// one-way SHA256 digest with nothing to recover), so this is a lookup table, not a parser —
    /// evicted in lockstep with `playlists`/`tokenOrder` so an identity can never outlive the
    /// token it describes. See `contentIdentity(forToken:)`.
    private var contentIdentities: [String: String] = [:]

    private init() {}

    /// Sendable snapshot of a Kotlin `TrailerAdaptiveTrack` (KMP classes aren't Sendable; the
    /// repack pipeline hops queues).
    private struct Track: Sendable {
        let url: String
        let codecs: String
        let bitrate: Int64
        let width: Int
        let height: Int
        let initStart: Int64
        let initEnd: Int64
        let indexStart: Int64
        let indexEnd: Int64

        init(_ track: TrailerAdaptiveTrack) {
            url = track.url
            codecs = track.codecs
            bitrate = track.bitrate
            width = Int(track.width)
            height = Int(track.height)
            initStart = track.initStart
            initEnd = track.initEnd
            indexStart = track.indexStart
            indexEnd = track.indexEnd
        }
    }

    // MARK: - Public API

    /// The best AVPlayer URL for a resolved trailer source: a local byte-range HLS master when the
    /// extractor surfaced a repack-worthy demuxed pair (and the repack builds), else the
    /// progressive/HLS URL exactly as before, else nil. Completion on the main queue.
    func playbackURL(for source: TrailerPlaybackSource, completion: @escaping @Sendable (String?) -> Void) {
        let progressive: String? = (source.progressiveUrl?.isEmpty == false) ? source.progressiveUrl : nil
        // BUG-81: this is the single choke point every trailer surface's playback URL comes out of,
        // so it is where the YouTube video id gets attached to that URL. See
        // `TrailerVideoIdRegistry` for why a side table rather than a threaded parameter.
        let videoId = source.videoId
        guard let video = source.adaptiveVideo, let audio = source.adaptiveAudio else {
            TrailerVideoIdRegistry.register(videoId, forPlaybackURL: progressive)
            DispatchQueue.main.async { completion(progressive) }
            return
        }
        repack(video: Track(video), audio: Track(audio)) { local in
            let url = local ?? progressive
            TrailerVideoIdRegistry.register(videoId, forPlaybackURL: url)
            DispatchQueue.main.async { completion(url) }
        }
    }

    func playbackURL(for source: TrailerPlaybackSource) async -> String? {
        await withCheckedContinuation { continuation in
            playbackURL(for: source) { continuation.resume(returning: $0) }
        }
    }

    /// BUG-46/B3: the token embedded in one of this server's playback URLs, or nil when `urlString`
    /// isn't one (a direct progressive/HLS googlevideo URL — nothing here to check).
    static func token(inPlaybackURL urlString: String) -> String? {
        guard let url = URL(string: urlString), url.host == "127.0.0.1" else { return nil }
        let comps = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.count == 2 else { return nil }
        return comps[0]
    }

    /// `true` while this server can still serve `token`'s playlists. Lets a `TrailerResolutionCache`
    /// hit verify its local URL *before* handing it to AVPlayer, instead of learning about an
    /// eviction from a 404 the user sees as a dead card.
    func hasToken(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return playlists[token] != nil
    }

    /// BUG-81 investigation (Wave F item C follow-up): a stable identity for `token`'s VIDEO
    /// stream, or nil when `token` was never minted (evicted, never seen by this server instance,
    /// or its video URL carried no `id` query item — nothing content-stable to report, same as
    /// `stableIdentity`'s own no-id fallback).
    ///
    /// Deliberately excludes the itag. YouTube's H.264 format ladder for one video (itags like
    /// 133-137/160/298/299) is one continuously-cropped source encoded at different
    /// resolutions/bitrates — never a different picture — and `TrailerExtractionPlatform.apple.kt`
    /// always selects the highest-resolution AVC rung it finds, so a fresh extraction of the SAME
    /// trailer can legitimately land on a different itag than the one a persisted zoom was
    /// measured against. `stableIdentity`'s own `token(video:audio:)` hash treats that as a brand
    /// new stream (by design — see its doc), so on the repack path `TrailerLetterboxProbe` was
    /// never able to VERIFY a persisted zoom against a re-extraction that picked a different rung:
    /// `token=mismatch` on effectively every relaunch, cold re-measure at the parity floor every
    /// time, a persisted zoom never confirmed OR corrected. This identity is the crop-relevant
    /// subset of that hash's input — same video, itag-independent — so `streamIdentity(of:)` in
    /// `TrailerHeroPlayerView.swift` can key the VERIFY comparison on it instead.
    ///
    /// Byte-range offsets and signed-URL expiry were never part of `stableIdentity` either — both
    /// are per-extraction serving plumbing, not picture geometry.
    ///
    /// Crop-geometry risk: sharing identity across itags assumes every AVC rung of one video shares
    /// one crop/letterbox. That holds for YouTube's ladder (one encode pipeline per upload, same
    /// aspect ratio at every rung) but isn't a protocol guarantee. If it were ever violated —
    /// e.g. a rendition family mixing a 4:3 SD source with a 16:9 HD re-master — the practical
    /// exposure is bounded, not silent: `TrailerLetterboxProbe.start()`'s VERIFY branch always
    /// re-measures behind a token match and calls `finish()`, which corrects (re-persists) any
    /// drift over `0.02`. Worst case is one relaunch showing a stale-but-plausible crop for the
    /// ~0.5-1.5s until the interim/final measurement lands, not a permanently wrong one.
    ///
    /// EMPIRICAL CORRECTION (sim soak, 2026-09-04, `TrailerSoakTests.testColdStoreFirstDwellRevealProfile`
    /// harvested against `-debug.trailerSmokeVideoId` — one fixed YouTube video, extracted three
    /// separate times): `itag` stayed `137` on every extraction, but the googlevideo `id=` query
    /// item itself was a DIFFERENT value every time (`o-AJbEeBZ...`, `o-AMk-fCjYnp...`,
    /// `o-APyRTSGf...`, …) — none sharing even a prefix. So this function's itag-only unification
    /// does NOT resolve the `persisted-hit token=mismatch` symptom by itself: `id=` reads as a
    /// per-extraction-request token minted by the CDN, not a stable identifier of the source
    /// video, contrary to `stableIdentity`'s own doc comment (which this function otherwise
    /// mirrors). The itag-sharing this function does provide is still correct and still the right
    /// behavior when itag IS the only thing that changed — it just isn't sufficient on its own.
    /// A real fix needs a video-id-stable identity that doesn't round-trip through the signed
    /// googlevideo URL at all — e.g. the actual YouTube video id (`rNZ0xKaCdus`-shaped, visible in
    /// the shared Kotlin extractor's own `[TrailerExtract] video=…` logs) threaded through
    /// `TrailerAdaptiveTrack`/`TrailerPlaybackSource` (`shared/.../trailer/TrailerPlaybackSource.kt`)
    /// down to this Swift layer, which is outside this type's current inputs.
    ///
    /// SUPERSEDED (2026-09-04): that real fix now exists. `TrailerPlaybackSource.videoId` carries
    /// the YouTube video id from the shared extractor, `TrailerVideoIdRegistry` (below) attaches it
    /// to the playback URL, and `TrailerLetterboxProbe.streamIdentity(of:videoId:)` prefers a
    /// `yt:<videoId>` identity over anything derived from the googlevideo URL. This function stays
    /// as the fallback for a URL with no registered video id (a source that never came from the
    /// YouTube extractor, or a registry entry evicted mid-session) — it is still strictly better
    /// than the raw repack token, just no longer the primary identity.
    static func contentIdentity(forToken token: String) -> String? {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.contentIdentities[token]
    }

    /// Test seam: registers the token/content-identity pair `repack(...)` would produce for this
    /// URL pair, without the sidx network fetch a real repack needs (unit tests can't drive that).
    /// `contentIdentity(forToken:)` coverage needs a real minted entry to look up — this is the
    /// only way to get one outside the live extraction pipeline. Returns the minted token.
    static func registerContentIdentityForTesting(videoURL: String, audioURL: String) -> String {
        let token = Self.token(videoURL: videoURL, audioURL: audioURL)
        shared.lock.lock()
        shared.contentIdentities[token] = Self.contentIdentity(videoURL: videoURL)
        shared.lock.unlock()
        return token
    }

    // MARK: - Repackaging

    private func repack(video: Track, audio: Track,
                        completion: @escaping @Sendable (String?) -> Void) {
        fetchSidx(track: video) { [weak self] videoSidx in
            guard let self else { completion(nil); return }
            guard let videoSidx else {
                NSLog("[TrailerRepack] video sidx fetch/parse FAILED -> progressive fallback")
                completion(nil)
                return
            }
            self.fetchSidx(track: audio) { audioSidx in
                guard let audioSidx else {
                    NSLog("[TrailerRepack] audio sidx fetch/parse FAILED -> progressive fallback")
                    completion(nil)
                    return
                }
                let master = Self.masterPlaylist(video: video, audio: audio)
                let videoMedia = Self.mediaPlaylist(track: video, sidx: videoSidx)
                let audioMedia = Self.mediaPlaylist(track: audio, sidx: audioSidx)
                let token = Self.token(video: video, audio: audio)
                self.store(token: token, contentIdentity: Self.contentIdentity(videoURL: video.url), files: [
                    "master.m3u8": Data(master.utf8),
                    "video.m3u8": Data(videoMedia.utf8),
                    "audio.m3u8": Data(audioMedia.utf8),
                ])
                self.ensureStarted { port in
                    guard let port else {
                        NSLog("[TrailerRepack] loopback bind FAILED -> progressive fallback")
                        completion(nil)
                        return
                    }
                    let url = "http://127.0.0.1:\(port)/\(token)/master.m3u8"
                    NSLog("[TrailerRepack] serving %dx%d avc1+mp4a (%d+%d segments) at %@",
                          video.width, video.height, videoSidx.segments.count, audioSidx.segments.count, url)
                    completion(url)
                }
            }
        }
    }

    /// BUG-46/BUG-55 (beta.12): googlevideo fetches must not ride the app's PERSISTENT cookie
    /// jar. `URLSession.shared` attaches `NSHTTPCookieStorage` cookies, and a YouTube identity
    /// cookie that gets rate-flagged is exactly the state that survives an app restart, dies
    /// with the container (the reporter's uninstall+reinstall "fix"), and comes back the same
    /// evening — the persisted-state profile BUG-46's escalation described. Ephemeral: no cookie
    /// send/store, no disk cache; nothing in this pipeline depends on cookie continuity.
    private static let mediaFetchSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    /// Fetch a track's `indexRange` bytes (the sidx box) and parse the segment table.
    private func fetchSidx(track: Track, completion: @escaping @Sendable (SidxIndex?) -> Void) {
        guard let url = URL(string: track.url) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("bytes=\(track.indexStart)-\(track.indexEnd)", forHTTPHeaderField: "Range")
        Self.mediaFetchSession.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let data, !data.isEmpty else {
                NSLog("[TrailerRepack] sidx http %d (%d bytes)", status, data?.count ?? 0)
                completion(nil)
                return
            }
            completion(Self.parseSidx(data, indexEnd: track.indexEnd))
        }.resume()
    }

    // MARK: - sidx parsing

    struct SidxIndex: Sendable {
        /// (byte size, duration in seconds) per media segment, in timeline order.
        let segments: [(size: Int64, duration: Double)]
        /// Absolute file offset of the first segment's first byte.
        let firstSegmentOffset: Int64
    }

    /// Minimal ISO-BMFF sidx parser: exactly one top-level `sidx` box is expected in the
    /// indexRange slice. Returns nil (→ progressive fallback) on anything surprising, including
    /// hierarchical indexes (reference_type=1), which YouTube doesn't emit for these formats.
    private static func parseSidx(_ data: Data, indexEnd: Int64) -> SidxIndex? {
        let bytes = [UInt8](data)
        guard bytes.count >= 32 else { return nil }
        func u32(_ o: Int) -> UInt32 {
            (UInt32(bytes[o]) << 24) | (UInt32(bytes[o + 1]) << 16) | (UInt32(bytes[o + 2]) << 8) | UInt32(bytes[o + 3])
        }
        func u64(_ o: Int) -> UInt64 { (UInt64(u32(o)) << 32) | UInt64(u32(o + 4)) }

        let boxSize = Int(u32(0))
        guard boxSize >= 32, boxSize <= bytes.count,
              bytes[4] == 0x73, bytes[5] == 0x69, bytes[6] == 0x64, bytes[7] == 0x78 else { // "sidx"
            return nil
        }
        let version = bytes[8]
        let timescale = u32(16)
        guard timescale > 0 else { return nil }
        var offset: Int
        let firstOffset: UInt64
        if version == 0 {
            firstOffset = UInt64(u32(24))
            offset = 28
        } else {
            firstOffset = u64(28)
            offset = 36
        }
        offset += 2 // reserved
        guard offset + 2 <= boxSize else { return nil }
        let refCount = Int((UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1]))
        offset += 2
        guard refCount > 0, offset + refCount * 12 <= boxSize else { return nil }

        var segments: [(size: Int64, duration: Double)] = []
        segments.reserveCapacity(refCount)
        for _ in 0..<refCount {
            let first = u32(offset)
            let durationTicks = u32(offset + 4)
            offset += 12
            if first & 0x8000_0000 != 0 { return nil } // hierarchical index — bail
            segments.append((size: Int64(first & 0x7FFF_FFFF), duration: Double(durationTicks) / Double(timescale)))
        }
        // Segment data starts right after the index box (plus any declared gap).
        return SidxIndex(segments: segments, firstSegmentOffset: indexEnd + 1 + Int64(firstOffset))
    }

    // MARK: - Playlist synthesis

    private static func masterPlaylist(video: Track, audio: Track) -> String {
        let bandwidth = max(Int(video.bitrate + audio.bitrate), 1_000_000)
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
        ]
        var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"\(video.codecs),\(audio.codecs)\",AUDIO=\"aud\""
        if video.width > 0 && video.height > 0 {
            streamInf += ",RESOLUTION=\(video.width)x\(video.height)"
        }
        lines.append(streamInf)
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func mediaPlaylist(track: Track, sidx: SidxIndex) -> String {
        let target = Int((sidx.segments.map(\.duration).max() ?? 1).rounded(.up))
        let initLength = track.initEnd - track.initStart + 1
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(target, 1))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(track.url)\",BYTERANGE=\"\(initLength)@\(track.initStart)\"",
        ]
        var offset = sidx.firstSegmentOffset
        for segment in sidx.segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(offset)")
            lines.append(track.url)
            offset += segment.size
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Playlist store

    /// BUG-46/B3: the token for a track pair, not for a repack. Deriving it from the tracks'
    /// STABLE identity means re-resolving a trailer overwrites its own playlists instead of
    /// minting a second entry that pushes somebody else's out — and it keeps a `.resolved` cache
    /// entry pointing at a token the next repack will simply refresh. Signed googlevideo URLs are
    /// NOT stable identity: every re-extraction re-signs them (fresh `expire`/`sig`/`n` params and
    /// often a different CDN host), so hashing the full URLs minted a new token per extraction and
    /// recreated exactly the eviction-404 churn this exists to prevent (Codex round 8). The stable
    /// part is the stream selection itself — the `id` + `itag` query items — with the full URL
    /// kept only as a fallback for URLs that carry neither.
    private static func token(video: Track, audio: Track) -> String {
        token(videoURL: video.url, audioURL: audio.url)
    }

    /// URL-string form of the derivation above, byte-identical to it (`token(video:audio:)` just
    /// delegates here) — factored out so `registerContentIdentityForTesting(videoURL:audioURL:)`
    /// can mint a real token without constructing a Kotlin `TrailerAdaptiveTrack`.
    private static func token(videoURL: String, audioURL: String) -> String {
        let digest = SHA256.hash(data: Data("\(stableIdentity(videoURL))\n\(stableIdentity(audioURL))".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The picture-geometry-relevant identity for a video URL: the `id` query item alone, itag and
    /// everything else `stableIdentity` keeps dropped. Nil when the URL carries no `id` (mirrors
    /// `stableIdentity`'s own no-id fallback) — nothing content-stable to report, so
    /// `contentIdentity(forToken:)` returns nil and callers fall back to the opaque per-mint token.
    private static func contentIdentity(videoURL: String) -> String? {
        guard let components = URLComponents(string: videoURL) else { return nil }
        guard let id = (components.queryItems ?? []).first(where: { $0.name == "id" })?.value, !id.isEmpty else {
            return nil
        }
        return "id=\(id)"
    }

    private static func stableIdentity(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString) else { return urlString }
        let items = components.queryItems ?? []
        // The CONTENT id is required: an itag alone names a format ladder rung, identical across
        // every video — accepting it without the id would collapse different trailers onto one
        // token (Codex round 11). No id → fall back to the full URL (per-extraction tokens, the
        // pre-B3 behavior, safe just less dedup-friendly).
        guard let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty else {
            return urlString
        }
        let itag = items.first(where: { $0.name == "itag" })?.value
        return "id=\(id)&itag=\(itag ?? "-")"
    }

    private func store(token: String, contentIdentity: String?, files: [String: Data]) {
        lock.lock()
        // A re-store is a refresh of an existing trailer, not a new entry: replace the files and
        // move the token to the back of the eviction line rather than double-listing it.
        if playlists[token] != nil {
            tokenOrder.removeAll { $0 == token }
        }
        playlists[token] = files
        if let contentIdentity {
            contentIdentities[token] = contentIdentity
        } else {
            contentIdentities.removeValue(forKey: token)
        }
        tokenOrder.append(token)
        while tokenOrder.count > Self.maxTokens {
            let evicted = tokenOrder.removeFirst()
            playlists.removeValue(forKey: evicted)
            contentIdentities.removeValue(forKey: evicted)
            if TrailerProbe.enabled {
                NSLog("[TrailerRepack] token evict token=%@ stored=%d max=%d", evicted, tokenOrder.count, Self.maxTokens)
            }
        }
        let stored = tokenOrder.count
        lock.unlock()
        // Phase 0 (BUG-46 candidate #3): a `TrailerResolutionCache` `.resolved` entry can hand out
        // this URL for up to 3h, but `maxTokens` bounds how long the token itself survives — this
        // is the mint side of the "cache says resolved, token already evicted" mismatch that
        // shows up as a 404 in `handle()` below. B3 narrowed that window (stable tokens, matching
        // capacities), so a `token mint` line that keeps reporting the same token for the same
        // title is the fix working, not a repeat.
        if TrailerProbe.enabled {
            NSLog("[TrailerRepack] token mint token=%@ stored=%d max=%d", token, stored, Self.maxTokens)
        }
    }

    // MARK: - Loopback listener (playlists only; media bytes go straight to googlevideo)

    private func ensureStarted(completion: @escaping @Sendable (UInt16?) -> Void) {
        lock.lock()
        if let port {
            lock.unlock()
            completion(port)
            return
        }
        let alreadyStarting = !startWaiters.isEmpty
        startWaiters.append(completion)
        lock.unlock()
        guard !alreadyStarting else { return }
        attemptStart(portOffset: 0)
    }

    private func resolveStart(_ boundPort: UInt16?) {
        lock.lock()
        port = boundPort
        let waiters = startWaiters
        startWaiters = []
        lock.unlock()
        waiters.forEach { $0(boundPort) }
    }

    private func attemptStart(portOffset: UInt16) {
        guard portOffset < 20, let nwPort = NWEndpoint.Port(rawValue: 8230 + portOffset) else {
            resolveStart(nil)
            return
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let candidate: NWListener
        do {
            candidate = try NWListener(using: params)
        } catch {
            attemptStart(portOffset: portOffset + 1)
            return
        }
        lock.lock(); listener = candidate; lock.unlock()

        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.resolveStart(8230 + portOffset)
            case .failed, .cancelled:
                candidate.cancel()
                self.lock.lock()
                let isCurrent = self.listener === candidate
                if isCurrent { self.listener = nil }
                let hadPort = self.port != nil
                if isCurrent { self.port = nil }
                self.lock.unlock()
                // A bind failure during startup tries the next port; a later listener death just
                // clears state so the next repack re-binds.
                if isCurrent && !hadPort { self.attemptStart(portOffset: portOffset + 1) }
            default:
                break
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.connQueue)
            self.receive(connection: connection, buffer: Data())
        }
        candidate.start(queue: listenerQueue)
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > 32 * 1024 { connection.cancel(); return }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.receive(connection: connection, buffer: buffer) }
                return
            }
            guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
                self.send(status: "400 Bad Request", body: Data(), on: connection)
                return
            }
            self.handle(head: head, on: connection)
        }
    }

    private func handle(head: String, on connection: NWConnection) {
        let requestLine = head.components(separatedBy: "\r\n").first?.split(separator: " ").map(String.init) ?? []
        let method = requestLine.first?.uppercased() ?? ""
        guard requestLine.count >= 2, method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", body: Data(), on: connection)
            return
        }
        let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestLine[1]
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        lock.lock()
        let body = comps.count == 2 ? playlists[comps[0]]?[comps[1]] : nil
        let stored = tokenOrder.count
        lock.unlock()
        guard let body else {
            // Phase 0 (BUG-46 candidate #3 — the direct probe): a `TrailerResolutionCache`
            // `.resolved` entry can point at a token this loopback server no longer has (evicted
            // by `maxTokens`, or never minted). AVPlayer sees this 404, the item fails, and the
            // existing `onFailure` fail-soft (static backdrop / collapsed card) covers it.
            if TrailerProbe.enabled {
                let token = comps.first ?? "?"
                NSLog("[TrailerRepack] 404 token=%@ stored=%d", token, stored)
            }
            send(status: "404 Not Found", body: Data(), on: connection)
            return
        }
        send(status: "200 OK", body: body, on: connection, isHead: method == "HEAD")
    }

    private func send(status: String, body: Data, on connection: NWConnection, isHead: Bool = false) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/vnd.apple.mpegurl\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if !isHead { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// BUG-81: playback URL → YouTube video id, so `TrailerLetterboxProbe` can key a persisted zoom on
/// the one identifier that survives a re-extraction of the same trailer.
///
/// A side table rather than a parameter threaded through every surface, because the playback URL is
/// all some call sites have left: `TrailerResolutionCache` memoizes a *URL string* per title, so a
/// second dwell on a title inside one launch replays that URL with no `TrailerPlaybackSource`
/// anywhere in scope. Registering at `TrailerLocalHLS.playbackURL(for:)` — the single choke point
/// every surface's URL comes out of — covers the Detail hero, the Trailers row clips, the inline
/// catalog cards and the Home hero alike, cache hits included. Surfaces that DO still hold the
/// source pass the id explicitly instead (`TrailerHeroPlayer.videoId`), which wins over this table.
///
/// Process-local and bounded; nothing is persisted. A cold launch starts empty and re-extraction
/// re-registers, which is exactly the flow the persisted zoom cache is verified against.
enum TrailerVideoIdRegistry {
    /// Matches `TrailerLocalHLS.maxTokens` / `TrailerResolutionCache.capacity`: one entry per
    /// distinct trailer URL, evicted on the same scale as the stores it shadows.
    private static let capacity = 200

    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids: [String: String] = [:]
    nonisolated(unsafe) private static var order: [String] = []

    /// No-op for a nil/empty URL or video id — an unregistered URL simply falls back to the
    /// URL-derived identity, which is what shipped before.
    static func register(_ videoId: String?, forPlaybackURL url: String?) {
        guard let url, !url.isEmpty, let videoId, !videoId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if ids.updateValue(videoId, forKey: url) == nil {
            order.append(url)
            while order.count > capacity {
                ids.removeValue(forKey: order.removeFirst())
            }
        }
    }

    static func videoId(forPlaybackURL url: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return ids[url]
    }

    /// Test seam: unit tests share one process, so a registry left populated by one case would leak
    /// into the next.
    static func removeAllForTesting() {
        lock.lock()
        defer { lock.unlock() }
        ids.removeAll()
        order.removeAll()
    }
}
