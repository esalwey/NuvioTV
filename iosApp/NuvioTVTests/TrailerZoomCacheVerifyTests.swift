import XCTest
@testable import NuvioTV

/// BUG-81 (Wave F item C): unit coverage for the two VERIFY-mode escape hatches `TrailerZoomCache`
/// gained — `remove(for:)` (item 1, the `final-clamped` escape) and `noteVerifyMiss(for:)` (item 2,
/// the `insufficient` escape) — plus `TrailerLetterboxProbe.streamIdentity(of:)`'s BUG-81 item 3
/// fix (a direct URL's identity keys on the `id` query item alone, dropping the host/path/itag that
/// used to make every googlevideo re-extraction read as a brand-new stream).
///
/// Every cache test uses `TrailerZoomCache.makeIsolated(suiteName:)` — a throwaway `UserDefaults`
/// suite, wiped on creation — so these never touch `.standard` or interact with each other.
final class TrailerZoomCacheVerifyTests: XCTestCase {

    /// The video-id registry is process-wide, and `streamIdentity(of:)` consults it whenever the
    /// caller passes no explicit id — so a stale entry from one case would silently rewrite the
    /// identity another case asserts on. Wipe it around every test.
    override func setUp() {
        super.setUp()
        TrailerVideoIdRegistry.removeAllForTesting()
    }

    override func tearDown() {
        TrailerVideoIdRegistry.removeAllForTesting()
        super.tearDown()
    }

    private func makeCache(_ name: String = #function) -> TrailerZoomCache {
        TrailerZoomCache.makeIsolated(suiteName: "TrailerZoomCacheVerifyTests.\(name).\(UUID().uuidString)")
    }

    // MARK: - remove(for:)

    func testRemovePersists() {
        let cache = makeCache()
        cache.store(1.2, for: "title:1", token: "repack:aaa")
        XCTAssertNotNil(cache.entry(for: "title:1"))

        cache.remove(for: "title:1")
        XCTAssertNil(cache.entry(for: "title:1"), "remove(for:) should drop the in-memory entry immediately")

        // Persistence check: `entry(for:)` alone can't distinguish "removed" from "never loaded
        // from disk yet" (both read nil from a fresh `values` dictionary) — `count` forces
        // `loadIfNeeded()`, which is exactly what proves the removal survived a reload.
        XCTAssertEqual(cache.count, 0, "remove(for:) must persist — a reload should not resurrect the entry")
    }

    func testRemoveOfMissingKeyIsANoOp() {
        let cache = makeCache()
        cache.store(1.1, for: "title:kept", token: "repack:bbb")
        cache.remove(for: "title:never-stored")
        XCTAssertNotNil(cache.entry(for: "title:kept"), "removing an absent key must not disturb other entries")
    }

    // MARK: - noteVerifyMiss(for:)

    func testThreeVerifyMissesEvict() {
        let cache = makeCache()
        cache.store(1.3, for: "title:2", token: "repack:ccc")

        XCTAssertEqual(cache.noteVerifyMiss(for: "title:2"), 1)
        XCTAssertNotNil(cache.entry(for: "title:2"), "one miss must not evict")

        XCTAssertEqual(cache.noteVerifyMiss(for: "title:2"), 2)
        XCTAssertNotNil(cache.entry(for: "title:2"), "two misses must not evict")

        XCTAssertEqual(cache.noteVerifyMiss(for: "title:2"), 3)
        XCTAssertNil(cache.entry(for: "title:2"), "a third consecutive miss must evict the entry")
    }

    func testNoteVerifyMissOnMissingKeyIsANoOp() {
        let cache = makeCache()
        XCTAssertEqual(cache.noteVerifyMiss(for: "title:never-stored"), 0)
        XCTAssertNil(cache.entry(for: "title:never-stored"))
    }

    func testConfirmResetsMissCount() {
        let cache = makeCache()
        cache.store(1.25, for: "title:3", token: "repack:ddd")

        XCTAssertEqual(cache.noteVerifyMiss(for: "title:3"), 1)
        XCTAssertEqual(cache.noteVerifyMiss(for: "title:3"), 2)

        // The `verify-confirmed`/`verify-corrected` call shape: re-store with `verifyMisses: 0`.
        cache.store(1.25, for: "title:3", token: "repack:ddd", verifyMisses: 0)

        // A fresh miss after the reset should read back as 1, not 3 (proving the reset actually
        // took, not merely that two more misses would have evicted anyway).
        XCTAssertEqual(cache.noteVerifyMiss(for: "title:3"), 1)
        XCTAssertNotNil(cache.entry(for: "title:3"))
    }

    // MARK: - streamIdentity(of:)

    func testDirectURLIdentityIgnoresHostItagExpireAndSig() {
        let a = "https://rr1---sn-abc123.googlevideo.com/videoplayback?id=deadbeef1234&itag=137&expire=1000&signature=aaa&mime=video%2Fmp4"
        let b = "https://rr5---sn-xyz789.googlevideo.com/videoplayback?id=deadbeef1234&itag=248&expire=9999999&signature=zzz&mime=video%2Fmp4"
        XCTAssertEqual(
            TrailerLetterboxProbe.streamIdentity(of: a),
            TrailerLetterboxProbe.streamIdentity(of: b),
            "two re-extractions of the SAME video must key identically regardless of host/itag/expire/sig"
        )
    }

    func testDirectURLIdentityDiffersAcrossId() {
        let a = "https://rr1---sn-abc123.googlevideo.com/videoplayback?id=videoOne&itag=137&expire=1000&signature=aaa"
        let b = "https://rr1---sn-abc123.googlevideo.com/videoplayback?id=videoTwo&itag=137&expire=1000&signature=aaa"
        XCTAssertNotEqual(
            TrailerLetterboxProbe.streamIdentity(of: a),
            TrailerLetterboxProbe.streamIdentity(of: b),
            "two different videos must never collapse onto one identity"
        )
    }

    func testDirectURLIdentityHasContentPrefix() {
        let url = "https://r1---sn-foo.googlevideo.com/videoplayback?id=abc123&itag=137&expire=1000&signature=aaa"
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: url), "direct:id=abc123")
    }

    func testURLWithNoIdFallsBackToWholeURL() {
        let url = "https://example.com/trailer.mp4?itag=137"
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: url), "url:\(url)")
    }

    // MARK: - streamIdentity(of:) on the REPACK path (BUG-81 investigation)

    /// `TrailerLocalHLS.registerContentIdentityForTesting` mints a token exactly as a real
    /// `repack()` would (same `token(video:audio:)` derivation, keyed on the video/audio URLs)
    /// without the sidx network fetch a real repack needs, and records its content identity —
    /// giving these tests a real entry to look up via `contentIdentity(forToken:)`.
    private func loopbackURL(token: String) -> String { "http://127.0.0.1:8230/\(token)/master.m3u8" }

    func testRepackIdentityIsEqualAcrossItagsOfTheSameVideo() {
        let audioURL = "https://rr1---sn-abc.googlevideo.com/videoplayback?id=aud&itag=140"
        let tokenLowItag = TrailerLocalHLS.registerContentIdentityForTesting(
            videoURL: "https://rr1---sn-abc.googlevideo.com/videoplayback?id=sharedVideo&itag=135",
            audioURL: audioURL
        )
        let tokenHighItag = TrailerLocalHLS.registerContentIdentityForTesting(
            videoURL: "https://rr5---sn-xyz.googlevideo.com/videoplayback?id=sharedVideo&itag=137",
            audioURL: audioURL
        )
        // Different itags mint DIFFERENT tokens (the eviction/dedup key stays itag-sensitive)...
        XCTAssertNotEqual(tokenLowItag, tokenHighItag)
        // ...but the same video must read as the same content identity, which is the whole point:
        // a re-extraction that lands on a different AVC rung must still VERIFY against a zoom
        // persisted under a previous rung instead of reading as a brand-new stream.
        XCTAssertEqual(
            TrailerLetterboxProbe.streamIdentity(of: loopbackURL(token: tokenLowItag)),
            TrailerLetterboxProbe.streamIdentity(of: loopbackURL(token: tokenHighItag)),
            "two itags of the SAME video must key identically on the repack path"
        )
    }

    func testRepackIdentityDiffersAcrossVideos() {
        let tokenOne = TrailerLocalHLS.registerContentIdentityForTesting(
            videoURL: "https://rr1---sn-abc.googlevideo.com/videoplayback?id=videoOne&itag=137",
            audioURL: "https://rr1---sn-abc.googlevideo.com/videoplayback?id=videoOne&itag=140"
        )
        let tokenTwo = TrailerLocalHLS.registerContentIdentityForTesting(
            videoURL: "https://rr1---sn-abc.googlevideo.com/videoplayback?id=videoTwo&itag=137",
            audioURL: "https://rr1---sn-abc.googlevideo.com/videoplayback?id=videoTwo&itag=140"
        )
        XCTAssertNotEqual(
            TrailerLetterboxProbe.streamIdentity(of: loopbackURL(token: tokenOne)),
            TrailerLetterboxProbe.streamIdentity(of: loopbackURL(token: tokenTwo)),
            "two different videos must never collapse onto one repack identity"
        )
    }

    func testRepackIdentityFallsBackToTokenWhenUnresolved() {
        // A syntactically valid loopback token this server never minted (or already evicted) —
        // `contentIdentity(forToken:)` returns nil, and `streamIdentity(of:)` must fall back to
        // the literal token rather than producing a nil/empty identity.
        let unknownToken = "0123456789abcdef"
        XCTAssertNil(TrailerLocalHLS.contentIdentity(forToken: unknownToken))
        XCTAssertEqual(
            TrailerLetterboxProbe.streamIdentity(of: loopbackURL(token: unknownToken)),
            "repack:\(unknownToken)"
        )
    }

    // MARK: - streamIdentity(of:videoId:) — the YouTube video id (BUG-81 round three)

    /// The whole point of the fix: the googlevideo `id=` query item, the CDN host and the itag all
    /// rotate between extractions of ONE video (sim soak 2026-09-04), so an identity keyed on any
    /// of them reads as a brand-new stream every play. The video id does not.
    func testVideoIdIdentityIsEqualAcrossRotatedURLs() {
        let first = "https://rr1---sn-abc123.googlevideo.com/videoplayback?id=o-AJbEeBZaaa&itag=137&expire=1000&signature=aaa"
        let second = "https://rr5---sn-xyz789.googlevideo.com/videoplayback?id=o-APyRTSGzzz&itag=135&expire=9999999&signature=zzz"
        XCTAssertNotEqual(
            TrailerLetterboxProbe.streamIdentity(of: first),
            TrailerLetterboxProbe.streamIdentity(of: second),
            "precondition: without a video id these two URLs are two different streams"
        )
        XCTAssertEqual(
            TrailerLetterboxProbe.streamIdentity(of: first, videoId: "rNZ0xKaCdus"),
            TrailerLetterboxProbe.streamIdentity(of: second, videoId: "rNZ0xKaCdus"),
            "two extractions of the same video must key identically however the signed URL rotated"
        )
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: first, videoId: "rNZ0xKaCdus"), "yt:rNZ0xKaCdus")
    }

    /// A trailer can play through the loopback repack on one launch and straight off googlevideo on
    /// the next (the repack is only attempted when the demuxed pair beats the muxed options), so
    /// the identity must not encode which transport served it either.
    func testVideoIdIdentityIsEqualAcrossTransports() {
        let repackToken = TrailerLocalHLS.registerContentIdentityForTesting(
            videoURL: "https://rr1---sn-abc.googlevideo.com/videoplayback?id=o-AJbEeBZaaa&itag=137",
            audioURL: "https://rr1---sn-abc.googlevideo.com/videoplayback?id=o-AJbEeBZaaa&itag=140"
        )
        XCTAssertEqual(
            TrailerLetterboxProbe.streamIdentity(of: loopbackURL(token: repackToken), videoId: "rNZ0xKaCdus"),
            TrailerLetterboxProbe.streamIdentity(
                of: "https://rr9---sn-qqq.googlevideo.com/videoplayback?id=o-APyRTSGzzz&itag=22",
                videoId: "rNZ0xKaCdus"
            ),
            "the repack and direct paths of one video must produce one identity"
        )
    }

    func testVideoIdIdentityDiffersAcrossVideos() {
        let url = "https://rr1---sn-abc.googlevideo.com/videoplayback?id=o-AJbEeBZaaa&itag=137"
        XCTAssertNotEqual(
            TrailerLetterboxProbe.streamIdentity(of: url, videoId: "rNZ0xKaCdus"),
            TrailerLetterboxProbe.streamIdentity(of: url, videoId: "dQw4w9WgXcQ"),
            "two different videos must never collapse onto one identity, same URL or not"
        )
    }

    /// Nil (a non-YouTube source, or an evicted registry entry) must land on exactly the identities
    /// that shipped before this change — the direct/repack/url keys the cases above cover.
    func testNilVideoIdFallsBackToTheURLDerivedKeys() {
        let direct = "https://r1---sn-foo.googlevideo.com/videoplayback?id=abc123&itag=137&expire=1000"
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: direct, videoId: nil), "direct:id=abc123")

        let noId = "https://example.com/trailer.mp4?itag=137"
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: noId, videoId: nil), "url:\(noId)")

        let token = TrailerLocalHLS.registerContentIdentityForTesting(
            videoURL: "https://rr1---sn-abc.googlevideo.com/videoplayback?id=repackVideo&itag=137",
            audioURL: "https://rr1---sn-abc.googlevideo.com/videoplayback?id=repackVideo&itag=140"
        )
        XCTAssertEqual(
            TrailerLetterboxProbe.streamIdentity(of: loopbackURL(token: token), videoId: nil),
            "repack:id=repackVideo"
        )
    }

    /// An empty string is not an identity — it must degrade to the fallback, not to `yt:`.
    func testEmptyVideoIdFallsBack() {
        let direct = "https://r1---sn-foo.googlevideo.com/videoplayback?id=abc123&itag=137"
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: direct, videoId: ""), "direct:id=abc123")
    }

    // MARK: - TrailerVideoIdRegistry

    /// The surfaces that replay a `TrailerResolutionCache` URL have no `TrailerPlaybackSource` left
    /// in scope, so they pass no video id — the registry the resolver populated is what gives them
    /// the same identity anyway.
    func testRegistryIdentityMatchesAnExplicitVideoId() {
        let url = "https://rr1---sn-abc.googlevideo.com/videoplayback?id=o-AJbEeBZaaa&itag=137"
        TrailerVideoIdRegistry.register("rNZ0xKaCdus", forPlaybackURL: url)
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: url), "yt:rNZ0xKaCdus")
        XCTAssertEqual(
            TrailerLetterboxProbe.streamIdentity(of: url),
            TrailerLetterboxProbe.streamIdentity(of: url, videoId: "rNZ0xKaCdus"),
            "a registry hit and an explicit id must produce the same identity"
        )
    }

    func testExplicitVideoIdWinsOverTheRegistry() {
        let url = "https://rr1---sn-abc.googlevideo.com/videoplayback?id=o-AJbEeBZaaa&itag=137"
        TrailerVideoIdRegistry.register("staleVideoId", forPlaybackURL: url)
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: url, videoId: "rNZ0xKaCdus"), "yt:rNZ0xKaCdus")
    }

    func testRegistryIgnoresEmptyAndMissingInputs() {
        let url = "https://r1---sn-foo.googlevideo.com/videoplayback?id=abc123&itag=137"
        TrailerVideoIdRegistry.register(nil, forPlaybackURL: url)
        TrailerVideoIdRegistry.register("", forPlaybackURL: url)
        TrailerVideoIdRegistry.register("rNZ0xKaCdus", forPlaybackURL: nil)
        TrailerVideoIdRegistry.register("rNZ0xKaCdus", forPlaybackURL: "")
        XCTAssertNil(TrailerVideoIdRegistry.videoId(forPlaybackURL: url))
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: url), "direct:id=abc123",
                       "an unregistered URL must keep the pre-BUG-81 identity")
    }

    func testRegistryDoesNotLeakAcrossURLs() {
        let registered = "https://rr1---sn-abc.googlevideo.com/videoplayback?id=one&itag=137"
        let other = "https://rr1---sn-abc.googlevideo.com/videoplayback?id=two&itag=137"
        TrailerVideoIdRegistry.register("rNZ0xKaCdus", forPlaybackURL: registered)
        XCTAssertEqual(TrailerLetterboxProbe.streamIdentity(of: other), "direct:id=two")
    }

    // MARK: - BUG-94 (beta.18): the full surface must never touch TrailerZoomCache

    /// `TrailerLetterboxProbe.start()`/`finish()` hardcode `TrailerZoomCache.shared` — there is no
    /// seam to inject `makeCache()`'s isolated instance into a real probe run, and driving `start()`
    /// end to end needs a live `AVPlayer`/`AVPlayerItemVideoOutput` decoding real frames, which is
    /// outside what an XCTest can stand up (see the file's own header on why every case here goes
    /// through `TrailerLocalHLS`/`TrailerVideoIdRegistry` seams instead of a live probe). This test
    /// therefore exercises the two things that jointly make "the full surface can never write the
    /// cache" true — `TrailerSurfaceZoomPolicy.decide(surface: "full", …)` answering
    /// `persist == false` regardless of the cache's current contents, and `TrailerZoomCache` itself
    /// only ever mutating on an explicit `store`/`remove`/`noteVerifyMiss` call — rather than driving
    /// `start()` itself. Said plainly: this proves the cache is inert to the *decision*, not that a
    /// live full-screen play never calls `store()` (that is `start()`'s own early return in
    /// `TrailerHeroPlayerView.swift`, unit-tested indirectly via `TrailerZoomProbeTests`'
    /// `fullSurfaceNeverMeasures`/`fullSurfaceAlwaysPlaysAtOne*`).
    func testFullSurfaceRunLeavesTheCacheByteIdentical() {
        let cache = makeCache()
        let key = "movie:tt0000000"
        cache.store(1.343, for: key, token: "yt:rNZ0xKaCdus", verifyMisses: 1)
        guard let seeded = cache.entry(for: key) else {
            XCTFail("seed must be readable back before simulating a run against it")
            return
        }

        // A real `start()` decides the full surface's policy from `cached: nil` (it never reads
        // the cache at all — see `TrailerHeroPlayerView.swift`'s `start()`), but passing the
        // ACTUAL seeded entry here is the stronger check: it proves `persist == false` even when a
        // real, matching entry exists to tempt a future refactor into consulting it.
        let policy = TrailerSurfaceZoomPolicy.decide(surface: "full", cached: seeded)
        XCTAssertFalse(policy.persist, "a full-screen play must never be allowed to persist")

        // Simulate exactly what `start()`/`finish()` do with that answer: nothing. No `store`, no
        // `remove`, no `noteVerifyMiss` call happens on this path — so the entry must read back
        // byte-identical, field for field, to what was seeded.
        guard let after = cache.entry(for: key) else {
            XCTFail("a policy decision alone must never evict or mutate the entry")
            return
        }
        XCTAssertEqual(after.zoom, seeded.zoom)
        XCTAssertEqual(after.token, seeded.token)
        XCTAssertEqual(after.at, seeded.at)
        XCTAssertEqual(after.verifyMisses, seeded.verifyMisses)
        XCTAssertEqual(cache.count, 1, "no entry should have been added or evicted")
    }
}
