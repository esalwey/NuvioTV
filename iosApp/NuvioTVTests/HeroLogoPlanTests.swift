import XCTest
@testable import NuvioTV

/// FEAT-42: unit tests for
/// `HeroArtResolver.logoPlan(addonLogo:id:isFolder:storeURL:storePending:allowMetahub:)` — the pure
/// priority decision behind the Home hero/focus panel's title-logo resolution. No view host, no
/// `TitleLogoStore`, no network: every row of the priority table (own logo → folder stops →
/// `TitleLogoStore`'s resolved URL → a synchronous metahub guess for IMDb ids → a `TitleLogoStore`
/// lookup already in flight → nothing) is driven directly through the function's parameters. See
/// `logoPlan`'s own doc comment in `HomeView.swift` for the full rationale behind the ordering
/// asserted here.
///
/// `allowMetahub` defaults to `true` and every case above omits it. The two `allowMetahub: false`
/// cases at the bottom cover `present`'s `debug.heroLogoStoreOnly` knob path — step 4 (metahub) is
/// skipped entirely and the plan falls straight to step 5/6.
final class HeroLogoPlanTests: XCTestCase {

    private let metahubURL = URL(string: "https://images.metahub.space/logo/medium/tt1234567/img")!
    private let storeURLString = "https://image.tmdb.org/t/p/w500/store-logo.png"
    private let addonURLString = "https://example.com/addon-logo.png"

    // MARK: - 1. Own logo wins outright

    func testOwnAddonLogoWinsOverEverythingElse() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: addonURLString, id: "tt1234567", isFolder: false,
            storeURL: storeURLString, storePending: true
        )
        XCTAssertEqual(plan, .url(URL(string: addonURLString)!, .addon))
    }

    // MARK: - 2. Blank is ignored, not a broken URL

    func testBlankAddonLogoIsIgnoredAndFallsThrough() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: "", id: "some-non-imdb-id", isFolder: false,
            storeURL: nil, storePending: false
        )
        XCTAssertEqual(plan, .none, "a blank string is not a candidate — must fall through, not park or crash")
    }

    // MARK: - 3. A string that fails URL(string:) also falls through

    func testUnparseableAddonLogoFallsThrough() {
        // Newer Foundation percent-encodes spaces and even a NUL on the way in (`URL(string: "a b")`
        // and `"x/\u{0}"` both parse on the tvOS 26 runtime); an unclosed IPv6 bracket in the host
        // is one of the few shapes the RFC 3986 parser still rejects outright.
        let unparseable = "http://[::1"
        XCTAssertNil(URL(string: unparseable), "test premise: this string must fail to parse")
        let plan = HeroArtResolver.logoPlan(
            addonLogo: unparseable, id: "tt1234567", isFolder: false,
            storeURL: nil, storePending: false
        )
        XCTAssertEqual(plan, .url(metahubURL, .metahub),
                       "an unparseable own-logo string must fall through to the next candidate, not stop resolution")
    }

    // MARK: - 4. A folder never looks up, even with a store URL sitting right there

    func testFolderNeverLooksUpEvenWithAResolvedStoreURL() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: nil, id: "nuvio-folder://collection/1", isFolder: true,
            storeURL: storeURLString, storePending: false
        )
        XCTAssertEqual(plan, .none, "a folder has no sensible TMDB id — it must stop here, not reach the store")
    }

    // MARK: - 11. But a folder's OWN logo still wins — the own-logo check runs before the folder gate

    func testFolderWithItsOwnLogoStillUsesIt() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: addonURLString, id: "nuvio-folder://collection/1", isFolder: true,
            storeURL: nil, storePending: false
        )
        XCTAssertEqual(plan, .url(URL(string: addonURLString)!, .addon),
                       "folderHeroPreview already sets the folder's own logo from titleLogoUrl — step 1 must win before the folder short-circuit")
    }

    // MARK: - 5. Store beats metahub

    func testResolvedStoreURLBeatsTheMetahubGuess() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: nil, id: "tt1234567", isFolder: false,
            storeURL: storeURLString, storePending: false
        )
        XCTAssertEqual(plan, .url(URL(string: storeURLString)!, .tmdb),
                       "a confirmed TMDB hit must win over a synthesized guess, even for an IMDb id")
    }

    // MARK: - 6/7. Metahub for plain and season/episode-suffixed IMDb ids

    func testMetahubForAPlainImdbId() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: nil, id: "tt1234567", isFolder: false,
            storeURL: nil, storePending: false
        )
        XCTAssertEqual(plan, .url(metahubURL, .metahub))
    }

    func testMetahubForASeasonEpisodeSuffixedImdbId() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: nil, id: "tt1234567:1:1", isFolder: false,
            storeURL: nil, storePending: false
        )
        XCTAssertEqual(plan, .url(metahubURL, .metahub),
                       "the imdb id is the first ':'-separated component — season/episode suffixes must not change the guess")
    }

    // MARK: - 8. Metahub survives a pending store lookup

    func testMetahubWinsEvenWhileAStoreLookupIsPending() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: nil, id: "tt1234567", isFolder: false,
            storeURL: nil, storePending: true
        )
        XCTAssertEqual(plan, .url(metahubURL, .metahub),
                       "the synchronous guess must not wait behind an in-flight lookup for an IMDb item")
    }

    // MARK: - 9. Pending is reached only for a non-IMDb id with no faster candidate

    func testPendingOnlyForANonImdbIdWithAnInFlightLookup() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: nil, id: "some-non-imdb-id", isFolder: false,
            storeURL: nil, storePending: true
        )
        XCTAssertEqual(plan, .pending)
    }

    // MARK: - 10. TMDB off (no store URL, nothing pending) resolves to none

    func testNoCandidateAndNoPendingLookupResolvesToNone() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: nil, id: "some-non-imdb-id", isFolder: false,
            storeURL: nil, storePending: false
        )
        XCTAssertEqual(plan, .none,
                       "this is also the shape a TMDB-disabled session presents in — TitleLogoStore never writes .pending with the gate off")
    }

    // MARK: - 12/13. `allowMetahub: false` (the `debug.heroLogoStoreOnly` knob path)

    func testAllowMetahubFalseWithNoStoreResolvesToNone() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: nil, id: "tt1234567", isFolder: false,
            storeURL: nil, storePending: false, allowMetahub: false
        )
        XCTAssertEqual(plan, .none,
                       "an IMDb id would normally hit the synchronous metahub guess (step 4) — with allowMetahub false there is nothing left to fall through to but .none")
    }

    func testAllowMetahubFalseWithPendingStoreResolvesToPending() {
        let plan = HeroArtResolver.logoPlan(
            addonLogo: nil, id: "tt1234567", isFolder: false,
            storeURL: nil, storePending: true, allowMetahub: false
        )
        XCTAssertEqual(plan, .pending,
                       "with the metahub guess disallowed, an IMDb id with a lookup in flight must fall through to .pending instead of the synchronous guess winning first")
    }
}
