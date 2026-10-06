import Combine
import Foundation
import SharedCore

/// Resolves and observes playable streams for a title via the shared `StreamsRepository`.
///
/// `load(type:videoId:...)` kicks off resolution across installed streaming addons; `uiState`
/// (`StateFlow<StreamsUiState>`) emits `groups` of `StreamItem`s as each addon responds.
///
/// A stream is surfaced when it either carries a direct HTTP(S) URL, or is a debrid candidate
/// (torrent/`clientResolve` result from an installed addon) while in-app debrid resolution is
/// enabled — those resolve to a direct link at click time in `StreamPickerView` (mobile parity:
/// `StreamsScreen.kt` / `App.kt` click paths). Also observes the shared badge + debrid settings
/// so the picker can render badge packs, file-size chips, placement, addon logos and the
/// "Instant" cached suffix exactly like mobile's `StreamCard`.
///
/// Empty state: `emptyReason` also covers the case where the shared repository found streams
/// but the local playability filter above dropped every one of them (torrent-only results with
/// debrid resolution off) — a different, actionable message from the shared "no streams found
/// at all" reasons, with `emptyReasonHint` pointing at the fix.
@MainActor
final class StreamsViewModel: ObservableObject {
    /// One playable, addon-grouped section for the picker UI.
    struct Group: Identifiable {
        let id: String           // addonId
        let addonName: String
        let streams: [StreamItem]
        /// Mirrors the shared `AddonStreamGroup.isLoading` — this addon hasn't finished
        /// responding yet (more streams may still arrive). Drives the per-group header spinner.
        let isLoading: Bool
        /// STAB-07: "2 × 4K · 5 × 1080p" for the group header; nil when no stream names a resolution.
        let qualitySummary: String?
    }

    /// STAB-04: an addon whose stream fetch failed (HTTP error, timeout, bad payload). Shown as a
    /// dimmed row with Retry instead of vanishing from the list.
    struct FailedGroup: Identifiable {
        let id: String           // addonId
        let addonName: String
        /// "Torrentio: unavailable (HTTP 429)".
        let message: String
        /// A Retry for this addon is in flight (the row keeps its place and shows a spinner).
        let isRetrying: Bool
    }

    /// STAB-07: the row pinned above the groups. Fixed once chosen, so it never swaps under focus.
    struct BestMatch {
        let groupId: String
        let stream: StreamItem
        /// True when it is the source this title/episode was last played from.
        let isLastUsed: Bool
        /// STREAM-INSIGHT: chosen by the shared recommender for the viewer's preferences (the
        /// "Recommended" capsule), not by the plain quality fallback ("Best Match").
        var isRecommended: Bool = false
    }

    /// STAB-04: how long one addon may take to answer before its row reports a timeout.
    static let addonFetchTimeoutMillis: Int64 = 15_000

    @Published private(set) var groups: [Group] = []
    /// STAB-04: failed addons, in install order, rendered after the playable groups.
    @Published private(set) var failedGroups: [FailedGroup] = []
    /// STAB-07: nil until every addon has answered (or the last-used source turns up).
    @Published private(set) var bestMatch: BestMatch?
    /// F10: the first addon group in install order that has playable streams — auto-expanded once.
    /// Nil while an earlier addon in install order is still loading (it may still produce streams).
    @Published private(set) var autoExpandGroupId: String?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var emptyReason: String?
    /// Secondary guidance line for `emptyReason` — where to go fix it (e.g. which Settings
    /// section). Nil for the plain "nothing found" reasons, which have nothing actionable to add.
    @Published private(set) var emptyReasonHint: String?
    /// Focus key of the first stream row; the picker moves initial focus here when rows arrive.
    @Published private(set) var firstRowKey: String?
    /// Shared badge settings (imported packs, file-size toggle, placement, addon logo).
    @Published private(set) var badgeSettings: StreamBadgeSettingsUiState?
    /// Whether in-app debrid can resolve torrent results (drives filtering + "Instant" suffix).
    @Published private(set) var debridResolveEnabled = false
    /// Mobile parity (`StreamsScreen.kt:229`): append "- <Provider> Instant" to cached rows
    /// only when debrid resolution is on and no custom stream-name template is active.
    @Published private(set) var instantSuffixEnabled = false
    /// Non-nil when the active resolver's stored credential has failed auth (401/403) on a
    /// recent provider call — the BUG-21 failure mode where "Connected" was a lie. Rendered as
    /// a warning banner above the stream list; clears itself on the next successful call or
    /// when the user reconnects (the shared health object is the source of truth).
    @Published private(set) var credentialWarning: String?
    /// STREAM-INSIGHT: what each row shows (quality line, language chips, reasons), keyed by
    /// `streamKey(_:)`. Rows look themselves up with `info(for:)`.
    @Published private(set) var rowInfos: [String: StreamRowInfo] = [:]
    /// STREAM-INSIGHT: `streamKey` of the recommended stream ("Recommended" capsule in its group).
    /// Chosen once every addon has answered and then kept, like the Best Match row.
    @Published private(set) var topPickKey: String?
    /// STREAM-INSIGHT: the viewer's ranking preferences (nil until the shared repository emits).
    @Published private(set) var rankingPreferences: StreamRankingPreferences?

    private var watcher: FlowWatcher?
    private var badgeWatcher: FlowWatcher?
    private var debridWatcher: FlowWatcher?
    private var healthWatcher: FlowWatcher?
    private var rankingWatcher: FlowWatcher?
    /// STREAM-INSIGHT: parsed insights by `streamKey` (a stream is parsed once per list).
    private var insightCache: [String: StreamInsight] = [:]
    /// STREAM-INSIGHT: the title's original language ("Original" preference, VO matching).
    private var originalLanguage: String?
    /// STREAM-INSIGHT: groups the picker has expanded. Their row order is frozen (rows keep their
    /// place under focus when a debrid cache check re-scores them); collapsed groups re-sort.
    private var expandedGroupIds: Set<String> = []
    /// STREAM-INSIGHT: the displayed order of each group, as `streamKey`s.
    private var frozenOrder: [String: [String]] = [:]
    /// Latest auth-failed provider ids from `DebridCredentialHealth`, kept to re-derive the
    /// warning when the active resolver changes (and vice versa).
    private var authFailedProviderIds: Set<String> = []
    private var activeResolverProviderId: String?
    /// Last raw state, kept so a debrid-settings flip re-filters without a reload.
    private var lastState: StreamsUiState?
    private let type: String
    /// STAB-02: the id the watch-progress record is keyed under (`parent:season:episode` for an
    /// episode). Used for the last-used-source lookup only.
    private var videoId: String
    /// STAB-02: the id the stream addons are asked with — the episode's own `MetaVideo.id` (kitsu
    /// and other anime catalogs don't follow `parent:season:episode`). Equal to `videoId` for
    /// movies and IMDb series.
    private var streamVideoId: String
    private let parentMetaId: String?
    private var season: KotlinInt?
    private var episode: KotlinInt?
    /// STAB-04: addon ids with a Retry in flight (their failed row stays put with a spinner).
    private var retryingAddonIds: Set<String> = []
    /// STAB-03: watchers were dropped while the player was on top, but the shared list was kept.
    private var isDetached = false

    init(type: String, videoId: String, streamVideoId: String? = nil, parentMetaId: String? = nil,
         season: Int? = nil, episode: Int? = nil) {
        self.type = type
        self.videoId = videoId
        self.streamVideoId = streamVideoId ?? videoId
        self.parentMetaId = parentMetaId
        self.season = season.map { KotlinInt(int: Int32($0)) }
        self.episode = episode.map { KotlinInt(int: Int32($0)) }
    }

    /// The shared repository's token for this model's current request. States carrying any other
    /// token (the previous episode's list after a retarget, the empty state `clear()` leaves) are
    /// ignored, so a re-attached watcher never flashes a stale list or a false "No streams".
    private var expectedRequestToken: String {
        StreamsRepository.shared.requestToken(
            type: type,
            videoId: streamVideoId,
            season: season,
            episode: episode,
            manualSelection: true
        )
    }

    // MARK: - Derived badge-setting conveniences (defaults mirror the shared repository)

    var showFileSizeBadges: Bool { badgeSettings?.showFileSizeBadges ?? true }
    var showAddonLogo: Bool { badgeSettings?.showAddonLogo ?? false }
    var badgesOnTop: Bool { badgeSettings?.badgePlacement == .top }

    static func rowKey(groupId: String, index: Int) -> String { "\(groupId)#\(index)" }

    func start() {
        guard watcher == nil else { return }

        StreamBadgeSettingsRepository.shared.ensureLoaded()
        DebridSettingsRepository.shared.ensureLoaded()
        StreamRankingSettingsRepository.shared.ensureLoaded()
        if rankingPreferences == nil {
            rankingPreferences = StreamRankingSettingsRepository.shared.snapshot()
        }

        watcher = FlowWatcherKt.watch(StreamsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? StreamsUiState else { return }
            let token: String? = state.requestToken
            guard token == self.expectedRequestToken else { return }
            self.lastState = state
            self.apply(state)
        }
        badgeWatcher = FlowWatcherKt.watch(StreamBadgeSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? StreamBadgeSettingsUiState else { return }
            self.badgeSettings = value
        }
        debridWatcher = FlowWatcherKt.watch(DebridSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? DebridSettings else { return }
            let canResolve = value.canResolvePlayableLinks
            self.instantSuffixEnabled = canResolve && !value.hasCustomStreamFormatting
            self.activeResolverProviderId = canResolve ? value.activeResolverProviderId : nil
            self.updateCredentialWarning()
            if self.debridResolveEnabled != canResolve {
                self.debridResolveEnabled = canResolve
                // Filtering depends on this flag — re-derive the visible groups.
                if let last = self.lastState { self.apply(last) }
            } else {
                self.debridResolveEnabled = canResolve
            }
        }
        rankingWatcher = FlowWatcherKt.watch(StreamRankingSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? StreamRankingPreferences else { return }
            guard self.rankingPreferences != value else { return }
            self.rankingPreferences = value
            // New preferences: every group re-sorts once and the pick is chosen again.
            self.frozenOrder = [:]
            self.topPickKey = nil
            if let last = self.lastState { self.apply(last) }
        }
        healthWatcher = FlowWatcherKt.watch(DebridCredentialHealth.shared.authFailedProviderIds) { [weak self] emitted in
            guard let self else { return }
            // Kotlin Set<String> arrives as a Swift Set of AnyHashable.
            let ids = (emitted as? Set<AnyHashable>)?.compactMap { $0 as? String } ?? []
            self.authFailedProviderIds = Set(ids)
            self.updateCredentialWarning()
        }

        // STAB-04: a dead or rate-limited addon reports back in seconds, not after the HTTP
        // client's 60 s. Per request on the shared repository; Android leaves it at 0.
        StreamsRepository.shared.addonFetchTimeoutMillis = Self.addonFetchTimeoutMillis

        // STAB-03: back from the player — the shared list was kept (`detach()`), and the load
        // below is skipped by the repository as an unchanged request. No fresh "open" log line.
        let reattaching = isDetached
        isDetached = false

        // BUG-74: the id this screen was actually handed, logged before the fetch so a tester's
        // photo shows it even if the fetch then reports nothing at all.
        if !reattaching {
            StreamProbe.log("open type=\(type) id=\(streamVideoId)"
                + (streamVideoId != videoId ? " progress=\(videoId)" : "")
                + (season.map { " s=\($0)" } ?? "")
                + (episode.map { " e=\($0)" } ?? ""))
        }

        StreamsRepository.shared.load(
            type: type,
            videoId: streamVideoId,
            parentMetaId: parentMetaId,
            season: season,
            episode: episode,
            manualSelection: true
        )
    }

    func stop() {
        cancelWatchers()
        isDetached = false
        retryingAddonIds = []
        StreamsRepository.shared.clear()
    }

    /// STAB-03: the player went on top of the picker. Stop observing, but keep the shared list
    /// (no `clear()`), so Back from the player finds the same rows — and the same focus — instead of
    /// a fresh fetch. `start()` re-attaches; `stop()` still clears when the picker itself closes.
    func detach() {
        cancelWatchers()
        isDetached = true
    }

    private func cancelWatchers() {
        watcher?.cancel()
        watcher = nil
        badgeWatcher?.cancel()
        badgeWatcher = nil
        debridWatcher?.cancel()
        debridWatcher = nil
        healthWatcher?.cancel()
        healthWatcher = nil
        rankingWatcher?.cancel()
        rankingWatcher = nil
    }

    // MARK: - Stream insight (STREAM-INSIGHT)

    /// The picker's expanded groups: their rows keep their order from then on.
    func setExpandedGroups(_ ids: Set<String>) {
        expandedGroupIds = ids
    }

    /// The title's original language, when the picker learns it (launch meta, then the meta cache).
    func setOriginalLanguage(_ language: String?) {
        let value = (language ?? "").isEmpty ? nil : language
        guard value != originalLanguage else { return }
        originalLanguage = value
        if let last = lastState { apply(last) }
    }

    /// What a row shows for `stream` (nil before its group was ranked).
    func info(for stream: StreamItem) -> StreamRowInfo? {
        rowInfos[Self.streamKey(stream)]
    }

    func isTopPick(_ stream: StreamItem) -> Bool {
        guard let topPickKey else { return false }
        return Self.streamKey(stream) == topPickKey
    }

    /// Identity of a stream across re-emissions: same addon, text and link. A debrid cache check
    /// re-issues the item with a new cache state but the same identity, so its row keeps its place.
    static func streamKey(_ stream: StreamItem) -> String {
        let name: String? = stream.name
        let title: String? = stream.title
        let desc: String? = stream.description_
        let url: String? = stream.url
        let hash: String? = stream.infoHash
        let fileIdx: KotlinInt? = stream.fileIdx
        let parts: [String] = [
            stream.addonId, name ?? "", title ?? "", desc ?? "", url ?? "", hash ?? "",
            fileIdx.map { String($0.int32Value) } ?? "",
        ]
        return parts.joined(separator: "\u{1F}")
    }

    /// The parse cache key: identity plus the cache state the insight reads.
    private static func insightKey(_ stream: StreamItem) -> String {
        streamKey(stream) + "\u{1F}" + (stream.debridCacheStatus?.state.name ?? "")
    }

    private func insight(for stream: StreamItem, key: String) -> StreamInsight {
        if let cached = insightCache[key] { return cached }
        let parsed = StreamInsightParser.shared.parse(stream: stream)
        insightCache[key] = parsed
        return parsed
    }

    private func rankingContext() -> StreamRankingContext {
        StreamRecommender.shared.contextFromSettings(
            originalLanguage: originalLanguage,
            supportsHdr: StreamDisplayCapabilities.supportsHdr,
            supportsDolbyVision: StreamDisplayCapabilities.supportsDolbyVision
        )
    }

    /// Scores one group's streams, records their row info, and returns them best first —
    /// except in an expanded group, whose shown order is kept (new streams go after it).
    private func rankGroup(
        _ streams: [StreamItem],
        groupId: String,
        preferences: StreamRankingPreferences,
        context: StreamRankingContext,
        infos: inout [String: StreamRowInfo]
    ) -> [StreamItem] {
        var entries: [(key: String, stream: StreamItem, score: Int, index: Int)] = []
        entries.reserveCapacity(streams.count)
        for (index, stream) in streams.enumerated() {
            let key = Self.streamKey(stream)
            let recommendation = StreamRecommender.shared.recommend(
                insight: insight(for: stream, key: Self.insightKey(stream)),
                preferences: preferences,
                context: context
            )
            infos[key] = StreamInsightPresenter.rowInfo(stream: stream, recommendation: recommendation)
            entries.append((key: key, stream: stream, score: Int(recommendation.score), index: index))
        }
        guard preferences.enabled else { return streams }
        let desired = entries.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
        }
        guard expandedGroupIds.contains(groupId), let frozen = frozenOrder[groupId] else {
            frozenOrder[groupId] = desired.map { $0.key }
            return desired.map { $0.stream }
        }
        var pool: [String: [StreamItem]] = [:]
        for entry in desired { pool[entry.key, default: []].append(entry.stream) }
        var ordered: [StreamItem] = []
        var keys: [String] = []
        func take(_ key: String) {
            guard var list = pool[key], !list.isEmpty else { return }
            ordered.append(list.removeFirst())
            pool[key] = list
            keys.append(key)
        }
        for key in frozen { take(key) }
        for entry in desired { take(entry.key) }
        frozenOrder[groupId] = keys
        return ordered
    }

    /// STAB-04: Retry on a failed addon row. Refetches that addon alone; falls back to a full
    /// reload when the repository can't (plugin group, or the request has been replaced).
    func retry(addonId: String) {
        guard !retryingAddonIds.contains(addonId) else { return }
        if StreamsRepository.shared.retryAddon(addonId: addonId) {
            retryingAddonIds.insert(addonId)
            if let last = lastState { apply(last) }
        } else {
            reload()
        }
    }

    /// The stream behind a row focus key: `bestMatchRowKey`, or `groupId#index`.
    func stream(forRowKey key: String) -> StreamItem? {
        if key == Self.bestMatchRowKey { return bestMatch?.stream }
        guard let hash = key.lastIndex(of: "#"),
              let index = Int(key[key.index(after: hash)...]) else { return nil }
        let groupId = String(key[..<hash])
        guard let group = groups.first(where: { $0.id == groupId }),
              group.streams.indices.contains(index) else { return nil }
        return group.streams[index]
    }

    static let bestMatchRowKey = "best-match"

    /// Rebuilds `credentialWarning` from the latest health set + active resolver. Only the
    /// ACTIVE resolver's failure is surfaced here — a stale key on a non-active provider
    /// doesn't affect this screen and is handled by the Settings pane instead.
    private func updateCredentialWarning() {
        guard let providerId = activeResolverProviderId,
              authFailedProviderIds.contains(providerId) else {
            credentialWarning = nil
            return
        }
        let name = DebridProviders.shared.displayName(id: providerId)
        credentialWarning = String(
            localized: "Your \(name) session has expired. Reconnect in Settings \u{2192} Account & Services \u{2192} Debrid."
        )
    }

    /// Point the picker at another episode of the same series (the player's end screen "Choose a
    /// Source" for the next episode) and load its streams. The shared repository is a singleton, so
    /// this re-targets the one model in place rather than rebuilding the picker (a rebuilt model's
    /// `stop()` would clear the new load).
    func retarget(videoId: String, streamVideoId: String? = nil, season: Int?, episode: Int?) {
        self.videoId = videoId
        self.streamVideoId = streamVideoId ?? videoId
        self.season = season.map { KotlinInt(int: Int32($0)) }
        self.episode = episode.map { KotlinInt(int: Int32($0)) }
        resetList()
        // Not started yet (or detached under the player): `start()` loads the new target.
        guard watcher != nil else { return }
        StreamsRepository.shared.clear()
        StreamProbe.log("retarget type=\(type) id=\(self.streamVideoId)"
            + (self.streamVideoId != videoId ? " progress=\(videoId)" : "")
            + (self.season.map { " s=\($0)" } ?? "")
            + (self.episode.map { " e=\($0)" } ?? ""))
        StreamsRepository.shared.load(
            type: type,
            videoId: self.streamVideoId,
            parentMetaId: parentMetaId,
            season: self.season,
            episode: self.episode,
            manualSelection: true
        )
    }

    /// Full re-fetch — used when a debrid resolve reports the picked link went stale
    /// (mobile shows the same "Refreshing results" toast and reloads). Uses the repository's
    /// reload() so the addon fetch carries forceRefresh=true and bypasses the HTTP cache —
    /// a stale-link retry that re-reads a cached stream list would just re-pick the dead link.
    func reload() {
        lastState = nil
        retryingAddonIds = []
        // A full re-fetch may bring a different set of streams: the pinned row is chosen again.
        bestMatch = nil
        topPickKey = nil
        frozenOrder = [:]
        insightCache = [:]
        StreamsRepository.shared.clear()
        StreamsRepository.shared.reload(
            type: type,
            videoId: streamVideoId,
            parentMetaId: parentMetaId,
            season: season,
            episode: episode,
            manualSelection: true
        )
    }

    /// Empties everything a new target must not inherit (retarget).
    private func resetList() {
        lastState = nil
        groups = []
        failedGroups = []
        bestMatch = nil
        topPickKey = nil
        frozenOrder = [:]
        insightCache = [:]
        rowInfos = [:]
        autoExpandGroupId = nil
        retryingAddonIds = []
        firstRowKey = nil
        emptyReason = nil
        emptyReasonHint = nil
        isLoading = true
    }

    private func apply(_ state: StreamsUiState) {
        isLoading = state.isAnyLoading
        let debridEnabled = debridResolveEnabled
        let preferences = rankingPreferences ?? StreamRankingSettingsRepository.shared.snapshot()
        let context = rankingContext()
        var infos: [String: StreamRowInfo] = [:]

        var playableGroups: [Group] = []
        var failed: [FailedGroup] = []
        // F10: walk install order; the first addon with playable streams is the one to expand,
        // unless an addon before it is still loading (it may still bring streams of its own).
        var expandTarget: String?
        var expandDecided = false
        for group in state.groups {
            // Widen through an explicit String? — Kotlin's nullable String surfaces here as a
            // non-optional Swift String, so direct optional-chaining/binding won't compile.
            let playable = group.streams.filter { stream in
                let direct: String? = stream.playableDirectUrl
                if !(direct ?? "").isEmpty { return true }
                // Torrent / clientResolve results from installed addons resolve at click time
                // through the in-app debrid connection (DirectDebridPlaybackResolver).
                return debridEnabled && stream.isAddonDebridCandidate
            }
            let error: String? = group.error
            let retrying = retryingAddonIds.contains(group.addonId)
            if retrying && !group.isLoading {
                retryingAddonIds.remove(group.addonId)
            }
            if !playable.isEmpty {
                // STREAM-INSIGHT: best first for this viewer (frozen once the group is open).
                let ranked = rankGroup(playable, groupId: group.addonId, preferences: preferences,
                                       context: context, infos: &infos)
                playableGroups.append(Group(
                    id: group.addonId,
                    addonName: group.addonName,
                    streams: ranked,
                    isLoading: group.isLoading,
                    qualitySummary: qualitySummary(ranked)
                ))
                if !expandDecided { expandTarget = group.addonId; expandDecided = true }
            } else if group.streams.isEmpty, let error, !error.isEmpty, !group.isLoading {
                failed.append(FailedGroup(
                    id: group.addonId,
                    addonName: group.addonName,
                    message: Self.failureMessage(addonName: group.addonName, error: error),
                    isRetrying: false
                ))
            } else if retrying && group.isLoading {
                // Keep the row (and its focus) in place while the retry runs.
                let previous = failedGroups.first { $0.id == group.addonId }
                failed.append(FailedGroup(
                    id: group.addonId,
                    addonName: group.addonName,
                    message: previous?.message ?? group.addonName,
                    isRetrying: true
                ))
            } else if group.isLoading, !expandDecided {
                expandDecided = true      // an earlier addon is still out: wait for it
            }
        }
        rowInfos = infos
        groups = playableGroups
        failedGroups = failed
        if autoExpandGroupId == nil, let expandTarget { autoExpandGroupId = expandTarget }
        firstRowKey = groups.first.map { Self.rowKey(groupId: $0.id, index: 0) }
        updateBestMatch(allAnswered: !state.isAnyLoading)

        // STAB-04: a Retry on the empty screen keeps that screen (and its focused row) up while
        // the retried addons are the only ones still out.
        let loadingOnlyRetries = state.isAnyLoading && state.groups.allSatisfy { group in
            !group.isLoading || retryingAddonIds.contains(group.addonId)
        }
        if groups.isEmpty && loadingOnlyRetries && emptyReason != nil {
            // Keep the current reason and hint.
        } else if groups.isEmpty && !isLoading {
            // The shared repository's `emptyStateReason` only covers "we truly found nothing"
            // (no addons, fetch failed, etc.) — it has no concept of the local playability
            // filter above, so a title with plenty of raw torrent results but no debrid
            // connection still reports `NoStreamsFound`-adjacent nils here. Detect that case
            // ourselves: shared handed us streams, but every one of them got filtered out.
            let rawCount = state.groups.reduce(0) { $0 + $1.streams.count }
            if rawCount > 0 {
                (emptyReason, emptyReasonHint) = Self.describeFiltered(rawCount: rawCount, debridEnabled: debridEnabled)
            } else {
                (emptyReason, emptyReasonHint) = Self.describe(state.emptyStateReason)
            }
        } else {
            emptyReason = nil
            emptyReasonHint = nil
        }
    }

    // MARK: - Best match (STAB-07, picker half)

    /// Picks the pinned row once and keeps it: the source this title/episode was last played from
    /// as soon as it shows up, otherwise — after every addon has answered — the highest-quality
    /// playable stream (resolution first, then ready-to-play over needs-a-resolve), install order
    /// breaking ties. Never re-picked while the list is on screen, so the row never swaps under
    /// focus; `reload()` and `retarget` start over.
    private func updateBestMatch(allAnswered: Bool) {
        if let current = bestMatch {
            // Keep it, refreshed to the list's current copy of the same stream (a debrid cache
            // check or prepare re-issues the item); drop it only if the stream left the list.
            let currentDesc: String? = current.stream.description_
            let fresh = groups.first { $0.id == current.groupId }?.streams.first { stream in
                let desc: String? = stream.description_
                return stream.streamLabel == current.stream.streamLabel && desc == currentDesc
            }
            if let fresh {
                if fresh != current.stream {
                    bestMatch = BestMatch(groupId: current.groupId, stream: fresh, isLastUsed: current.isLastUsed,
                                          isRecommended: current.isRecommended)
                }
                updateTopPick(allAnswered: allAnswered)
                return
            }
            bestMatch = nil
        }
        updateTopPick(allAnswered: allAnswered)
        if let lastUsed = lastUsedMatch() {
            bestMatch = lastUsed
            return
        }
        guard allAnswered else { return }
        // STREAM-INSIGHT: the recommender's pick for this viewer, when there is one.
        if let topPickKey,
           let group = groups.first(where: { group in group.streams.contains { Self.streamKey($0) == topPickKey } }),
           let stream = group.streams.first(where: { Self.streamKey($0) == topPickKey }) {
            bestMatch = BestMatch(groupId: group.id, stream: stream, isLastUsed: false, isRecommended: true)
            return
        }
        var best: (score: Int, groupId: String, stream: StreamItem)?
        for group in groups {
            for stream in group.streams {
                let score = Self.qualityScore(stream)
                if best == nil || score > best!.score {
                    best = (score, group.id, stream)
                }
            }
        }
        if let best {
            bestMatch = BestMatch(groupId: best.groupId, stream: best.stream, isLastUsed: false)
        }
    }

    /// STREAM-INSIGHT: the recommended stream across every group — the best-scored one that
    /// passes the hard filters, install order breaking ties. Chosen once every addon has answered,
    /// then kept while it stays in the list. None while ranking is off or everything is filtered.
    private func updateTopPick(allAnswered: Bool) {
        let enabled = (rankingPreferences ?? StreamRankingSettingsRepository.shared.snapshot()).enabled
        guard enabled else {
            topPickKey = nil
            return
        }
        if let current = topPickKey {
            if groups.contains(where: { group in group.streams.contains { Self.streamKey($0) == current } }) { return }
            topPickKey = nil
        }
        guard allAnswered else { return }
        var best: (score: Int, key: String)?
        for group in groups {
            for stream in group.streams {
                let key = Self.streamKey(stream)
                guard let info = rowInfos[key], !info.isExcluded else { continue }
                if best == nil || info.score > best!.score {
                    best = (info.score, key)
                }
            }
        }
        topPickKey = best?.key
    }

    /// The stream this title/episode was last played from, matched on the progress record's addon
    /// and its link (else its stream name).
    private func lastUsedMatch() -> BestMatch? {
        guard let progress = WatchProgressRepository.shared.progressForVideo(
            videoId: videoId,
            parentMetaId: parentMetaId,
            seasonNumber: season,
            episodeNumber: episode
        ) else { return nil }
        let addonId: String? = progress.providerAddonId
        let lastUrl: String? = progress.lastSourceUrl
        let lastTitle: String? = progress.lastStreamTitle
        guard let addonId, !addonId.isEmpty,
              let group = groups.first(where: { $0.id == addonId }) else { return nil }
        if let lastUrl, !lastUrl.isEmpty,
           let match = group.streams.first(where: { stream in
               let direct: String? = stream.playableDirectUrl
               return direct == lastUrl
           }) {
            return BestMatch(groupId: group.id, stream: match, isLastUsed: true)
        }
        if let lastTitle, !lastTitle.isEmpty,
           let match = group.streams.first(where: { $0.streamLabel == lastTitle }) {
            return BestMatch(groupId: group.id, stream: match, isLastUsed: true)
        }
        return nil
    }

    /// Resolution tier read from the stream's name and description: 4 = 4K, 3 = 1080p, 2 = 720p,
    /// 1 = SD, 0 = not stated.
    static func resolutionTier(_ stream: StreamItem) -> Int {
        let desc: String? = stream.description_
        let name: String? = stream.name
        let text = [stream.streamLabel, desc ?? "", name ?? ""].joined(separator: " ").lowercased()
        func has(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        if has(#"2160p|\b4k\b|\buhd\b"#) { return 4 }
        if has(#"1080p|1440p|\bfhd\b"#) { return 3 }
        if has(#"720p"#) { return 2 }
        if has(#"480p|576p|360p|\bsd\b"#) { return 1 }
        return 0
    }

    /// Resolution first; within a tier a cached-on-debrid or direct link (plays at once) beats a
    /// torrent that still needs a resolve.
    private static func qualityScore(_ stream: StreamItem) -> Int {
        var score = resolutionTier(stream) * 10
        if let status = stream.debridCacheStatus, status.state == .cached { score += 2 }
        let direct: String? = stream.playableDirectUrl
        if !(direct ?? "").isEmpty { score += 1 }
        return score
    }

    /// STAB-07: "2 × 4K · 5 × 1080p" — technical labels, the same in every language.
    /// STREAM-INSIGHT: read from the parsed insights (1440p and 480p now counted too).
    private func qualitySummary(_ streams: [StreamItem]) -> String? {
        var counts: [String: Int] = [:]
        for stream in streams {
            guard let label = insightCache[Self.insightKey(stream)]?.resolution.label, !label.isEmpty else { continue }
            counts[label, default: 0] += 1
        }
        let labels = ["4K", "1440p", "1080p", "720p", "480p", "SD"]
        let parts = labels.compactMap { label -> String? in
            guard let count = counts[label] else { return nil }
            return "\(count) \u{00D7} \(label)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// STAB-04: "Torrentio: unavailable (HTTP 429)" / "…: no answer (timed out)".
    private static func failureMessage(addonName: String, error: String) -> String {
        if StreamsRepository.shared.isTimeoutError(error: error) {
            return String(
                localized: "streams.addon.failed.timeout",
                defaultValue: "\(addonName): no answer (timed out)",
                comment: "Source picker: an addon did not answer in time. %@ is the addon name."
            )
        }
        if let range = error.range(of: #"HTTP [0-9]{3}"#, options: .regularExpression) {
            let code = String(error[range].suffix(3))
            return String(
                localized: "streams.addon.failed.http",
                defaultValue: "\(addonName): unavailable (HTTP \(code))",
                comment: "Source picker: an addon answered with an HTTP error. First %@ is the addon name, second the status code."
            )
        }
        return String(
            localized: "streams.addon.failed.generic",
            defaultValue: "\(addonName): unavailable",
            comment: "Source picker: an addon's stream lookup failed. %@ is the addon name."
        )
    }

    /// Builds the reason/hint pair for the "shared found streams, but our playability filter
    /// dropped all of them" case. Distinguishes the common cause (debrid off, torrent-only
    /// results) from the rarer one (debrid already on, but nothing still resolved) so the hint
    /// never tells someone to do something they've already done.
    private static func describeFiltered(rawCount: Int, debridEnabled: Bool) -> (String, String?) {
        let sourceWord = rawCount == 1 ? "source" : "sources"
        if !debridEnabled {
            let reason = String(localized: "Found \(rawCount) torrent \(sourceWord), but no debrid service is connected.")
            let hint = String(localized: "Connect one in Settings \u{2192} Account & Services \u{2192} Debrid, or turn on \u{201C}Resolve Streams with Debrid\u{201D}.")
            return (reason, hint)
        }
        let reason = String(localized: "Found \(rawCount) \(rawCount == 1 ? "stream" : "streams"), but none could be resolved to a playable link.")
        return (reason, nil)
    }

    /// BUG-74: `NoCompatibleAddons` used to assert "only a metadata catalog (Cinemeta) is set up",
    /// which was a guess dressed as a fact — and when a `tmdb:` id filtered out addons the user
    /// definitely had installed, it was a confident lie that sent them looking in the wrong place
    /// for three weeks. Both strings now describe what we actually know, and the id case has its
    /// own reason so it can say so.
    private static func describe(_ reason: StreamsEmptyStateReason?) -> (String, String?) {
        switch reason?.name {
        case "NoAddonsInstalled":
            return (String(localized: "No addons installed."),
                    String(localized: "Add one in Settings \u{2192} Content Sources \u{2192} Addons."))
        case "NoCompatibleAddons":
            return (String(localized: "None of your addons provide streams for this title."),
                    String(localized: "Your installed addons either don\u{2019}t serve streams, or don\u{2019}t cover this content type."))
        case "IncompatibleContentId":
            return (String(localized: "Couldn\u{2019}t look this title up with your stream addons."),
                    String(localized: "It was opened from a TMDB source and has no matching IMDb id, which is what stream addons need. Opening it from search or a different row usually works."))
        case "NoStreamsFound":
            return (String(localized: "No streams found for this title."), nil)
        case "StreamFetchFailed":
            return (String(localized: "Stream lookup failed."), nil)
        default:
            return (String(localized: "No playable streams. Install a streaming addon, or connect a debrid account in Settings to play torrent results."), nil)
        }
    }

    deinit {
        watcher?.cancel()
        badgeWatcher?.cancel()
        debridWatcher?.cancel()
        healthWatcher?.cancel()
        rankingWatcher?.cancel()
    }
}
