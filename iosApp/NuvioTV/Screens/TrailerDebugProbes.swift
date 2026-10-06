import Foundation
import AVFoundation

// MARK: - Trailer pipeline probe (BUG-46 leak investigation / UX-9 zoom measurement prerequisite)

/// Runtime knob shared by every trailer-pipeline probe, following the exact house pattern of
/// `HomeGeometryProbe` (`BrowseComponents.swift:59-61`):
///
///     defaults write com.nuvio.media.NuvioTV debug.trailerProbe -bool YES
///
/// One knob covers both investigations (BUG-46's live-pipeline leak, UX-9's letterbox zoom);
/// greppable NSLog prefixes distinguish streams — `[TrailerPipeline]` for the live-pipeline
/// counts, failure classification, and cache/coordinator logging this file and its call sites in
/// `TrailerHeroPlayerView.swift`/`InlineTrailerCard.swift` add, joining the existing
/// `[TrailerQuality]`/`[TrailerRepack]`/`[TrailerExtract]` streams (`TrailerHeroPlayerView.swift`,
/// `TrailerLocalHLS.swift`, the Kotlin extractor) untouched by this pass.
///
/// Read ONCE at launch: a disabled probe costs a single Bool for the whole session, because every
/// call site below is a plain `if TrailerProbe.enabled` guard, not a modifier that's conditionally
/// attached.
///
/// Deliberately NOT `#if DEBUG`, matching `HomeGeometryProbe`'s precedent: testers run release
/// sideloads, there is no automated input path to the physical Apple TV, and the console (`log
/// show`) is the only diagnostic that comes back from a device pass.
enum TrailerProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.trailerProbe")

    /// `debug.trailerSmokeVideoId` — forces every trailer onto one videoId for deterministic
    /// `[TrailerRepack]`/`[TrailerZoom]` logs. BUG-59 (beta.13): read once, logged once, and the
    /// call sites honor it only when `enabled` is also true (a stray persisted value used to be
    /// able to hijack every trailer on a release sideload).
    nonisolated static let smokeVideoId: String? = {
        let value = UserDefaults.standard.string(forKey: "debug.trailerSmokeVideoId")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        NSLog("[TrailerPipeline] smokeVideoId present=%@ honored=%@", value, enabled ? "YES" : "NO (debug.trailerProbe off)")
        return value
    }()

    /// `debug.trailerForceNoTrailer` (P-1d) — makes every title report "no trailer", so the
    /// never-morph-on-speculation fix (a focused poster with nothing to play must never bloom
    /// into a landscape tile, even for ~1s) is testable on sim and device without hunting for a
    /// fixture whose TMDB listing happens to be empty. Read once, logged once — same pairing rule
    /// as `smokeVideoId` above: honored ONLY when `enabled` is also true, so a stray persisted
    /// value can't silently kill every trailer on a release sideload. The gating is baked into
    /// this property (it reads `false` whenever `enabled` is off) rather than left for call sites
    /// to re-check, since every read of this knob is an OR'd boolean condition, not a value with
    /// its own "present but not honored" log line to make.
    nonisolated static let forceNoTrailer: Bool = {
        let raw = UserDefaults.standard.bool(forKey: "debug.trailerForceNoTrailer")
        guard raw else { return false }
        NSLog("[TrailerPipeline] forceNoTrailer present=YES honored=%@", enabled ? "YES" : "NO (debug.trailerProbe off)")
        return enabled
    }()

    /// `scheme://host` only — the log lines that carry a playback URL (attach/teardown) must
    /// never leak a full googlevideo URL (query strings carry auth tokens) into `log show` output
    /// that a tester might paste into a bug report.
    static func redactedHost(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "?" }
        return "\(url.scheme ?? "?")://\(host)"
    }
}

/// BUG-55: the two inline-trailer gates (`inline_trailers_enabled` + tvOS Auto-Play Video
/// Previews) both default OFF, and a fresh sideload container silently resets the first — a
/// session where trailers "just don't play" needs its gate state in the log. Deliberately NOT
/// behind `TrailerProbe.enabled`, unlike everything else in this file: it emits only when the
/// combined state *changes* (≤ a couple of lines per session), and it is precisely the line that
/// must be present in a log pull nobody thought to arm the probe knob for.
@MainActor
enum InlineTrailerGateProbe {
    private static var lastReported: (enabled: Bool, autoplay: Bool)?

    static func report(enabled: Bool, autoplay: Bool) {
        // BUG-59: touching the lazy static logs "smokeVideoId present=… honored=…" once per session
        // whether or not the probe knob is on — the one line that names a stray persisted knob.
        _ = TrailerProbe.smokeVideoId
        guard lastReported?.enabled != enabled || lastReported?.autoplay != autoplay else { return }
        lastReported = (enabled, autoplay)
        NSLog("[TrailerPipeline] gates inlineTrailersEnabled=%@ systemAutoplay=%@",
              enabled ? "YES" : "NO", autoplay ? "YES" : "NO")
    }
}

/// One entry in the failure ring: cause tag + timestamp. Phase 0 only records these — nothing
/// consumes the ring yet; it exists so a later phase's error-storm breaker (≥3 failures inside
/// 60s) has data to read without re-plumbing anything.
struct TrailerFailureRecord {
    let cause: String
    let at: Date
}

/// Process-wide counters for the trailer pipeline. `attaches`/`teardowns` count
/// `TrailerHeroPlayer.Coordinator.attach`/`teardown()` calls (plus the `FullScreenTrailerSurface`
/// twin, sharing this same singleton so full-screen plays don't read as a leak in the inline/hero
/// numbers); `liveViews` is ground truth from `TrailerPlayerUIView.init`/`deinit`, independent of
/// any attach/teardown bookkeeping; `livePlayers` mirrors attach/teardown so a gap against
/// `liveViews` is visible without cross-referencing two log lines by hand.
///
/// **The leak signal:** `liveViews`/`livePlayers` climbing while browsing — instead of resting at
/// 0 or oscillating 0↔1 — IS the leak, independent of any hypothesis about why.
///
/// NSLock-guarded, matching the house pattern elsewhere in this pipeline (`TrailerLocalHLS`'s own
/// `lock`, `LaunchTrace`'s counters) rather than `OSAllocatedUnfairLock`: `attach()`/`teardown()`
/// fire from the main actor, but `TrailerPlayerUIView.deinit` can run on whatever thread drops the
/// last reference, so this can't assume a single isolation domain.
final class TrailerPipelineCounters: @unchecked Sendable {
    static let shared = TrailerPipelineCounters()

    private let lock = NSLock()
    private var _attaches = 0
    private var _teardowns = 0
    private var _liveViews = 0
    private var _livePlayers = 0
    private var _failures = 0
    private var _failureRing: [TrailerFailureRecord] = []
    private static let ringCapacity = 10

    private init() {}

    struct Snapshot {
        let attaches: Int
        let teardowns: Int
        let liveViews: Int
        let livePlayers: Int
        let failures: Int
    }

    @discardableResult
    func attach() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        _attaches += 1
        _livePlayers += 1
        return snapshotLocked()
    }

    @discardableResult
    func teardown() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        _teardowns += 1
        _livePlayers = max(0, _livePlayers - 1)
        return snapshotLocked()
    }

    @discardableResult
    func viewCreated() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        _liveViews += 1
        return snapshotLocked()
    }

    @discardableResult
    func viewDestroyed() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        _liveViews = max(0, _liveViews - 1)
        return snapshotLocked()
    }

    @discardableResult
    func failure(cause: String) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        _failures += 1
        _failureRing.append(TrailerFailureRecord(cause: cause, at: Date()))
        if _failureRing.count > Self.ringCapacity { _failureRing.removeFirst() }
        return snapshotLocked()
    }

    /// Last ≤10 failure causes, oldest first. Unused beyond being populated in Phase 0 — a later
    /// phase's storm-breaker reads this.
    func recentFailures() -> [TrailerFailureRecord] {
        lock.lock(); defer { lock.unlock() }
        return _failureRing
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    private func snapshotLocked() -> Snapshot {
        Snapshot(attaches: _attaches, teardowns: _teardowns, liveViews: _liveViews, livePlayers: _livePlayers, failures: _failures)
    }
}

// MARK: - Failure classification

/// Classified reason a trailer failed to play — mirrors the causes `AVPlayerItem`/its
/// notifications can actually report, so a `[TrailerPipeline] fail` line reads as a diagnosis
/// instead of a generic "it broke". Observation-only in Phase 0: nothing branches on this yet
/// (that's Phase 2/B2's negative-cache scoping) — it exists purely to log.
enum TrailerFailureCause {
    case badURL
    case itemFailed(NSError?)
    case failedToPlayToEnd(NSError?)
    case watchdogTimeout

    /// Short tag for the log line's `cause=` field and the failure-ring entries.
    var tag: String {
        switch self {
        case .badURL: return "badURL"
        case .itemFailed: return "itemFailed"
        case .failedToPlayToEnd: return "failedToPlayToEnd"
        case .watchdogTimeout: return "watchdogTimeout"
        }
    }

    private var underlyingError: NSError? {
        switch self {
        case .badURL, .watchdogTimeout: return nil
        case let .itemFailed(error), let .failedToPlayToEnd(error): return error
        }
    }

    /// `domain=... code=... http=... category=...` for the `[TrailerPipeline] fail` log line.
    ///
    /// `httpStatus`, when the caller has it from `AVPlayerItem.errorLog()`'s last event's
    /// `errorStatusCode` (the channel that actually reports a `TrailerLocalHLS` evicted-token
    /// 404 — HLS playback errors don't reliably carry an HTTP status on the `NSError` itself the
    /// way some progressive-download errors do), wins over anything read off the NSError.
    func logSuffix(httpStatus: Int?) -> String {
        let error = underlyingError
        let domain = error?.domain ?? "-"
        let code = error.map { String($0.code) } ?? "-"
        let http = httpStatus.map(String.init) ?? "-"
        return "domain=\(domain) code=\(code) http=\(http) category=\(category(httpStatus: httpStatus))"
    }

    /// Coarse bucket the Phase 0 decision gate reads off: HTTP 404/403 (a `TrailerLocalHLS`
    /// evicted-token 404, or a googlevideo URL expiry), decoder/resource exhaustion (the tvOS
    /// decoder cap — `AVFoundationErrorDomain` -11819 "media services were reset", -11839
    /// "decoder resources unavailable", -11800 generic w/ underlying OSStatus), network
    /// (`NSURLErrorDomain`), or unclassified.
    private func category(httpStatus: Int?) -> String {
        if let httpStatus, httpStatus == 404 || httpStatus == 403 { return "http\(httpStatus)" }
        switch self {
        case .badURL: return "badURL"
        case .watchdogTimeout: return "watchdogTimeout"
        case .itemFailed, .failedToPlayToEnd:
            guard let error = underlyingError else { return "other" }
            if error.domain == AVFoundationErrorDomain, [-11819, -11839, -11800].contains(error.code) {
                return "decoderResource"
            }
            if error.domain == NSURLErrorDomain { return "network" }
            return "other"
        }
    }
}
