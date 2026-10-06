import Combine
import Foundation
import SharedCore

/// FEAT-34/FEAT-42: the app's TMDB title-logo URL cache. Per-item (id + type), per-settings-scope
/// cache of a title's resolved TMDB title-logo URL, including a resolved-but-empty result. Clients:
/// `SagaCard` (the description page's franchise/saga row, the original FEAT-34 use — a
/// `LazyHStack` recycling a card's view identity while scrolling must never re-issue the same
/// lookup) and `HomeView`'s `HeroArtResolver`/`HomeHeroFocusModel` (FEAT-42 — the Home hero/focus
/// panel's own title-logo resolution, added without widening `MetaPreview` or the shared Kotlin
/// enrichment payload; see `HeroArtResolver.logoPlan` and `HomeHeroFocusModel.requestLogoIfNeeded`
/// in `HomeView.swift`). Scoped as a process-wide singleton (mirrors `ArtworkStore`'s own
/// in-memory cache) rather than per-view state, since the same title can be looked up from more
/// than one surface (a saga-row part that is ALSO a Home catalog item, say).
///
/// Moved out of `SagaCard.swift` (where it lived as `SagaLogoStore`, FEAT-34) and renamed for
/// FEAT-42 now that a second, unrelated view owns a client of its own — no typealias shim, every
/// call site was updated in the same change.
///
/// Every mounted `SagaCard` holds `@ObservedObject private var logoStore = TitleLogoStore.shared`,
/// so ANY `results` mutation (any card's lookup resolving) republishes to every saga card on
/// screen, not just the one that changed — `@Published` on a dictionary has no per-key
/// granularity. Each card's own re-render is cheap (`logoURL(for:)` is a dictionary lookup keyed
/// off its own item + the current scope), so this is a non-issue at saga-row scale. `HomeView`'s
/// Home-path consumers (`HeroArtResolver`, `HomeHeroFocusModel`) deliberately do NOT hold this as
/// an `@ObservedObject` — see the FEAT-42 rule in `HomeView.swift`'s `HeroArtResolver.present`
/// doc: they read it synchronously (`logoURL(for:)`/`isLookupPending(for:)`) or await one specific
/// key (`awaitLogoURL(for:)`) instead of subscribing the whole Home view hierarchy to every
/// unrelated saga/row lookup resolving.
@MainActor
final class TitleLogoStore: ObservableObject {
    static let shared = TitleLogoStore()

    private init() {}

    /// `.pending(requestId:)` from the moment a lookup starts until its callback lands. The
    /// request id lets a late completion recognize it has been superseded — by a fresh
    /// `lookupIfNeeded` call for the same key, or by the whole cache being dropped in
    /// `evictIfAtCapacity()` — before it can latch a stale `.pending` in place forever (see
    /// `shouldCommit`). `.resolved(nil)` is a completed lookup that found no logo (no match) —
    /// remembered exactly like a real URL so it is never retried on every scroll. A lookup that
    /// FAILED (network error, timeout, HTTP 429, decode failure, ...) is NOT latched as
    /// `.resolved(nil)` — see `LookupOutcome.failed` — so it is not covered by this case either; a
    /// failed key instead has no entry at all here, gated from immediate retry by `lastFailureAt`
    /// (see `shouldSkipRetry`). A lookup skipped because settings gate it off is also NEVER written
    /// here at all (see `lookupIfNeeded`), so it is not covered by this case. Internal, not
    /// private, so `TitleLogoStoreTests` can exercise `shouldCommit` with `@testable import`.
    enum LookupState: Equatable {
        case pending(requestId: UInt64)
        case resolved(String?)
    }

    /// FEAT-42: the pure decision behind `awaitLogoURL(for:)` — whether a waiter for a given
    /// cache entry should be answered immediately (`.answer`) or parked until the lookup resolves
    /// (`.park`). Factored out, `nonisolated static`, with no store/dictionary access, so
    /// `TitleLogoStoreTests` can cover every case directly.
    enum LogoWaitDecision: Equatable {
        case answer(String?)
        case park
    }

    @Published private var results: [String: LookupState] = [:]

    /// FEAT-42: parked `awaitLogoURL(for:)` callers, keyed the same way `results` is. Resumed from
    /// one of three places, all reachable only while the entry was `.pending`: the matching entry
    /// resolves (answered with the URL, or nil for "resolved but found nothing"), it is removed
    /// because the scope moved on before the lookup finished, or it is removed because the lookup
    /// itself failed (2026-09-12, `LookupOutcome.failed`) — the last two both answer nil rather
    /// than leaving the waiter to hang forever, the anti-hang invariant `waitDecision` encodes. A
    /// `.pending` entry dropped by `evictIfAtCapacity()` never happens — that function only ever
    /// drops `.resolved` entries — so eviction alone never needs to resume a waiter.
    private var waiters: [String: [CheckedContinuation<String?, Never>]] = [:]

    /// Monotonically increasing id handed to each lookup attempt so its completion can tell, via
    /// `shouldCommit`, whether it is still the one live attempt for its key rather than a
    /// superseded or evicted one.
    private var nextRequestId: UInt64 = 0

    private func makeRequestId() -> UInt64 {
        nextRequestId += 1
        return nextRequestId
    }

    /// Bumped every time `results` is dropped wholesale by `evictIfAtCapacity()`. Not itself
    /// consulted by `shouldCommit` — a `.pending` entry wiped by a reset already fails the
    /// `requestId` match on its own — but kept as the store's own record of how many times a
    /// reset has happened.
    private var generation: UInt64 = 0

    /// Bounds `results` across a long session — many collections/rows browsed, or repeated
    /// settings changes each adding a fresh generation of keys for the same items, would
    /// otherwise grow it without limit. FEAT-42 note: this cap is now shared between saga-row
    /// lookups and Home row/hero lookups — see the risk note on that task for when to raise it.
    /// Past this many entries the whole cache is dropped; a lookup already pending under a
    /// dropped key just gets requested again (`TmdbMetadataService` has no dedup problem with a
    /// redundant in-flight request completing twice — the second write just replaces the first
    /// with the same value).
    private static let maxEntries = 200

    /// Eviction used before a new `.pending` write in `lookupIfNeeded`, the single place that
    /// keeps `results` from growing past `maxEntries`. Codex r3 (Finding P2): only drops
    /// `.resolved` entries — a `.pending` one is a lookup already in flight for a card that is
    /// (or was, moments ago) mounted, and wiping it here would strand it forever, since
    /// `lookupIfNeeded`'s own `results[key] == nil` guard treats a missing entry as "never
    /// looked up" while the mounted card's `.task(id:)` keys only on type|id and so never re-runs
    /// to ask again. Dropping only `.resolved` entries is safe: a card whose logo was already
    /// resolved just re-fetches it once, cheaply, next time it is looked up.
    private func evictIfAtCapacity() {
        guard results.count >= Self.maxEntries else { return }
        results = results.filter { _, state in
            if case .pending = state { return true }
            return false
        }
        generation += 1
    }

    /// FEAT-42 (2026-09-12, P3): last-failure timestamp per key, keyed the same way `results` is.
    /// A `.failed` lookup (see `LookupOutcome.failed`) removes its `results` entry so the key looks
    /// "never looked up" again — without this, a persistently failing lookup (offline addon,
    /// TMDB rate limit, ...) would be re-issued on every single focus/scroll that re-mounts the
    /// card, hammering the same failing request. `lookupOne` consults this via `shouldSkipRetry`
    /// before starting a new attempt; a successful resolve clears the key's entry here so a later
    /// genuine failure gets its own fresh cooldown window.
    private var lastFailureAt: [String: Date] = [:]

    /// Minimum time a key must wait after a failed lookup before `lookupOne` will retry it.
    private static let retryCooldown: TimeInterval = 30

    /// Pure decision behind the cooldown: true when `lastFailure` is set and less than `cooldown`
    /// seconds before `now` (no recorded failure never skips). `nonisolated static`, no
    /// store/dictionary access, so `TitleLogoStoreTests` can cover every case directly.
    nonisolated static func shouldSkipRetry(lastFailure: Date?, now: Date, cooldown: TimeInterval) -> Bool {
        guard let lastFailure else { return false }
        return now.timeIntervalSince(lastFailure) < cooldown
    }

    /// Pure decision for whether a completed lookup's result should be written into `results`:
    /// true only when `entry` is the exact `.pending` placeholder this request itself installed.
    /// False for a different (newer) request's `.pending`, an already-`.resolved` entry, or a
    /// missing entry — the key was superseded by a newer lookup, or its `.pending` was wiped by a
    /// capacity reset (`evictIfAtCapacity()`, which also bumps `generation`). Internal + testable
    /// on its own, with no store/dictionary access, so `TitleLogoStoreTests` can cover every case
    /// directly.
    nonisolated static func shouldCommit(entry: LookupState?, requestId: UInt64) -> Bool {
        entry == .pending(requestId: requestId)
    }

    /// FEAT-42: pure decision behind `awaitLogoURL(for:)` — see `LogoWaitDecision`'s doc comment.
    /// `.pending` parks the caller (nothing to answer yet); `.resolved(x)` answers with `x`
    /// (which may itself be nil, "resolved but found nothing" — a real, final answer, not a
    /// reason to keep waiting); a missing entry (nil) answers nil rather than parking forever —
    /// nothing will ever resolve a key nobody asked `lookupIfNeeded` to look up. This is the
    /// anti-hang invariant: every branch either answers immediately or parks behind a `.pending`
    /// that WILL resolve (via `lookupIfNeeded`'s completion) or be removed (the off-scope path),
    /// both of which resume every parked waiter — never a branch that parks with nothing left to
    /// wake it.
    nonisolated static func waitDecision(entry: LookupState?) -> LogoWaitDecision {
        switch entry {
        case .pending:
            return .park
        case .resolved(let url):
            return .answer(url)
        case nil:
            return .answer(nil)
        }
    }

    /// True when `logo` (an item's own, already-known logo string) is worth a dedicated lookup —
    /// nil or blank. Takes the raw field rather than a whole `MetaPreview` so both `SagaCardArt`
    /// (which reads `item.logo` its own way for `needsLogoLookup`) and `HomeView` (which checks
    /// this ahead of `logoPlan`/`requestLogoIfNeeded`, where an item may or may not be a
    /// `MetaPreview` depending on the call site) can share one predicate.
    nonisolated static func isLookupCandidate(_ logo: String?) -> Bool {
        logo?.isEmpty ?? true
    }

    /// FEAT-42 crash fix (2026-09-12): pure decision for what `lookupOne`'s completion should do
    /// with a `fetchPreviewEnrichmentChecked` result, once the `shouldCommit`/scope guards have
    /// already passed. `.failed` means the lookup itself failed (a Ktor network error, a timeout,
    /// HTTP 429, a JSON decode failure, ...) — the caller must NOT latch `.resolved(nil)` for
    /// that, since that would permanently remember "no logo" for what was really a transient
    /// failure; `.resolvedNone`/`.resolved(url)` are the two real "looked, and here's what we
    /// found" answers, matching today's `.resolved(nil)`/`.resolved(url)` writes. `nonisolated
    /// static`, no store/dictionary access, so `TitleLogoStoreTests` can cover every branch
    /// directly.
    enum LookupOutcome: Equatable {
        case resolved(String)
        case resolvedNone
        case failed
    }

    nonisolated static func completionOutcome(enrichment: TmdbPreviewEnrichment?, error: Error?) -> LookupOutcome {
        guard error == nil else { return .failed }
        let logo = enrichment?.logo
        guard let logo, !logo.isEmpty else { return .resolvedNone }
        return .resolved(logo)
    }

    nonisolated static func key(for item: MetaPreview) -> String { "\(item.type)|\(item.id)" }

    /// The settings that change what a logo lookup returns or whether it even runs — folded into
    /// the cache key so a Metadata Language change, or the artwork/TMDB gate flipping, can never
    /// serve a stale-language logo or a permanently-latched nil from a session where the gate was
    /// off.
    private static func scopeToken(_ settings: TmdbSettings) -> String {
        "\(settings.language)|\(settings.enabled)|\(settings.hasApiKey)|\(settings.useArtwork)"
    }

    private static func scopedKey(for item: MetaPreview, scope: String) -> String {
        "\(key(for: item))|\(scope)"
    }

    /// The resolved logo URL for `item` under the CURRENT settings snapshot, or nil while
    /// unresolved / if resolution found nothing / if this item has no entry under the current
    /// scope yet (e.g. settings changed since the last lookup — see `lookupIfNeeded`).
    func logoURL(for item: MetaPreview) -> String? {
        let scope = Self.scopeToken(TmdbSettingsRepository.shared.snapshot())
        if case .resolved(let url) = results[Self.scopedKey(for: item, scope: scope)] { return url }
        return nil
    }

    /// FEAT-42: true while a lookup for `item` under the CURRENT settings snapshot is in flight —
    /// `HeroArtResolver.logoPlan` reads this to decide between `.pending` (wait inside the
    /// existing 400ms budget) and `.none` (nothing to wait for).
    func isLookupPending(for item: MetaPreview) -> Bool {
        let scope = Self.scopeToken(TmdbSettingsRepository.shared.snapshot())
        if case .pending = results[Self.scopedKey(for: item, scope: scope)] { return true }
        return false
    }

    /// Starts (at most once per key, where the key includes the current settings scope) the TMDB
    /// preview-enrichment lookup for each item's logo. A second call for the same item under the
    /// same scope, while one is pending or after one has resolved, is a no-op; a call under a NEW
    /// scope (language changed, or the artwork/TMDB gate flipped) always gets its own fresh
    /// attempt. FEAT-42: takes a batch so a row's first-focus prefetch can kick every candidate in
    /// one call (`HomeView.reportRowFocus`) instead of the caller looping; `SagaCard` calls this
    /// with its own single item wrapped in a one-element array.
    func lookupIfNeeded(_ items: [MetaPreview]) {
        for item in items {
            lookupOne(item)
        }
    }

    private func lookupOne(_ item: MetaPreview) {
        let settings = TmdbSettingsRepository.shared.snapshot()
        let scope = Self.scopeToken(settings)
        let key = Self.scopedKey(for: item, scope: scope)
        guard results[key] == nil else { return }

        // FEAT-42 (2026-09-12, P3): a key that failed recently is left with no `results` entry
        // (see the `.failed` branch below), which would otherwise look identical to "never looked
        // up" and get re-issued on every focus/scroll that re-mounts the card. Skip re-issuing
        // until the cooldown elapses; `awaitLogoURL` still answers nil for a key with no entry.
        guard !Self.shouldSkipRetry(lastFailure: lastFailureAt[key], now: Date(), cooldown: Self.retryCooldown) else {
            return
        }

        guard settings.enabled, settings.hasApiKey, settings.useArtwork else {
            // Deliberately NOT cached: writing `.resolved(nil)` here would latch a permanent "no
            // logo" for this scope even though no lookup was ever attempted. Leaving no entry
            // means the very next call under this same scope (gate still off) still short-circuits
            // here cheaply — it's the scope changing, not this branch, that ever triggers a retry.
            return
        }

        evictIfAtCapacity()
        let requestId = makeRequestId()
        results[key] = .pending(requestId: requestId)

        // suspend fun → Swift completion; result may arrive off the main thread (same convention
        // as `HomeView.enrichIfNeeded`), so hop back before touching `@Published` state.
        //
        // FEAT-42 crash fix (2026-09-12): calls `fetchPreviewEnrichmentChecked`, NOT
        // `fetchPreviewEnrichment`, and reads the completion's `error`. A suspend function
        // exported to Swift without `@Throws` treats ANY non-cancellation exception thrown
        // inside it as unhandled and ABORTS THE PROCESS — that is exactly what happened here
        // (SIGABRT via `Kotlin_ObjCExport_ExceptionAsNSError` → `terminateWithUnhandledException`
        // under `-debug.heroLogoStoreOnly`, one lookup among a store-driven batch throwing a
        // network/timeout/decode error). `fetchPreviewEnrichmentChecked` is `@Throws(Throwable::
        // class)`, so Kotlin/Native hands that same failure to this completion as an `NSError`
        // instead. See `completionOutcome` for what each outcome means.
        TmdbMetadataService.shared.fetchPreviewEnrichmentChecked(
            type: item.type, id: item.id, settings: settings
        ) { [weak self] enrichment, error in
            DispatchQueue.main.async {
                guard let self else { return }
                // Not the live attempt for this key anymore — either a newer `lookupIfNeeded` call
                // for the same key took over (its `.pending(requestId:)` won't match ours), or a
                // capacity reset wiped the entry entirely. Either way, writing now would be wrong:
                // in the superseded case it would clobber the newer attempt's own eventual result;
                // in the wiped case there is nothing to correct — the key simply has no entry until
                // something looks it up again. Drop this completion.
                guard Self.shouldCommit(entry: self.results[key], requestId: requestId) else { return }
                // The live attempt, but for a scope the user has since moved away from. Leaving the
                // `.pending` entry in place here would permanently wedge scope A: `lookupIfNeeded`'s
                // `results[key] == nil` guard above would reject every future lookup for this exact
                // key, so returning to scope A later would never retry and the logo would never
                // appear (Finding 3). Remove the stale entry instead, so scope A starts fresh next
                // time it is looked up; don't write the (now off-scope) result anywhere. FEAT-42:
                // any waiter parked on this key must not hang forever just because the scope moved
                // on — resume with nil, the same answer `waitDecision` gives for a missing entry.
                guard Self.scopeToken(TmdbSettingsRepository.shared.snapshot()) == scope else {
                    self.results.removeValue(forKey: key)
                    self.resumeWaiters(for: key, with: nil)
                    return
                }
                switch Self.completionOutcome(enrichment: enrichment, error: error) {
                case .failed:
                    // A failed or cancelled lookup — do NOT latch `.resolved(nil)`, that would
                    // permanently remember "no logo" for what was really a transient failure.
                    // Drop the `.pending` entry instead so the next `lookupIfNeeded` for this key
                    // retries from scratch, same as the off-scope branch above.
                    self.results.removeValue(forKey: key)
                    self.resumeWaiters(for: key, with: nil)
                    let now = Date()
                    // Codex r6 P3: expiry only PERMITS a retry, it never removed the entry, so a
                    // long browse of failing titles (or an abandoned language scope) grew this map
                    // without bound. Prune everything past the cooldown on each insert — the
                    // pruned keys read as "no failure" to `shouldSkipRetry`, which is exactly what
                    // an expired cooldown means.
                    self.lastFailureAt = self.lastFailureAt.filter { now.timeIntervalSince($0.value) < Self.retryCooldown }
                    self.lastFailureAt[key] = now
                    // FEAT-42 (2026-09-12): the bare error description is usually just
                    // "Kotlin bridge error" — the ORIGINAL throwable (its class, e.g.
                    // `SocketTimeoutException`/`JsonDecodingException`) rides along on the bridged
                    // `NSError` under `userInfo["KotlinException"]`/`["KotlinExceptionOrigin"]`; log
                    // both so a future SIGABRT-shaped report can be pinned to a Kotlin cause without
                    // reproducing under a debugger.
                    let nsError = error as NSError?
                    NSLog(
                        "[TitleLogoStore] lookup failed key=%@ error=%@ kotlinException=%@ kotlinExceptionOrigin=%@",
                        key,
                        String(describing: error),
                        String(describing: nsError?.userInfo["KotlinException"]),
                        String(describing: nsError?.userInfo["KotlinExceptionOrigin"])
                    )
                case .resolved(let url):
                    // Codex r3 (Finding P2): no `evictIfAtCapacity()` call here — this write
                    // replaces an existing `.pending` key with `.resolved`, so it can never itself
                    // grow `results` past the cap; there was previously a "defensive" eviction
                    // call on this path, but `evictIfAtCapacity()` used to drop the whole cache
                    // wholesale, which could wipe out the very entry this line just wrote (plus
                    // every other in-flight `.pending` lookup) with no mounted card ever
                    // re-requesting it — see that function's own doc for why eviction now only
                    // touches `.resolved` entries.
                    self.results[key] = .resolved(url)
                    self.resumeWaiters(for: key, with: url)
                    self.lastFailureAt.removeValue(forKey: key)
                    // FEAT-42: warm `ArtworkStore` the moment a real URL resolves, so the NEXT
                    // time this item is presented (a saga card scrolled back into view, a Home
                    // row item refocused) the bitmap is already cached — `HeroArtResolver.present`
                    // never waits out a fetch it could have started here.
                    if let parsedURL = URL(string: url) {
                        ArtworkStore.prefetch([parsedURL])
                    }
                case .resolvedNone:
                    self.results[key] = .resolved(nil)
                    self.resumeWaiters(for: key, with: nil)
                    self.lastFailureAt.removeValue(forKey: key)
                }
            }
        }
    }

    /// FEAT-42: awaits the resolved logo URL for `item` — answers immediately if a `.resolved`
    /// entry (or no entry at all) already exists (`waitDecision`'s `.answer` branches), otherwise
    /// parks behind the in-flight lookup's eventual write. Callers are expected to have already
    /// confirmed a lookup IS in flight (`isLookupPending(for:)`, read by
    /// `HeroArtResolver.logoPlan` before choosing `.pending`) — calling this for a key with no
    /// entry at all is well-defined (answers nil at once) but starts no lookup of its own; pair it
    /// with `lookupIfNeeded` if one is wanted.
    func awaitLogoURL(for item: MetaPreview) async -> String? {
        let scope = Self.scopeToken(TmdbSettingsRepository.shared.snapshot())
        let key = Self.scopedKey(for: item, scope: scope)
        switch Self.waitDecision(entry: results[key]) {
        case .answer(let url):
            return url
        case .park:
            return await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }
    }

    private func resumeWaiters(for key: String, with url: String?) {
        guard let parked = waiters.removeValue(forKey: key) else { return }
        for continuation in parked { continuation.resume(returning: url) }
    }
}
