import Combine
import Foundation
import SharedCore

/// Loads and observes the full metadata for a single title via the shared `MetaDetailsRepository`,
/// and tracks its Watched / Library state via the shared `WatchedRepository` / `LibraryRepository`.
///
/// `MetaDetailsRepository.load(type:id:)` kicks off the fetch (cache-first, then addon/TMDB enrich);
/// `uiState` (a `StateFlow<MetaDetailsUiState>`) emits `{isLoading, meta, errorMessage}` as it resolves.
/// The watched/library flags are recomputed from their repositories on every emission so the Detail
/// action buttons stay in sync after a toggle (persisted per-profile via the Phase 0 seams).
@MainActor
final class DetailViewModel: ObservableObject {
    @Published private(set) var meta: MetaDetails?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWatched: Bool = false
    @Published private(set) var isSaved: Bool = false
    /// Resolved, directly-playable trailer video URL for the hero (nil until/unless one resolves).
    @Published private(set) var trailerVideoURL: String?
    /// BUG-81: the YouTube video id `trailerVideoURL` was extracted from, handed to the trailer
    /// surfaces so the letterbox probe can key its persisted zoom on something that survives a
    /// re-extraction. Always written together with `trailerVideoURL`, so the two never disagree
    /// about which stream is on screen. See `TrailerHeroPlayer.videoId`.
    @Published private(set) var trailerVideoId: String?
    /// Trakt community comments (empty while Trakt is disconnected — the shared repo no-ops).
    @Published private(set) var comments: [TraktCommentReview] = []
    /// IMDb episode ratings keyed "season:episode" (api.imdbapi.dev, keyless).
    @Published private(set) var episodeRatings: [String: Double] = [:]
    /// Episodes to badge as watched, keyed "season:episode" — explicit Watched marks OR
    /// effectively-completed watch progress (mirrors mobile's player episode rows).
    @Published private(set) var watchedEpisodeKeys: Set<String> = []
    /// AES-4/EP-2: partial watch progress (0…1) per episode, keyed "season:episode" — the latest
    /// record of each episode still in progress; watched episodes are left out (they get the check).
    @Published private(set) var episodeProgress: [String: Double] = [:]
    /// Series-level primary play action (Resume SxEy / Play SxEy, honoring behaviorHints
    /// defaultVideoId) from the shared resolver; nil for movies or while meta loads.
    @Published private(set) var seriesAction: SeriesPrimaryAction?
    /// PLY-A13: the movie has a saved position its Play would resume from — Detail then offers
    /// "Start from Beginning" beside it. Always false for a series (see `seriesAction`).
    @Published private(set) var movieHasResumePoint = false
    /// Upstream 972109f9: false once it is certain no configured source (stream add-on, plugin,
    /// embedded stream) can stream the primary Play target — Detail greys Play out instead of
    /// opening a stream list that can only say so. True while that is not known.
    @Published private(set) var isPlaybackAvailable = true
    /// IMDb parental-guide severities (empty when the title has no tt-id or no guide data).
    @Published private(set) var parentalWarnings: [ParentalWarning] = []
    /// SET-2 / upstream 6fb46976b (Settings → Appearance → Ratings, synced per profile): whether the
    /// meta line shows the title's IMDb rating, and which episode badges carry a rating —
    /// `EpisodeRatingsVisibility.name` ("SHOW_ALL" / "HIDE_EPISODES" / "HIDE_UNWATCHED_EPISODES").
    @Published private(set) var showOverallRatings = true
    @Published private(set) var episodeRatingsVisibility = "SHOW_ALL"
    /// Resolved full-screen trailer (from the Trailers row); drives a player cover with sound.
    @Published var trailerPlayback: TrailerPlaybackItem?
    /// Trailer currently resolving (spinner on its row card).
    @Published private(set) var resolvingTrailerId: String?

    /// Ownership of the shared (unkeyed) `MetaDetailsRepository`. Nested pushes (Detail → More Like
    /// This → Detail) overlap start/stop: the destination may `load()` before the source's
    /// `onDisappear` fires, and an unconditional `clear()` there wipes the destination's in-flight
    /// request (HI-005). Only the most recent screen to call `start()` owns the repo and may clear it.
    private static var currentOwner: UUID?
    private let ownerToken = UUID()

    private var detailWatcher: FlowWatcher?
    private var watchedWatcher: FlowWatcher?
    /// DET-2: fully-watched series state is its own flow (a reconcile can change it without
    /// touching the watched items).
    private var fullyWatchedWatcher: FlowWatcher?
    private var libraryWatcher: FlowWatcher?
    /// Installed add-ons and plugin scrapers → `isPlaybackAvailable`.
    private var addonsWatcher: FlowWatcher?
    private var pluginsWatcher: FlowWatcher?
    /// A series watched toggle is in flight (the shared action fetches the episode list first).
    private var watchedToggleInFlight = false
    private var progressWatcher: FlowWatcher?
    private var cwPrefsWatcher: FlowWatcher?
    private var ratingsSettingsWatcher: FlowWatcher?
    // Latest shared-state emissions (the exported StateFlow interface has no `value` accessor,
    // so the watchers below capture what the series primary action needs).
    private var latestProgressEntries: [WatchProgressEntry] = []
    private var latestWatchedItems: [WatchedItem] = []
    private var latestCwPrefs: ContinueWatchingPreferencesUiState?
    /// DET-2: the series-level watched state is reconciled (mobile MetaDetailsScreen) only once both
    /// stores have loaded — and only when what it reads has changed since the last run.
    private var watchedStateLoaded = false
    private var progressRemoteLoaded = false
    private var watchedStateVersion = 0
    private var lastReconcileSignature: String?
    private var didRequestTrailer = false
    private var didRequestComments = false
    private var didRequestRatings = false
    private var didRequestGuide = false
    /// BUG-101 (War Machine, 2026-09-08): the ranked hero-trailer candidates for the current title
    /// (`HeroTrailerSelectorKt.rankHeroTrailers`) and which one is currently being tried/playing —
    /// a dead/blocked top pick (e.g. a TMDB-listed French trailer whose YouTube id no longer
    /// resolves) falls through to the next ranked candidate instead of leaving Detail with no
    /// trailer at all, even though a playable one (usually the English one `fetchTmdbVideos`
    /// always merges in) sits right behind it.
    private var trailerCandidates: [MetaTrailer] = []
    private var trailerCandidateIndex = 0
    /// One retry after an AVPlayer *playback* failure (as opposed to an extraction miss) per
    /// title — otherwise a title whose every remaining candidate fails to actually play would
    /// retry without end.
    private var trailerRetriedAfterPlaybackFailure = false
    /// Bumped in `stop()` so a completion from a resolution the current title has already walked
    /// away from (a stop()/start() reuse of this same view model instance mid-flight) can never
    /// apply — the identity guard `resolveTrailerIfNeeded`'s completions check before touching
    /// `trailerVideoURL`/`trailerVideoId`.
    private var trailerResolveGeneration = 0

    private let preview: MetaPreview
    /// The catalog preview's identity — the repo request key (`load`, the stale-emission guard) and
    /// the trailer zoom key. Watch/library/progress state lives under `contentId` instead.
    private var type: String { preview.type }
    private var id: String { preview.id }
    /// DET-1: the identity watched/library/progress state is read AND written under — the resolved
    /// meta's. A TMDB-backed preview's `tmdb:` id resolves to `tt…`, and every write (library,
    /// playback progress, completion marks) uses the meta's id; the preview's until it arrives.
    private var contentId: String { meta?.id ?? preview.id }
    private var contentType: String { meta?.type ?? preview.type }
    /// The preview's identity while it differs from the meta's: a mark saved under it before the
    /// meta resolved still reads as set (and is what a toggle then clears).
    private var previewIdentityIfDistinct: (id: String, type: String)? {
        guard let meta, meta.id != preview.id else { return nil }
        return (preview.id, preview.type)
    }
    /// The content id `refreshEpisodeProgress` last ran for (re-run once the meta's id is known).
    private var episodeProgressRequestedFor: String?
    /// BUG-59: the identity the trailer surfaces remember their measured zoom under.
    var trailerZoomKey: String { TrailerResolutionCache.key(type: type, id: id) }

    init(preview: MetaPreview) {
        self.preview = preview
    }

    func start() {
        guard detailWatcher == nil else { return }
        Self.currentOwner = ownerToken

        // SET-2: the rating settings are read BEFORE the detail watcher can deliver a meta, so a
        // title opened with episode ratings hidden never fetches them (the watcher below takes over).
        MetaScreenSettingsRepository.shared.ensureLoaded()
        if let state = MetaScreenSettingsRepository.shared.uiState.value_ as? MetaScreenSettingsUiState {
            showOverallRatings = state.showOverallRatings
            episodeRatingsVisibility = state.episodeRatingsVisibility.name
        }

        detailWatcher = FlowWatcherKt.watch(MetaDetailsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MetaDetailsUiState else { return }
            // The shared repo holds one in-flight detail at a time — only adopt emissions for ours.
            // The repo tags every publish with the ORIGINAL request key ("type:id" from the catalog
            // preview we passed to load()); the resolved meta's own id can differ (the repo remaps
            // tmdb: → tt… and the addon returns its canonical id), so we must NOT match on meta.id.
            // The initial/cleared empty state carries no key — fall back to repo ownership for it.
            if let key = state.requestKey {
                if key != "\(self.type):\(self.id)" { return }
            } else if Self.currentOwner != self.ownerToken {
                return
            }
            self.isLoading = state.isLoading
            self.meta = state.meta
            self.errorMessage = state.errorMessage
            if let m = state.meta {
                self.resolveTrailerIfNeeded(m)
                self.fetchCommentsIfNeeded(m)
                self.fetchEpisodeRatingsIfNeeded(m)
                self.fetchParentalGuideIfNeeded(m)
                // DET-1: the meta's id can differ from the preview's (tmdb: → tt…).
                self.refreshEpisodeProgressIfNeeded()
            }
            self.refreshFlags()
        }

        // Live Watched / Library state for the action buttons + per-episode watched badges.
        WatchedRepository.shared.ensureLoaded()
        LibraryRepository.shared.ensureLoaded()
        WatchProgressRepository.shared.ensureLoaded()
        // Hydrate Trakt-sourced per-episode completion for this title (no-op/cached otherwise).
        refreshEpisodeProgressIfNeeded()
        watchedWatcher = FlowWatcherKt.watch(WatchedRepository.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            if let state = emitted as? WatchedUiState {
                self.latestWatchedItems = state.items
                self.watchedStateLoaded = state.isLoaded
                self.watchedStateVersion += 1
            }
            self.refreshFlags()
        }
        fullyWatchedWatcher = FlowWatcherKt.watch(WatchedRepository.shared.fullyWatchedSeriesKeys) { [weak self] _ in
            self?.refreshFlags()
        }
        libraryWatcher = FlowWatcherKt.watch(LibraryRepository.shared.uiState) { [weak self] _ in
            guard let self else { return }
            self.refreshFlags()
        }
        addonsWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] _ in
            self?.refreshFlags()
        }
        // A plugin repository synced from the phone brings its scrapers once its manifest lands.
        pluginsWatcher = FlowWatcherKt.watch(PluginRepository.shared.uiState) { [weak self] _ in
            self?.refreshFlags()
        }
        progressWatcher = FlowWatcherKt.watch(WatchProgressRepository.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            if let state = emitted as? WatchProgressUiState {
                self.latestProgressEntries = state.entries
                self.progressRemoteLoaded = state.hasLoadedRemoteProgress
            }
            self.refreshFlags()
        }
        cwPrefsWatcher = FlowWatcherKt.watch(ContinueWatchingPreferencesRepository.shared.uiState) { [weak self] emitted in
            guard let self else { return }
            if let state = emitted as? ContinueWatchingPreferencesUiState { self.latestCwPrefs = state }
            self.refreshFlags()
        }
        refreshFlags()

        ratingsSettingsWatcher = FlowWatcherKt.watch(MetaScreenSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MetaScreenSettingsUiState else { return }
            self.showOverallRatings = state.showOverallRatings
            self.episodeRatingsVisibility = state.episodeRatingsVisibility.name
            // Episode ratings shown again after the title loaded with them hidden: fetch them now.
            if let m = self.meta { self.fetchEpisodeRatingsIfNeeded(m) }
        }

        MetaDetailsRepository.shared.load(type: type, id: id)
    }

    func stop() {
        detailWatcher?.cancel(); detailWatcher = nil
        watchedWatcher?.cancel(); watchedWatcher = nil
        fullyWatchedWatcher?.cancel(); fullyWatchedWatcher = nil
        libraryWatcher?.cancel(); libraryWatcher = nil
        addonsWatcher?.cancel(); addonsWatcher = nil
        pluginsWatcher?.cancel(); pluginsWatcher = nil
        progressWatcher?.cancel(); progressWatcher = nil
        cwPrefsWatcher?.cancel(); cwPrefsWatcher = nil
        ratingsSettingsWatcher?.cancel(); ratingsSettingsWatcher = nil
        episodeProgressRequestedFor = nil
        lastReconcileSignature = nil
        trailerVideoURL = nil
        trailerVideoId = nil
        didRequestTrailer = false
        trailerCandidates = []
        trailerCandidateIndex = 0
        trailerRetriedAfterPlaybackFailure = false
        trailerResolveGeneration &+= 1
        // Only the current owner clears the shared repo — a source screen disappearing mid-push
        // must not cancel the destination's request (HI-005).
        if Self.currentOwner == ownerToken {
            Self.currentOwner = nil
            MetaDetailsRepository.shared.clear()
        }
    }

    // MARK: - Hero trailer

    /// Once per title: rank the hero-trailer candidates (`rankHeroTrailers`) and resolve them in
    /// ranked order into a directly-playable stream via the shared `HeroTrailerResolver`,
    /// publishing the first one that actually works. Fails soft — if nothing resolves,
    /// `trailerVideoURL` stays nil and Detail keeps the static backdrop.
    private func resolveTrailerIfNeeded(_ meta: MetaDetails) {
        guard !didRequestTrailer else { return }
        let trailers = meta.trailers
        guard !trailers.isEmpty else { return }
        // BUG-101 (War Machine, 2026-09-08): the FULL ranking, not just the head — a dead/blocked
        // top candidate (e.g. a TMDB-listed French trailer whose YouTube id no longer resolves)
        // falls through to the next one instead of leaving Detail with no trailer at all, even
        // though a playable one (usually the English one `fetchTmdbVideos` always merges in) sits
        // right behind it.
        let ranked = HeroTrailerSelectorKt.rankHeroTrailers(
            trailers: trailers,
            preferredLanguage: TmdbSettingsRepository.shared.snapshot().language
        )
        guard !ranked.isEmpty else { return }
        didRequestTrailer = true
        trailerCandidates = ranked
        trailerCandidateIndex = 0
        trailerRetriedAfterPlaybackFailure = false
        attemptTrailerResolution(generation: trailerResolveGeneration)
    }

    /// BUG-101: walks `trailerCandidates` starting at `trailerCandidateIndex`, advancing to the
    /// next one whenever `HeroTrailerResolver` extraction comes back nil, OR (Finding 3) when
    /// extraction succeeds but `TrailerLocalHLS`'s repack of that source yields no playable URL —
    /// capped at 3 attempts total so a title with nothing but dead links doesn't chain an
    /// unbounded run of extractions. `generation` is the value `trailerResolveGeneration` held
    /// when this title's resolution began; every completion re-checks it before touching
    /// published state, so a stale completion from a resolution this title has already walked
    /// away from (a `stop()`/`start()` reuse of this same view model instance mid-flight) can
    /// never apply.
    private func attemptTrailerResolution(generation: Int) {
        guard trailerCandidateIndex < trailerCandidates.count, trailerCandidateIndex < 3 else { return }
        let trailer = trailerCandidates[trailerCandidateIndex]
        let attemptIndex = trailerCandidateIndex
        let totalCandidates = min(trailerCandidates.count, 3)

        var youtubeUrl = trailer.youtubePlaybackUrl()
        // Sim/device verification knob for the SABR repackaging path: force every Detail hero
        // trailer to a specific videoId (e.g. rNZ0xKaCdus) so [TrailerRepack]/[TrailerQuality]
        // logs are deterministic. `defaults write <bundle> debug.trailerSmokeVideoId <id>`.
        // Phase 0 (BUG-46/UX-9, 2026-08-06): lifted out of `#if DEBUG` — the trailer soak needs
        // this on release sideloads too (testers, device passes), same rationale as
        // `TrailerProbe`/`HomeGeometryProbe` being runtime knobs rather than compile-time ones.
        // BUG-59 (beta.13): honored only together with `debug.trailerProbe` — see the same guard
        // in `InlineTrailerCardModel.resolve` for why.
        if TrailerProbe.enabled, let forced = TrailerProbe.smokeVideoId {
            youtubeUrl = "https://www.youtube.com/watch?v=\(forced)"
        }
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] hero resolve candidate=%d/%d id=%@", attemptIndex + 1, totalCandidates, trailer.id)
        }
        HeroTrailerResolver.shared.resolveYouTube(youtubeUrl: youtubeUrl) { [weak self] source, _ in
            DispatchQueue.main.async {
                guard let self, self.trailerResolveGeneration == generation else { return }
                guard let source else {
                    // BUG-101: extraction miss — this candidate's YouTube id didn't resolve
                    // (dead/blocked/deleted). Try the next ranked one rather than give up.
                    self.trailerCandidateIndex = attemptIndex + 1
                    self.attemptTrailerResolution(generation: generation)
                    return
                }
                // AVPlayer-friendly URL only (tvOS plays trailers via AVPlayer, not libmpv):
                // a local byte-range HLS repackage of the demuxed 1080p pair when the extractor
                // surfaced one (SABR fallback), else the progressive/HLS URL as before.
                TrailerLocalHLS.shared.playbackURL(for: source) { [weak self] url in
                    guard let self, self.trailerResolveGeneration == generation else { return }
                    guard let url else {
                        // Finding 3 (BUG-101 follow-up): extraction succeeded but the local repack
                        // yielded nothing playable (conversion failure, no progressive fallback) —
                        // this candidate is a dead end exactly like an extraction miss. Walk to the
                        // next ranked one within the same budget instead of leaving Detail with no
                        // trailer; a playback failure can't help here because no player ever starts.
                        self.trailerCandidateIndex = attemptIndex + 1
                        self.attemptTrailerResolution(generation: generation)
                        return
                    }
                    self.trailerVideoURL = url
                    self.trailerVideoId = source.videoId
                }
            }
        }
    }

    /// The trailer surface reports it couldn't start (undecodable/stalled) — drop it so Detail
    /// keeps the static backdrop, unless a next-ranked candidate is worth one retry first.
    ///
    /// BUG-101: an AVPlayer *playback* failure (as opposed to the extraction miss
    /// `attemptTrailerResolution` already handles) doesn't mean the title has nothing to show —
    /// try the next ranked candidate once before giving up, the same one-retry discipline
    /// `InlineTrailerCardModel.playbackFailed` uses.
    func trailerFailed() {
        trailerVideoURL = nil
        trailerVideoId = nil
        guard !trailerRetriedAfterPlaybackFailure,
              trailerCandidateIndex + 1 < trailerCandidates.count,
              trailerCandidateIndex + 1 < 3 else { return }
        trailerRetriedAfterPlaybackFailure = true
        trailerCandidateIndex += 1
        attemptTrailerResolution(generation: trailerResolveGeneration)
    }

    /// Trailers row: resolve one trailer's YouTube URL into an AVPlayer-friendly stream and present
    /// it full-screen (with sound — unlike the muted hero loop).
    func playTrailer(_ trailer: MetaTrailer) {
        guard resolvingTrailerId == nil else { return }
        resolvingTrailerId = trailer.id
        var youtubeUrl = trailer.youtubePlaybackUrl()
        // Repro-gap fix (2026-08-30 investigation): `resolveTrailerIfNeeded` above honors
        // `debug.trailerSmokeVideoId` (paired with `debug.trailerProbe`, same discipline as
        // `InlineTrailerCardModel.resolve`) so the Detail hero can be pinned to a deterministic
        // video in the simulator; this row-clip path never did, so there was no way to force a
        // "Trailers & Extras" clip to a known stream for repro/soak work. Substituting AFTER
        // `trailer.id` is what keys `resolvingTrailerId`/the eventual `TrailerPlaybackItem.zoomKey`
        // keeps per-card state distinct even though every forced clip resolves the same video.
        if TrailerProbe.enabled, let forced = TrailerProbe.smokeVideoId {
            youtubeUrl = "https://www.youtube.com/watch?v=\(forced)"
        }
        HeroTrailerResolver.shared.resolveYouTube(youtubeUrl: youtubeUrl) { [weak self] source, _ in
            DispatchQueue.main.async {
                guard let self, let source else {
                    self?.resolvingTrailerId = nil
                    return
                }
                TrailerLocalHLS.shared.playbackURL(for: source) { [weak self] url in
                    guard let self else { return }
                    self.resolvingTrailerId = nil
                    guard let url else { return }
                    // C3 (2026-08-30 investigation): a per-clip zoom key, NOT `trailerZoomKey` — see
                    // `TrailerPlaybackItem.zoomKey`'s doc comment. The hero trailer and every row
                    // clip used to share one title-keyed `TrailerZoomCache` entry, so whichever
                    // measured last stomped the other's crop.
                    self.trailerPlayback = TrailerPlaybackItem(
                        id: trailer.id, url: url, title: trailer.name,
                        zoomKey: "\(self.trailerZoomKey):clip:\(trailer.id)",
                        videoId: source.videoId
                    )
                }
            }
        }
    }

    // MARK: - Trakt comments

    /// Once per title: first page of Trakt community comments. The shared repo resolves the Trakt
    /// ids from `meta` itself and returns an empty page when Trakt isn't connected, so the section
    /// simply stays hidden in that case.
    ///
    /// Goes through `TraktCommentsSwiftBridge`: the raw repo call THROWS on HTTP errors (e.g. 401
    /// when the synced Trakt token is rejected), and an undeclared Kotlin exception crossing a
    /// suspend completion terminates the app. The bridge collapses failures to nil.
    private func fetchCommentsIfNeeded(_ meta: MetaDetails) {
        guard !didRequestComments else { return }
        didRequestComments = true
        TraktCommentsSwiftBridge.shared.pageOrNull(meta: meta, page: 1, forceRefresh: false) { [weak self] page, _ in
            DispatchQueue.main.async {
                guard let self, let page else { return }
                self.comments = page.items
            }
        }
    }

    // MARK: - IMDb episode ratings (series only)

    /// Once per series: per-episode IMDb ratings from api.imdbapi.dev (keyless), keyed
    /// "season:episode" for the episode list to badge. Movies and titles without a tt/tmdb id skip.
    private func fetchEpisodeRatingsIfNeeded(_ meta: MetaDetails) {
        // SET-2 (upstream 6fb46976b): no request while episode ratings are hidden; the settings
        // watcher calls back in here once they are shown again.
        guard !didRequestRatings, episodeRatingsVisibility != "HIDE_EPISODES",
              EpisodesSection.isSeriesLike(meta) else { return }
        // Upstream 90054b7b9: the addon's own `imdb_id` rates kitsu/mal/custom-id titles.
        let addonImdbId: String? = meta.imdbId
        let imdbId = ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: meta.id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: addonImdbId)
        let tmdbId = ParentalGuideRepositoryKt.extractParentalGuideTmdbId(value: meta.id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideTmdbId(value: id)
        guard imdbId != nil || tmdbId != nil else { return }
        didRequestRatings = true

        ImdbEpisodeRatingsRepository.shared.getEpisodeRatings(imdbId: imdbId, tmdbId: tmdbId) { [weak self] ratings, _ in
            DispatchQueue.main.async {
                guard let self, let ratings else { return }
                // Kotlin Map<Pair<Int, Int>, Double> — unwrap the KotlinPair keys defensively
                // (generics erase across the ObjC bridge).
                var mapped: [String: Double] = [:]
                for (key, value) in ratings {
                    guard let season = (key.first as? KotlinInt)?.value,
                          let episode = (key.second as? KotlinInt)?.value else { continue }
                    mapped["\(season):\(episode)"] = value.doubleValue
                }
                self.episodeRatings = mapped
            }
        }
    }

    // MARK: - Parental guide

    /// Once per title: IMDb parents-guide severities, mapped to display chips via the shared
    /// `buildParentalWarnings` (labels supplied here — tvOS is English-only).
    private func fetchParentalGuideIfNeeded(_ meta: MetaDetails) {
        guard !didRequestGuide else { return }
        let addonImdbId: String? = meta.imdbId
        guard let imdbId = ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: meta.id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: id)
            ?? ParentalGuideRepositoryKt.extractParentalGuideImdbId(value: addonImdbId) else { return }
        didRequestGuide = true

        ParentalGuideRepository.shared.getParentalGuide(imdbId: imdbId) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self, let result else { return }
                self.parentalWarnings = ParentalGuideRepositoryKt.buildParentalWarnings(
                    guide: result,
                    labels: Self.parentalGuideLabels
                )
            }
        }
    }

    static let parentalGuideLabels = ParentalGuideLabels(
        nudity: String(localized: "Nudity"),
        violence: String(localized: "Violence"),
        profanity: String(localized: "Profanity"),
        alcohol: String(localized: "Alcohol & Drugs"),
        frightening: String(localized: "Frightening Scenes"),
        severe: String(localized: "Severe"),
        moderate: String(localized: "Moderate"),
        mild: String(localized: "Mild")
    )

    // MARK: - Actions

    /// DET-2: the series-aware toggle mobile's Detail runs. A loaded series goes through the shared
    /// `WatchingActions.toggleSeriesWatched`: it marks — or clears — every released main-season
    /// episode along with the series marker, so the episode badges and the Resume / Up Next action
    /// follow, and (upstream ba7862154 keeps series-level marks away from Simkl, which would stamp
    /// every episode of the show) the episode marks are what sync. A page still loading goes through
    /// `togglePosterWatched`, which fetches the details itself. A movie toggles its own mark. Filed
    /// under the meta's identity (DET-1). A mark left under the preview's id before the meta
    /// resolved is cleared as such.
    func toggleWatched() {
        guard !watchedToggleInFlight else { return }
        if let previewIdentity = previewIdentityIfDistinct,
           !isTitleWatched(id: contentId, type: contentType),
           isTitleWatched(id: previewIdentity.id, type: previewIdentity.type) {
            WatchedRepository.shared.unmarkWatched(item: preview.toWatchedItem(markedAtEpochMs: 0))
            return
        }
        if let meta, EpisodesSection.isSeriesLike(meta) {
            // Details already loaded: no second fetch, the toggle applies at once.
            WatchingActions.shared.toggleSeriesWatched(meta: meta)
        } else if meta == nil {
            // Details still loading: the poster action fetches them first — ignore presses until it
            // has applied.
            watchedToggleInFlight = true
            WatchingActions.shared.togglePosterWatched(preview: preview) { [weak self] _ in
                DispatchQueue.main.async { self?.watchedToggleInFlight = false }
            }
        } else {
            WatchedRepository.shared.toggleWatched(item: watchedPreview.toWatchedItem(markedAtEpochMs: 0))
        }
    }

    /// Title-level watched: its own mark, or (series) every released episode watched.
    private func isTitleWatched(id: String, type: String) -> Bool {
        WatchedRepository.shared.isWatched(id: id, type: type, season: nil, episode: nil)
            || WatchedRepository.shared.isFullyWatchedSeries(id: id, type: type)
    }

    /// The title as a catalog preview under the meta's identity (DET-1) — what the movie toggle
    /// files its mark under. The catalog preview itself until the meta resolves.
    private var watchedPreview: MetaPreview {
        guard let meta else { return preview }
        return MetaPreview(
            id: meta.id,
            type: meta.type,
            name: meta.name,
            poster: meta.poster ?? preview.poster,
            banner: meta.background ?? preview.banner,
            logo: meta.logo ?? preview.logo,
            posterShape: preview.posterShape,
            description: meta.description_ ?? preview.description_,
            releaseInfo: meta.releaseInfo ?? preview.releaseInfo,
            rawReleaseDate: preview.rawReleaseDate,
            popularity: preview.popularity,
            voteCount: preview.voteCount,
            imdbRating: meta.imdbRating ?? preview.imdbRating,
            genres: meta.genres.isEmpty ? preview.genres : meta.genres
        )
    }

    /// Toggle library membership. Prefers the enriched `meta`, falling back to the preview card.
    /// `toLibraryItem` is a Kotlin extension → Swift instance method; the repo stamps
    /// `savedAtEpochMs` itself, so we pass 0.
    func toggleLibrary() {
        // DET-1: saved under the preview's id only (before its meta resolved) → remove THAT entry;
        // toggling the meta's id would add a duplicate instead.
        if let previewIdentity = previewIdentityIfDistinct,
           !LibraryRepository.shared.isSaved(id: contentId, type: contentType),
           LibraryRepository.shared.isSaved(id: previewIdentity.id, type: previewIdentity.type) {
            LibraryRepository.shared.toggleSaved(item: preview.toLibraryItem(savedAtEpochMs: 0))
            return
        }
        let item: LibraryItem = meta.map { $0.toLibraryItem(savedAtEpochMs: 0) }
            ?? preview.toLibraryItem(savedAtEpochMs: 0)
        LibraryRepository.shared.toggleSaved(item: item)
    }

    private func refreshFlags() {
        // DET-2: a series whose released episodes are all watched counts as watched too. Read under
        // the meta's identity — the one `toggleSeriesWatched` reads and writes — and the preview's.
        isWatched = isTitleWatched(id: contentId, type: contentType)
            || previewIdentityIfDistinct.map { isTitleWatched(id: $0.id, type: $0.type) } == true
        isSaved = LibraryRepository.shared.isSaved(id: contentId, type: contentType)
            || previewIdentityIfDistinct.map { LibraryRepository.shared.isSaved(id: $0.id, type: $0.type) } == true
        watchedEpisodeKeys = computeWatchedEpisodeKeys()
        let progress = computeEpisodeProgress(excluding: watchedEpisodeKeys)
        if progress != episodeProgress { episodeProgress = progress }
        seriesAction = computeSeriesAction()
        let movieResume = computeMovieHasResumePoint()
        if movieResume != movieHasResumePoint { movieHasResumePoint = movieResume }
        let playable = computePlaybackAvailability()
        if playable != isPlaybackAvailable { isPlaybackAvailable = playable }
        reconcileSeriesWatchedStateIfNeeded()
    }

    /// DET-2 (mobile MetaDetailsScreen parity): re-derives the series-level watched state — the
    /// series marker and the fully-watched flag — from its episodes, so a series finished episode by
    /// episode (here before this build, or on another device) reads as Watched, and a marker a newly
    /// released episode made stale is dropped (else "Watched" → press → clears the whole history).
    /// The shared call is idempotent; it runs again only when its inputs moved: the watched state,
    /// this series' episode completions (not the positions a playback tick moves), the day.
    private func reconcileSeriesWatchedStateIfNeeded() {
        guard let meta, EpisodesSection.isSeriesLike(meta), watchedStateLoaded, progressRemoteLoaded,
              !watchedToggleInFlight else { return }
        // A meta without its episode list (an add-on that sends none) proves nothing — reconciling
        // against it would drop the viewer's own series mark, and sync that removal.
        guard meta.videos.contains(where: { EpisodesSection.normalizeSeasonNumber($0.season) > 0 }) else { return }
        let today = CurrentDateProvider.shared.todayIsoDate()
        let completions = latestProgressEntries
            .filter { $0.parentMetaId == meta.id }
            .map { (entry: WatchProgressEntry) -> String in
                let season = entry.seasonNumber?.value ?? -1
                let episode = entry.episodeNumber?.value ?? -1
                return "\(season):\(episode):\(entry.isCompleted ? 1 : 0)"
            }
            .sorted()
            .joined(separator: ",")
        let signature = "\(meta.type)|\(meta.id)|\(meta.videos.count)|\(today)|\(watchedStateVersion)|\(completions)"
        guard signature != lastReconcileSignature else { return }
        lastReconcileSignature = signature
        WatchingActions.shared.reconcileSeriesWatchedState(meta: meta, todayIsoDate: today)
    }

    /// The primary Play target as Detail requests it — the series action's episode, else the
    /// movie under the meta's id — checked once the meta has resolved (a press before that is
    /// covered by the stream repository's own tmdb → IMDb retry).
    private func computePlaybackAvailability() -> Bool {
        guard let meta else { return true }
        if EpisodesSection.isSeriesLike(meta) {
            guard let action = seriesAction else { return true }
            return StreamSourceAvailability.shared.canStream(type: meta.type, videoId: action.videoId)
        }
        return StreamSourceAvailability.shared.canStream(type: preview.type, videoId: meta.id)
    }

    /// EP-2: mark / unmark one episode (mobile's episode long-press, shared
    /// `WatchingActions.toggleEpisodeWatched`). "Watched" is what the badge shows — an explicit mark
    /// or a completed playback; the shared action clears the episode's progress either way and
    /// re-derives the series-level marker.
    func toggleEpisodeWatched(_ episode: MetaVideo) {
        guard let meta, let s = episode.season?.value, let e = episode.episode?.value else { return }
        WatchingActions.shared.toggleEpisodeWatched(
            meta: meta,
            episode: episode,
            isCurrentlyWatched: watchedEpisodeKeys.contains("\(s):\(e)")
        )
    }

    /// The latest progress record per episode of this series (under the meta's id, DET-1), kept
    /// when it is still in progress.
    private func computeEpisodeProgress(excluding watched: Set<String>) -> [String: Double] {
        guard let meta, EpisodesSection.isSeriesLike(meta) else { return [:] }
        let id = meta.id
        var latest: [String: WatchProgressEntry] = [:]
        for entry in latestProgressEntries where entry.parentMetaId == id {
            guard let s = entry.seasonNumber?.value, let e = entry.episodeNumber?.value else { continue }
            let key = "\(s):\(e)"
            if let existing = latest[key], existing.lastUpdatedEpochMs >= entry.lastUpdatedEpochMs { continue }
            latest[key] = entry
        }
        var result: [String: Double] = [:]
        for (key, entry) in latest where !watched.contains(key) && !entry.isEffectivelyCompleted {
            let fraction = Double(entry.progressFraction)
            if fraction > 0.01 && fraction < 1 { result[key] = fraction }
        }
        return result
    }

    /// Hydrates Trakt-sourced per-episode completion for this title (no-op/cached otherwise), once
    /// per content id — again when the meta's id turns out to differ from the preview's (DET-1).
    private func refreshEpisodeProgressIfNeeded() {
        let target = contentId
        guard episodeProgressRequestedFor != target else { return }
        episodeProgressRequestedFor = target
        WatchProgressRepository.shared.refreshEpisodeProgress(contentId: target, forceRefresh: false)
    }

    /// PLY-A13: the player's own resume gate (`PlaybackProgressRecorder.resumePositionSec`): an
    /// unfinished record under the meta's id, more than 10 s in (or a percentage-only row).
    private func computeMovieHasResumePoint() -> Bool {
        if let meta, EpisodesSection.isSeriesLike(meta) { return false }
        guard let entry = WatchProgressRepository.shared.progressForVideo(
            videoId: contentId,
            parentMetaId: contentId,
            seasonNumber: nil,
            episodeNumber: nil
        ), !entry.isCompleted, !entry.isEffectivelyCompleted else { return false }
        if entry.lastPositionMs > 10_000 { return true }
        return entry.lastPositionMs <= 0 && entry.durationMs <= 0 && Double(entry.progressFraction) > 0.01
    }

    /// Mirrors mobile's Detail screen: shared `seriesPrimaryAction` over the full progress +
    /// watched state (resume beats next-up; first released episode — or the addon's
    /// behaviorHints.defaultVideoId — for a fresh series; upstream 2b8be69cd: a series watched to
    /// its last released episode plays again from the first one instead of offering nothing).
    private func computeSeriesAction() -> SeriesPrimaryAction? {
        guard let meta, EpisodesSection.isSeriesLike(meta) else { return nil }
        return meta.seriesPrimaryAction(
            entries: latestProgressEntries,
            watchedItems: latestWatchedItems,
            todayIsoDate: CurrentDateProvider.shared.todayIsoDate(),
            preferFurthestEpisode: latestCwPrefs?.upNextFromFurthestEpisode ?? true,
            showUnairedNextUp: latestCwPrefs?.showUnairedNextUp ?? false,
            allowRewatch: true
        )
    }

    /// "season:episode" keys for every episode that is explicitly marked watched or whose watch
    /// progress is effectively complete. Pure in-memory lookups against the shared repositories,
    /// under the loaded meta's id and, when it differs, the catalog preview's too.
    private func computeWatchedEpisodeKeys() -> Set<String> {
        guard let meta, EpisodesSection.isSeriesLike(meta) else { return [] }
        // DET-1: the meta's identity — what playback records progress and completion marks under —
        // and, when it differs, the catalog preview's.
        var owners: [(id: String, type: String)] = [(meta.id, meta.type)]
        if let previewIdentity = previewIdentityIfDistinct { owners.append(previewIdentity) }
        var keys: Set<String> = []
        for episode in meta.videos {
            guard let s = episode.season?.value, let e = episode.episode?.value else { continue }
            let season = KotlinInt(int: Int32(s))
            let number = KotlinInt(int: Int32(e))
            let watched = owners.contains { owner in
                WatchedRepository.shared.isWatched(id: owner.id, type: owner.type, season: season, episode: number)
                    || WatchProgressRepository.shared.progressForVideo(
                        videoId: "\(owner.id):\(s):\(e)",
                        parentMetaId: owner.id,
                        seasonNumber: season,
                        episodeNumber: number
                    )?.isEffectivelyCompleted == true
            }
            if watched { keys.insert("\(s):\(e)") }
        }
        return keys
    }

    deinit {
        detailWatcher?.cancel()
        watchedWatcher?.cancel()
        fullyWatchedWatcher?.cancel()
        libraryWatcher?.cancel()
        addonsWatcher?.cancel()
        pluginsWatcher?.cancel()
        progressWatcher?.cancel()
        cwPrefsWatcher?.cancel()
        ratingsSettingsWatcher?.cancel()
    }
}

/// One resolved trailer ready for full-screen playback (`id` keys the presenting cover).
struct TrailerPlaybackItem: Identifiable {
    let id: String
    let url: String
    let title: String
    /// C3 (2026-08-30 investigation): the identity `TrailerLetterboxProbe`/`TrailerZoomCache`
    /// remembers this clip's measured letterbox zoom under. The Detail hero "Watch Trailer" button
    /// and the auto-play item play the SAME video the Detail hero background loop does, so they use
    /// the canonical title key (`DetailViewModel.trailerZoomKey`) and correctly share its entry.
    /// Every "Trailers & Extras" row clip (`DetailViewModel.playTrailer(_:)`) is a DIFFERENT stream
    /// of the same title, and used to collide on that one title-keyed entry — opening a row clip
    /// right after the hero (or vice versa) inherited whichever measurement ran last, then visibly
    /// re-zoomed mid-playback once its own probe landed. Row clips get their own per-trailer-id key.
    let zoomKey: String
    /// BUG-81: the YouTube video id this clip's stream was extracted from. See
    /// `TrailerHeroPlayer.videoId`; nil is a supported fallback, not an error.
    var videoId: String? = nil
}
