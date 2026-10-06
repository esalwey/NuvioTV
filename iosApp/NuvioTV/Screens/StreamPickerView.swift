import SwiftUI
import SharedCore

/// Presented when the user taps Play. Resolves streams for the title, lists the playable ones
/// grouped by addon, and opens the native player on selection.
///
/// Debrid: torrent/`clientResolve` results from installed addons (no direct URL) are listed when
/// in-app debrid resolution is enabled, and resolve to a direct link at click time through the
/// shared `DirectDebridPlaybackResolver` (mobile parity: `App.kt:2157`, `StreamsScreen.kt:363`).
/// Failures surface as a transient toast using the same wording as the shared `toastMessage()`.
///
/// Badges: rows render imported badge-pack chips, the file-size chip, TOP/BOTTOM placement, the
/// optional addon logo and the "- <Provider> Instant" cached suffix (mobile `StreamCard` parity).
///
/// Grouping: each addon's streams sit under a collapsed-by-default, focusable header (name,
/// stream count, per-addon loading spinner). Rows only build while their group is expanded — a
/// `LazyVStack` throughout — so the picker no longer lags while addons are still resolving
/// (previously every addon's rows were built eagerly in one long always-expanded list). F10: the
/// first addon in install order with playable streams auto-expands once; the rest stay collapsed
/// until picked, and nothing auto-collapses/re-expands as later addons stream in. Every stream row
/// has one fixed height; the focused row's full release name sits in a footer under the list.
///
/// STAB-07: a Best Match row is pinned above the groups (the source last played for this title,
/// else the best quality once every addon has answered), and each group header carries a quality
/// summary. STAB-04: addons that failed or timed out (15 s) stay listed, dimmed, with Retry.
///
/// STREAM-INSIGHT: rows no longer print the add-on's raw title. The shared parser reads it
/// (`StreamInsightParser`) and each row shows a quality line ("4K · Dolby Vision · Atmos"), audio
/// chips with the French version visible (VFF / VFQ / VF), subtitle chips, size, cache state and
/// source/provider; the original title stays one line below and in full in the footer, with the
/// reasons behind the ranking. Each group is sorted best-first for the viewer's preferences
/// (Settings → Playback → Stream Recommendations); the pinned row is the "Recommended" pick.
///
/// Focus: rows and group headers carry stable focus keys. Initial focus lands on the first
/// group's header (its first row when that group auto-expanded), then moves to the Best Match row
/// when it appears — never away from a row the user moved to. Collapsing a group that holds focus
/// retargets focus to that group's header first. STAB-03: while the player is up the list is
/// kept (`detach()`), and Back from the player returns focus to the row that was played.
struct StreamPickerView: View {
    let type: String

    let parentMetaId: String
    /// All episodes of the parent series (from `MetaDetails.videos`); enables next-episode
    /// autoplay in the player. Empty for movies or launch paths without the series meta.
    let episodes: [MetaVideo]
    /// Info-tab header input (optional). The catalog/series poster (also persisted as the parent
    /// artwork by the progress recorder).
    let poster: String?
    /// Title-level facts for the player's Info tab chips (nil when the caller has no meta).
    let meta: PlaybackMeta?
    /// CW-1: what the watch-progress record is filed under — the series name (`title` is the
    /// episode label for an episode), plus the title's backdrop and logo. See `PlaybackContext`.
    let seriesTitle: String?
    let background: String?
    let logo: String?

    /// The episode this picker lists streams for. It starts as the one the picker was opened for;
    /// "Choose a Source" on the player's end screen moves it to the NEXT episode (`retarget(to:)`)
    /// instead of stacking another picker on top.
    private struct Target: Equatable {
        /// STAB-02: the watch-progress key (`parent:season:episode` for an episode) — what the
        /// player records progress under and the resume lookups query.
        var videoId: String
        /// STAB-02: the id the stream addons are asked with — the episode's own `MetaVideo.id`
        /// (kitsu/anime catalogs don't follow `parent:season:episode`). Same as `videoId` for
        /// movies and IMDb series.
        var streamVideoId: String
        /// The caller named `streamVideoId` itself (no later re-derivation from the episode list).
        var streamVideoIdExplicit: Bool
        var title: String
        var season: Int?
        var episode: Int?
        /// 16:9 episode image for the Info-tab header, shown in preference to `poster`.
        var episodeStill: String?
        var synopsis: String?
        /// The episode's own name (CW-1: recorded beside the series name).
        var episodeTitle: String?
    }
    @State private var target: Target
    private var videoId: String { target.videoId }
    private var title: String { target.title }
    private var season: Int? { target.season }
    private var episode: Int? { target.episode }
    private var episodeStill: String? { target.episodeStill }
    private var synopsis: String? { target.synopsis }

    /// CW-1: the series identity fetched with the episode list on the paths that start from a
    /// progress record (Continue Watching, the Top Shelf). Those can only hand over what the record
    /// holds — a name that builds before CW-1 wrote as the episode label, and often no artwork.
    private struct FetchedSeries: Equatable {
        var name: String?
        var background: String?
        var logo: String?
    }
    @State private var fetchedSeries: FetchedSeries?

    /// Presenters that are not the title's details page (Home's Continue Watching, a Top Shelf deep
    /// link) open it once this picker has closed after the player asked for the details page —
    /// the Up Next cancel, "Back to Details", the end of a movie or finale. nil = the presenter IS
    /// the details page (Detail, its episode list).
    let onLeaveToDetails: (() -> Void)?
    /// Start Over (PLY-A13): the Detail page's "Start from Beginning" or the Continue Watching
    /// card's. Every stream picked for the episode this picker was opened for plays from 0:00
    /// (`PlaybackContext.startingOver()`); another episode it is retargeted to plays as usual.
    private let startFromBeginning: Bool
    private let startOverVideoId: String

    @StateObject private var model: StreamsViewModel
    @State private var selected: PlaybackContext?
    /// Autoplay (or a panel jump) took playback past the episode this picker lists: closing the
    /// player then leaves for the details page too — never back onto this stale list, where one
    /// Select would replay the old episode (NE-4/NEXT-1).
    @State private var autoAdvanced = false
    /// The player asked for the details page and this picker is closing with it. Normally the one
    /// `dismiss()` takes the picker and everything it presents down in one transition; should only
    /// the player cover close, its `onDismiss` then closes the picker (never leaving it on screen).
    @State private var exitToDetailsPending = false
    /// Episodes fetched on demand when a series launch path didn't supply them (Home
    /// continue-watching, Detail's primary Play). Filled from `MetaDetailsRepository.fetch`
    /// (cache-first, side-effect free) so next-episode autoplay works from every path.
    @State private var fetchedEpisodes: [MetaVideo] = []
    /// The title's name, logo and backdrop for the header (AES-3) — see `loadHeaderArt()`.
    @State private var headerArt: CachedTitleArt?
    /// Row key currently mid debrid-resolve (drives the row spinner; one resolve at a time).
    @State private var resolvingKey: String?
    /// Transient failure message (debrid resolve errors), auto-dismissed after a few seconds.
    @State private var toast: String?
    @FocusState private var focusedRow: String?
    /// The key focus was last moved to by the picker itself (initial focus). While focus still
    /// sits there, the Best Match row may take it when it appears (spec §6.8 default focus).
    @State private var autoFocusedKey: String?
    /// STAB-03: the row whose stream is playing, to put focus back on when the player closes.
    @State private var lastPlayedRowKey: String?
    /// STAB-06: bumped by every debrid resolve start, timeout, retarget and player presentation,
    /// so a resolve that answers late (after its timeout, or for a list that has moved on) is
    /// dropped instead of opening the player out of nowhere.
    @State private var resolveGeneration = 0
    /// F10: one fixed height for every stream row (scales with the text size), so moving down the
    /// list never shifts the rows below. The full release name of the focused row is shown in the
    /// footer under the list instead of growing the row (the old BUG-16 behaviour).
    @ScaledMetric(relativeTo: .body) private var streamRowHeight: CGFloat = 184
    @ScaledMetric(relativeTo: .caption2) private var focusedNameFooterHeight: CGFloat = 96
    /// Addon ids whose group is currently expanded. Collapsed (absent) by default; see
    /// `body`'s F10 auto-expand (`model.autoExpandGroupId`) and `toggleExpansion(_:)`.
    @State private var expandedGroups: Set<String> = []
    /// Guards the one-time auto-expand check so a second addon streaming in later never
    /// collapses/re-expands anything under the user (no layout shifts under focus).
    @State private var didAutoExpand = false
    /// External players installed on this Apple TV (FEAT-5). Probed once per appearance via the
    /// shared `ExternalPlayerPlatform` — `canOpenURL` only returns true for schemes declared in
    /// Info.plist's `LSApplicationQueriesSchemes` (Infuse, VLC, Outplayer, VidHub as of FEAT-21),
    /// so testers without any of them installed never see the handoff option at all. Empty ⇒ no
    /// menu is attached.
    @State private var externalPlayers: [ExternalPlayerApp] = []
    /// User-chosen default player (Settings → Playback → Default Player). Empty = built-in.
    /// Same device-local key `DefaultPlayerRow` writes; validated against the live probe below
    /// so an uninstalled default silently reverts to built-in instead of dead-ending playback.
    @AppStorage("default_external_player_id") private var defaultExternalPlayerId = ""
    @Environment(\.dismiss) private var dismiss

    /// Focus key of the DEBUG-only test-stream button (`devTestStreamButton`).
    private static let testRowKey = "test-stream"

    /// - Parameters:
    ///   - videoId: the watch-progress key (STAB-02).
    ///   - streamVideoId: the id to ask the stream addons with; nil = derive it from the episode
    ///     list when there is one (an episode's own `MetaVideo.id`), else `videoId`.
    init(
        type: String,
        videoId: String,
        streamVideoId: String? = nil,
        title: String,
        parentMetaId: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        episodes: [MetaVideo] = [],
        poster: String? = nil,
        episodeStill: String? = nil,
        synopsis: String? = nil,
        meta: PlaybackMeta? = nil,
        seriesTitle: String? = nil,
        episodeTitle: String? = nil,
        background: String? = nil,
        logo: String? = nil,
        startFromBeginning: Bool = false,
        onLeaveToDetails: (() -> Void)? = nil
    ) {
        self.startFromBeginning = startFromBeginning
        self.startOverVideoId = videoId
        self.meta = meta
        self.poster = poster
        // A progress-record launch hands over what the record holds, which builds before CW-1
        // wrote as the episode label: such a label is dropped here (the fetched name stands in).
        self.seriesTitle = seriesTitle.flatMap {
            ProgressRecordTitles.seriesTitle($0, season: season, episode: episode)
        }
        self.background = background
        self.logo = logo
        self.onLeaveToDetails = onLeaveToDetails
        self.type = type
        self.parentMetaId = parentMetaId ?? videoId
        self.episodes = episodes
        let resolvedStreamId = streamVideoId
            ?? Self.derivedStreamVideoId(progressVideoId: videoId, parentMetaId: parentMetaId ?? videoId,
                                         season: season, episode: episode, episodes: episodes)
            ?? videoId
        _target = State(initialValue: Target(
            videoId: videoId, streamVideoId: resolvedStreamId, streamVideoIdExplicit: streamVideoId != nil,
            title: title, season: season, episode: episode,
            episodeStill: episodeStill, synopsis: synopsis, episodeTitle: episodeTitle
        ))
        _model = StateObject(wrappedValue: StreamsViewModel(
            type: type, videoId: videoId, streamVideoId: resolvedStreamId, parentMetaId: parentMetaId,
            season: season, episode: episode
        ))
    }

    /// STAB-02: the addon-facing id of an episode launched by its progress key. Only when the key
    /// is the synthesized `parent:season:episode` form and the episode is in the list: the
    /// episode's own id (`NextEpisodeEngine.streamQueryVideoId`, mobile parity). nil otherwise —
    /// the key is then used as is, as before.
    private static func derivedStreamVideoId(progressVideoId: String, parentMetaId: String, season: Int?,
                                             episode: Int?, episodes: [MetaVideo]) -> String? {
        guard let season, let episode,
              progressVideoId == "\(parentMetaId):\(season):\(episode)",
              let video = episodes.first(where: { $0.season?.value == season && $0.episode?.value == episode })
        else { return nil }
        return NextEpisodeEngine.streamQueryVideoId(metaId: parentMetaId, episode: video)
    }

    private func context(url: URL, stream: StreamItem?) -> PlaybackContext {
        let built = PlaybackContext(
            url: url,
            title: title,
            contentType: type,
            parentMetaId: parentMetaId,
            videoId: videoId,
            season: season,
            episode: episode,
            poster: poster,
            background: Self.nonEmpty(background) ?? fetchedSeries?.background,
            providerName: stream?.addonName,
            providerAddonId: stream?.addonId,
            streamTitle: stream.map { $0.streamLabel },
            streamSubtitle: { let s: String? = stream?.description_; return s }(),
            externalSubtitles: (stream?.externalSubtitles ?? []).map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            },
            bingeGroup: { let bg: String? = stream?.behaviorHints.bingeGroup; return bg }(),
            episodes: episodes.isEmpty ? fetchedEpisodes : episodes,
            synopsis: synopsis,
            episodeStill: episodeStill,
            meta: meta,
            fileSizeBytes: { let n: Int64? = stream?.behaviorHints.videoSize?.int64Value; return n }(),
            requestHeaders: StreamModelsKt.sanitizePlaybackHeaders(
                headers: stream?.behaviorHints.proxyHeaders?.request),
            seriesTitle: resolvedSeriesTitle,
            episodeTitle: Self.nonEmpty(target.episodeTitle),
            logo: Self.nonEmpty(logo) ?? fetchedSeries?.logo
        )
        return startFromBeginning && videoId == startOverVideoId ? built.startingOver() : built
    }

    /// CW-1: the series name the progress record is filed under — the caller's (legacy episode
    /// labels already dropped in `init`), else the one fetched with the episode list, else — a
    /// stream picked before that fetch landed — the metadata cache's.
    private var resolvedSeriesTitle: String? {
        if let seriesTitle { return seriesTitle }
        if let name = fetchedSeries?.name { return name }
        guard season != nil, episode != nil else { return nil }
        return ProgressRecordTitles.cachedSeriesName(type: type, id: parentMetaId)
    }

    /// Kotlin-bridged optional strings: blank counts as missing.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Series launch paths that don't carry the episode list (Home continue-watching, Detail's
    /// primary Play) get it fetched here so the player can offer next-episode autoplay. No-op for
    /// movies and for paths that already passed `episodes` (EpisodesSection). The series name and
    /// artwork come along for the progress record (CW-1).
    private func fetchEpisodesIfNeeded() {
        guard needsEpisodeFetch else { return }
        MetaDetailsRepository.shared.fetch(type: type, id: parentMetaId, cacheResult: true) { details, _ in
            guard let details else { return }
            let videos = details.videos
            let name: String = details.name
            let backdrop: String? = details.background
            let logo: String? = details.logo
            // Suspend completions can land off-main; hop before mutating view state.
            DispatchQueue.main.async {
                // The header art comes from the same record (`loadHeaderArt` leaves it to this
                // fetch), kept for the player chrome too (`CachedTitleArt.remember`).
                let art = CachedTitleArt.remember(details, type: type, id: parentMetaId)
                if headerArt == nil { headerArt = art }
                if !videos.isEmpty {
                    fetchedEpisodes = videos
                    adoptDerivedStreamVideoId(episodes: videos)
                }
                model.setOriginalLanguage(currentOriginalLanguage)
                // CW-1: the series name and artwork for the progress record.
                fetchedSeries = FetchedSeries(
                    name: Self.nonEmpty(name),
                    background: Self.nonEmpty(backdrop),
                    logo: Self.nonEmpty(logo)
                )
            }
        }
    }

    /// STAB-02: a launch from a progress record (Continue Watching, Top Shelf) carries only the
    /// progress key. Once the episode list arrives, an episode whose own id differs from that key
    /// (kitsu and other anime catalogs) is asked for again under its own id — the first request,
    /// under the key, finds nothing on those addons. A no-op for IMDb series, where they match.
    private func adoptDerivedStreamVideoId(episodes: [MetaVideo]) {
        guard !target.streamVideoIdExplicit, selected == nil,
              let derived = Self.derivedStreamVideoId(progressVideoId: target.videoId, parentMetaId: parentMetaId,
                                                      season: target.season, episode: target.episode,
                                                      episodes: episodes),
              derived != target.streamVideoId else { return }
        target.streamVideoId = derived
        resetListState()
        model.retarget(videoId: target.videoId, streamVideoId: derived,
                       season: target.season, episode: target.episode)
    }

    /// View state that belongs to one stream list (cleared whenever the list is re-targeted).
    private func resetListState() {
        resolveGeneration += 1
        resolvingKey = nil
        expandedGroups = []
        didAutoExpand = false
        focusedRow = nil
        autoFocusedKey = nil
        lastPlayedRowKey = nil
    }

    /// STREAM-INSIGHT: the title's original language (launch meta, else the meta cache).
    private var currentOriginalLanguage: String? {
        StreamOriginalLanguage.resolve(meta: meta, type: type, parentMetaId: parentMetaId)
    }

    /// A series launch path without the episode list (see `fetchEpisodesIfNeeded`).
    private var needsEpisodeFetch: Bool {
        episodes.isEmpty && fetchedEpisodes.isEmpty
            && ["series", "tv", "show", "tvshow"].contains(type.lowercased())
    }

    /// AES-3: the title's name, logo, backdrop and facts for the header — from the shared meta
    /// cache when the Details page already loaded it, else from one cache-first fetch (Home's
    /// Continue Watching, a Top Shelf resume). A series without its episode list gets it from the
    /// fetch `fetchEpisodesIfNeeded` makes anyway, never a second one. Either way the record is
    /// kept for the player chrome (`CachedTitleArt`), which reads it after Details has cleared the
    /// shared cache.
    private func loadHeaderArt() {
        if let cached = CachedTitleArt.peek(type: type, id: parentMetaId) {
            headerArt = cached
            return
        }
        guard !needsEpisodeFetch else { return }
        MetaDetailsRepository.shared.fetch(type: type, id: parentMetaId, cacheResult: true) { details, _ in
            guard let details else { return }
            DispatchQueue.main.async {
                headerArt = CachedTitleArt.remember(details, type: type, id: parentMetaId)
                model.setOriginalLanguage(currentOriginalLanguage)
            }
        }
    }

    var body: some View {
        NavigationStack {
            // AES-3: the title's artwork and an episode/movie header on the left, the addon list on
            // a panel on the right — it was one full-width column of text on flat #0D0D0D, with the
            // series name nowhere and poster/still/synopsis passed in but never drawn.
            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                headerColumn
                listPanel
            }
            .padding(.horizontal, Theme.Spacing.screen)
            .padding(.vertical, Theme.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { ArtworkBackdrop(url: backdrop.url, blurRadius: backdrop.blurRadius) }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                        .background(Theme.Surface.overlay, in: Capsule())
                        .padding(.bottom, Theme.Spacing.xl)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: model.autoExpandGroupId) { _, groupId in
                // F10: expand the first addon in install order that has playable streams, exactly
                // once. Never re-evaluated afterward, so an addon streaming in later doesn't
                // collapse or expand anything under the user.
                guard let groupId, !didAutoExpand else { return }
                didAutoExpand = true
                expandedGroups.insert(groupId)
                // Its first row takes initial focus when it is also the top group.
                if groupId == model.groups.first?.id, let firstKey = model.firstRowKey {
                    moveInitialFocus(to: firstKey)
                }
            }
            .onChange(of: model.groups.map(\.id)) { _, ids in
                // Initial focus once groups (first) arrive: the first group's header (its first
                // row once auto-expanded, above). Never steals focus after the user has moved it.
                guard let firstId = ids.first else { return }
                if expandedGroups.contains(firstId), let firstKey = model.firstRowKey {
                    moveInitialFocus(to: firstKey)
                } else {
                    moveInitialFocus(to: Self.headerKey(groupId: firstId))
                }
            }
            .onChange(of: model.failedGroups.map(\.id)) { oldIds, newIds in
                followRetriedGroup(oldFailedIds: oldIds, newFailedIds: newIds)
            }
            .onChange(of: model.bestMatch?.stream) { _, stream in
                // Spec §6.8: default focus is the recommended row — taken from the initial focus
                // only, never from a row or header the user moved to.
                guard stream != nil else { return }
                moveInitialFocus(to: StreamsViewModel.bestMatchRowKey)
            }
            .onChange(of: expandedGroups) { _, ids in
                // STREAM-INSIGHT: an open group keeps its row order under focus.
                model.setExpandedGroups(ids)
            }
            .onAppear {
                loadHeaderArt()
                model.setOriginalLanguage(currentOriginalLanguage)
                model.start()
                fetchEpisodesIfNeeded()
                // Main-thread only (UIApplication.canOpenURL); cheap enough to re-probe every
                // appearance so an Infuse install mid-session is picked up next time the picker
                // opens instead of requiring an app relaunch.
                externalPlayers = ExternalPlayerPlatform.shared.availablePlayers()
                // Head start for the player: addon subtitles for this title begin fetching while
                // the user is still choosing a stream, so the native path's pre-master window
                // (and the mpv side-load) see results instead of racing the network. The player's
                // own fetch call deduplicates against this one.
                SubtitleRepository.shared.fetchAddonSubtitles(type: type, videoId: videoId)
            }
            .onDisappear {
                // STAB-03: the player cover hides this view too. Keep the list (detach) while it
                // is up; clear it only when the picker itself goes away.
                if selected != nil {
                    model.detach()
                } else {
                    model.stop()
                }
            }
            .onChange(of: selected?.id) { _, id in
                // STAB-06: a player going up (or swapping) orphans any resolve still running.
                if id != nil {
                    resolveGeneration += 1
                    resolvingKey = nil
                }
            }
            .fullScreenCover(item: $selected, onDismiss: {
                // A real close of the player — an autoplay swap already holds the next context.
                // After an autoplay chain, go back to the details page, not to this picker; and
                // an exit to the details page never stops on it either (see below).
                guard selected == nil else { return }
                guard autoAdvanced || exitToDetailsPending else {
                    // STAB-03: back on the same list — focus returns to the row that was played.
                    restoreFocusAfterPlayback()
                    return
                }
                exitToDetailsPending = false
                model.stop()
                dismiss()
            }) { ctx in
                // `.id(ctx.id)` forces a full player rebuild when autoplay swaps in the next
                // episode's context (a same-position cover would otherwise keep the old libmpv
                // controller and just ignore the new context).
                PlayerScreen(
                    context: ctx,
                    onPlayNext: { next in
                        if next.videoId != target.videoId { autoAdvanced = true }
                        selected = next
                    },
                    // Cancel from the Up Next card / end screen, "Back to Details", the end of a
                    // movie or finale: dismissing the picker takes the player cover (and anything
                    // on it) down in the same transition. Should only the player close, the cover's
                    // `onDismiss` above closes the picker — the details page, never this list.
                    onExitToDetails: {
                        guard !exitToDetailsPending else { return }
                        exitToDetailsPending = true
                        // STAB-03: the picker closes with the player — its detached list goes too.
                        model.stop()
                        onLeaveToDetails?()
                        dismiss()
                    },
                    onPickNextSource: { video in chooseSource(for: video) },
                    onChooseAnotherSource: { chooseAnotherSource(for: ctx) }
                )
                .ignoresSafeArea()
                .id(ctx.id)
            }
        }
    }

    // MARK: - Stream list panel

    /// The addon groups and their rows on a panel material (`Theme.Surface.panel`, the surface the
    /// Theme reserves for this picker), which also keeps them legible over bright artwork.
    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // BUG-21 follow-up: the active debrid credential failed auth on a recent call —
            // without this banner the only symptom is every resolve failing while Settings still
            // says "Connected". Not focusable; purely advisory. Pinned above the list so it can't
            // scroll away while the rows fail.
            if let warning = model.credentialWarning {
                debridWarning(warning)
                    .padding([.horizontal, .top], Theme.Spacing.lg)
            }
            // `emptyReason` is only set once nothing is loading — or while a Retry from this very
            // screen is the only thing out (STAB-04), which keeps the screen and its focus.
            if let reason = model.emptyReason, model.groups.isEmpty {
                emptyState(reason: reason)
            } else {
                streamList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Surface.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }

    private var streamList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                streamListContent
            }
            if !model.groups.isEmpty {
                focusedNameFooter
            }
        }
    }

    private var streamListContent: some View {
        // Lazy so collapsed groups' rows (the overwhelming majority while addons are
        // still streaming in) are never built at all — this was the lag source (BUG-5):
        // a non-lazy VStack built every row of every addon up front.
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
            bestMatchSlot

            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    groupHeader(group)
                    // Collapsed groups render nothing at all (not just off-screen —
                    // absent from the hierarchy), which is what actually kills the lag:
                    // the old always-expanded list built every row of every addon.
                    if expandedGroups.contains(group.id) {
                        LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            ForEach(Array(group.streams.enumerated()), id: \.offset) { index, stream in
                                streamRow(stream, key: StreamsViewModel.rowKey(groupId: group.id, index: index))
                            }
                        }
                        // Rows sit under their addon's name, not under its chevron.
                        .padding(.leading, Self.rowIndent)
                        .padding(.top, Theme.Spacing.xxs)
                    }
                }
                // Each addon group is its own focus section: D-pad up/down navigates
                // between group headers and (when expanded) that group's rows without
                // leaking focus into a sibling group's rows.
                .focusSection()
            }

            // STAB-04: addons that failed, dimmed, each with Retry — after the playable groups.
            if !model.failedGroups.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(model.failedGroups) { failed in
                        failedRow(failed)
                    }
                }
                .focusSection()
            }
        }
        // Inside the scroll content, so a focused row's lift never meets the panel's clip.
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// STAB-07: the Best Match row pinned above the groups. While addons are still answering the
    /// slot holds the "Finding streams…" line at the same height, so the row taking its place
    /// never pushes the list down.
    @ViewBuilder
    private var bestMatchSlot: some View {
        if let best = model.bestMatch {
            streamRow(best.stream, key: StreamsViewModel.bestMatchRowKey,
                      pinnedLabel: best.isLastUsed
                          ? Self.lastUsedLabel
                          : (best.isRecommended ? StreamInsightPresenter.recommendedLabel : Self.bestMatchLabel))
                .focusSection()
        } else if model.isLoading {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Finding streams\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: streamRowHeight, maxHeight: streamRowHeight, alignment: .leading)
        }
    }

    private static var bestMatchLabel: String {
        String(localized: "streams.bestMatch", defaultValue: "Best Match",
               comment: "Source picker: capsule on the recommended stream pinned at the top of the list.")
    }

    private static var lastUsedLabel: String {
        String(localized: "streams.lastUsed", defaultValue: "Last Used",
               comment: "Source picker: capsule on the pinned stream when it is the one this title was last played from.")
    }

    /// F10: the focused row's full release name, under the list. Rows have one fixed height, so
    /// a long name is cut in the row and read here in full. Fixed height: focus moving between
    /// rows never resizes the list above it.
    ///
    /// STREAM-INSIGHT: the original title as the add-on wrote it (emoji removed), under the reasons
    /// the row ranks where it does ("Recommended · VFF · 4K DV · Atmos · Cached").
    private var focusedNameFooter: some View {
        let stream = focusedRow.flatMap { model.stream(forRowKey: $0) }
        let info = stream.flatMap { model.info(for: $0) }
        let name: String = {
            if let raw = info?.rawTitle, !raw.isEmpty { return raw }
            let desc: String? = stream?.description_
            if let desc, !desc.isEmpty { return StreamInsightText.shared.stripEmojiSingleLine(text: desc) }
            return stream.map { StreamInsightText.shared.stripEmojiSingleLine(text: $0.streamLabel) } ?? ""
        }()
        let reasons: String = {
            guard let info, let stream else { return "" }
            var parts: [String] = []
            if model.isTopPick(stream) { parts.append(StreamInsightPresenter.recommendedLabel) }
            if !info.reasons.isEmpty { parts.append(info.reasons) }
            if let caveat = info.caveat { parts.append(caveat) }
            return parts.joined(separator: " \u{00B7} ")
        }()
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if !reasons.isEmpty {
                Text(reasons)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
            }
            Text(name)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(reasons.isEmpty ? 3 : 2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: focusedNameFooterHeight, maxHeight: focusedNameFooterHeight,
               alignment: .topLeading)
        .accessibilityHidden(true)
    }

    // MARK: - Failed addons (STAB-04)

    private static func failedKey(groupId: String) -> String { "failed:\(groupId)" }

    /// One failed addon: "Torrentio: unavailable (HTTP 429)", dimmed until focused, Select retries
    /// that addon alone. The row keeps its place (with a spinner) while the retry runs.
    private func failedRow(_ failed: StreamsViewModel.FailedGroup) -> some View {
        let key = Self.failedKey(groupId: failed.id)
        let retryLabel = String(localized: "streams.addon.retry", defaultValue: "Retry",
                                comment: "Source picker: button on a failed addon row that asks that addon again.")
        return Button {
            model.retry(addonId: failed.id)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(Theme.Font.body)
                    .rowTextColor(secondary: true)
                    .frame(width: Self.chevronWidth, alignment: .center)
                Text(failed.message)
                    .font(Theme.Font.body)
                    .rowTextColor(secondary: true)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.md)
                if failed.isRetrying {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Label(retryLabel, systemImage: "arrow.clockwise")
                        .font(Theme.Font.meta)
                        .rowTextColor()
                }
            }
            .padding(.vertical, Theme.Spacing.xs + 2)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.settingsRow)
        .focused($focusedRow, equals: key)
        .opacity(focusedRow == key ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(failed.message))
        .accessibilityHint(Text(retryLabel))
    }

    /// A failed row whose retry brought streams turns into a group: focus follows it to that
    /// group's header instead of falling to wherever tvOS puts it.
    private func followRetriedGroup(oldFailedIds: [String], newFailedIds: [String]) {
        guard let focusedRow, focusedRow.hasPrefix("failed:") else { return }
        let id = String(focusedRow.dropFirst("failed:".count))
        guard oldFailedIds.contains(id), !newFailedIds.contains(id),
              model.groups.contains(where: { $0.id == id }) else { return }
        DispatchQueue.main.async { self.focusedRow = Self.headerKey(groupId: id) }
    }

    /// AES-6: nothing playable — the reason and where to fix it, centred in the panel, and a Back
    /// button so focus has somewhere to land. That target used to be the developer "Play test
    /// stream (Apple HLS sample)" button, shipped in release builds; it's DEBUG-only now. The
    /// reason keeps full text-primary weight: the debrid/filtered cases are actionable, not a dead
    /// end. Back is deliberately not bound to `focusedRow`, so streams arriving later (a stale-link
    /// reload) still take focus.
    private func emptyState(reason: String) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "play.slash")
                .font(Theme.Font.hero)
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.sm) {
                Text(reason)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let hint = model.emptyReasonHint {
                    Text(hint)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // STAB-04: which addons failed, and a Retry for each (a dead addon is no longer a
            // silent "No streams").
            if !model.failedGroups.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(model.failedGroups) { failed in
                        failedRow(failed)
                    }
                }
                .focusSection()
            }
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.backward")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
            }
            .buttonStyle(.bordered)
            .padding(.top, Theme.Spacing.sm)
            devTestStreamButton
        }
        .frame(maxWidth: 760)
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if DEBUG
    /// Dev/diagnostics affordance (DEBUG builds only): plays Apple's HLS sample through the real
    /// player pipeline. Only reachable from the empty state, so it can never steal initial focus
    /// from a stream list.
    private var devTestStreamButton: some View {
        Button {
            selected = context(url: Self.testStreamURL, stream: nil)
        } label: {
            Label("Play test stream (Apple HLS sample)", systemImage: "play.circle")
                .font(Theme.Font.caption)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xxs)
        }
        .buttonStyle(.bordered)
        .focused($focusedRow, equals: Self.testRowKey)
    }

    private static let testStreamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!
    #else
    private var devTestStreamButton: some View { EmptyView() }
    #endif

    /// AES-11: the debrid-session warning in the Theme's warning amber — tinted fill, a leading
    /// accent bar and body-size text readable at 10 ft (it was caption text on a raw `.yellow`
    /// fill with a hard-coded radius).
    private func debridWarning(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.warning)
            Text(text)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.body)
        .padding(.vertical, Theme.Spacing.md)
        .padding(.leading, Theme.Spacing.lg)
        .padding(.trailing, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.warning.opacity(0.12))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.Palette.warning)
                .frame(width: Theme.Spacing.xxs)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Header (AES-3)

    /// Fixed width of the artwork/header column; the list panel takes the rest, so long release
    /// names (BUG-16) keep most of the screen.
    private static let headerWidth: CGFloat = 520
    private static let logoMaxHeight: CGFloat = 140
    /// The group header's chevron column (`groupHeader`).
    private static let chevronWidth: CGFloat = 20
    /// Stream rows start where their addon's name does: the header's leading padding, its chevron
    /// column and the spacing after it — derived from `groupHeader`'s metrics so the two can't
    /// drift apart.
    private static let rowIndent: CGFloat = Theme.Spacing.sm + chevronWidth + Theme.Spacing.sm

    /// Series · code · episode name for the header, from the launch title, the episode list and
    /// the series record (`headerArt`).
    private var headerTitleParts: PlaybackTitleParts {
        PlaybackTitleParts(launchTitle: title, season: season, episode: episode,
                           seriesName: headerArt?.name,
                           episodes: episodes.isEmpty ? fetchedEpisodes : episodes)
    }

    /// Full-bleed art behind everything: the title's backdrop, else — blurred, since they're
    /// low-resolution at full screen — the episode still or the poster.
    private var backdrop: (url: String?, blurRadius: CGFloat) {
        if let background = headerArt?.background { return (background, 0) }
        return (CachedTitleArt.nonEmpty(episodeStill) ?? CachedTitleArt.nonEmpty(poster), 24)
    }

    /// Not focusable: the list panel holds every control. Logo (or name), then for an episode its
    /// still, "S1 · E4" and name; for a movie its year · runtime · rating; then the synopsis.
    private var headerColumn: some View {
        let parts = headerTitleParts
        return VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            titleArt(name: parts.isEpisode ? parts.series : title)
            if parts.isEpisode {
                if let still = CachedTitleArt.nonEmpty(episodeStill) {
                    CachedAsyncImage(string: still)
                        .frame(width: Self.headerWidth, height: Self.headerWidth * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if let code = parts.code {
                        Text(code)
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    if let line = parts.episodeLine {
                        Text(line)
                            .font(Theme.Font.screenTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2)
                    }
                }
            } else {
                movieFacts
            }
            if let synopsis = CachedTitleArt.nonEmpty(synopsis) {
                Text(synopsis)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(parts.isEpisode ? 4 : 7)
                    // The column's give: an episode's logo, still, code and two-line name come
                    // close to the screen's height (more so in Open Sans), so the synopsis is what
                    // loses lines when they don't all fit — never the name, never past the edge.
                    .layoutPriority(-1)
            }
        }
        .frame(width: Self.headerWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The title logo (the series' for an episode), else its name; nothing for an episode whose
    /// series isn't known yet — the code and episode name below still say what this is.
    @ViewBuilder
    private func titleArt(name: String?) -> some View {
        if let logo = headerArt?.logo {
            // A broken logo falls back to the name (the logo and the name come from one record).
            CachedAsyncImage(string: logo, contentMode: .fit, failure: {
                Self.titleText(name ?? title)
            })
            .frame(maxWidth: Self.headerWidth, maxHeight: Self.logoMaxHeight, alignment: .leading)
            .accessibilityLabel(Text(name ?? title))
        } else if let name {
            Self.titleText(name)
        }
    }

    private static func titleText(_ name: String) -> some View {
        Text(name)
            .font(Theme.Font.hero)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(2)
    }

    /// Year · runtime · IMDb rating for a movie (the same facts the player's Info chips show): the
    /// launch path's `meta`, else the title record's — Home's Continue Watching and a Top Shelf
    /// resume pass no `meta`. Display only: `context()` still hands the player `meta` alone.
    @ViewBuilder
    private var movieFacts: some View {
        let year: String? = CachedTitleArt.nonEmpty(meta?.year) ?? headerArt?.year
        let runtime: String? = CachedTitleArt.nonEmpty(meta?.runtime) ?? headerArt?.runtime
        let rating: String? = CachedTitleArt.nonEmpty(meta?.imdbRating) ?? headerArt?.rating
        if year != nil || runtime != nil || rating != nil {
            HStack(spacing: Theme.Spacing.md) {
                if let year { Text(year) }
                if let runtime { Text(runtime) }
                if let rating {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Theme.Palette.star)
                        Text(rating)
                    }
                }
            }
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: - Next episode's stream list ("Choose a Source" on the player's end screen)

    /// No stream could be auto-selected for the next episode: this picker becomes the next
    /// episode's list and the player closes onto it. Back from here then returns to details.
    private func chooseSource(for video: MetaVideo) {
        retarget(to: video)
        selected = nil
    }

    /// The player couldn't play the picked stream (its error card, PLY-1): close it onto a list of
    /// the playing episode's streams — this one, or, for an episode autoplay reached, this picker
    /// retargeted to it (its list here is a previous episode's).
    private func chooseAnotherSource(for ctx: PlaybackContext) {
        guard ctx.videoId != target.videoId else {
            autoAdvanced = false     // this list IS the playing episode's: stay on it
            selected = nil
            return
        }
        if let video = ctx.episodes.first(where: { $0.season?.value == ctx.season && $0.episode?.value == ctx.episode }) {
            chooseSource(for: video)
        } else {
            selected = nil           // no episode to retarget to: the usual close (details after autoplay)
        }
    }

    private func retarget(to video: MetaVideo) {
        let still: String? = video.thumbnail
        let overview: String? = video.overview
        let next = Target(
            videoId: NextEpisodeEngine.episodeVideoId(metaId: parentMetaId, episode: video),
            // STAB-02: addons are asked with the episode's own id (kitsu/anime catalogs).
            streamVideoId: NextEpisodeEngine.streamQueryVideoId(metaId: parentMetaId, episode: video),
            streamVideoIdExplicit: true,
            title: NextEpisodeEngine.episodeTitle(video),
            season: video.season?.value,
            episode: video.episode?.value,
            episodeStill: (still ?? "").isEmpty ? nil : still,
            synopsis: (overview ?? "").isEmpty ? nil : overview,
            episodeTitle: video.title
        )
        target = next
        // The list now IS the playing episode's, so a later close stays here.
        autoAdvanced = false
        resetListState()
        model.retarget(videoId: next.videoId, streamVideoId: next.streamVideoId,
                       season: next.season, episode: next.episode)
        SubtitleRepository.shared.fetchAddonSubtitles(type: type, videoId: next.videoId)
    }

    // MARK: - Focus (initial, Best Match, back from the player)

    /// Moves focus for the picker — initial focus, then the Best Match row — but only while focus
    /// is nowhere, on the DEBUG test button, or still where the picker itself last put it.
    private func moveInitialFocus(to key: String) {
        let untouched = focusedRow == nil || focusedRow == Self.testRowKey
            || (autoFocusedKey != nil && focusedRow == autoFocusedKey)
        guard untouched, focusedRow != key else { return }
        autoFocusedKey = key
        DispatchQueue.main.async { focusedRow = key }
    }

    /// STAB-03: Back from the player lands on the row that was played (the list was kept).
    private func restoreFocusAfterPlayback() {
        guard let key = lastPlayedRowKey else { return }
        let onScreen: Bool
        if key == StreamsViewModel.bestMatchRowKey {
            onScreen = model.bestMatch != nil
        } else {
            onScreen = model.stream(forRowKey: key) != nil
                && expandedGroups.contains { key.hasPrefix("\($0)#") }
        }
        guard onScreen else { return }
        autoFocusedKey = nil
        DispatchQueue.main.async { focusedRow = key }
    }

    // MARK: - Group headers

    private static func headerKey(groupId: String) -> String { "header:\(groupId)" }

    /// Collapsed by default: a focusable header row per addon (name, stream count, chevron, and
    /// a per-addon spinner while that addon is still loading — the shared `AddonStreamGroup`
    /// carries `isLoading` per addon already, so this reflects real per-addon state rather than
    /// the global "any addon still loading" flag). Deliberately a plain `Button`, not
    /// `DisclosureGroup` — tvOS focus/highlight on `DisclosureGroup` is poor and inconsistent
    /// with the rest of this screen's rows.
    private func groupHeader(_ group: StreamsViewModel.Group) -> some View {
        let key = Self.headerKey(groupId: group.id)
        let isExpanded = expandedGroups.contains(group.id)

        return Button {
            toggleExpansion(group)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.Font.body)
                    .rowTextColor(secondary: true)
                    .frame(width: Self.chevronWidth, alignment: .center)
                Text(group.addonName)
                    .font(Theme.Font.sectionTitle)
                    .rowTextColor()
                    .lineLimit(1)
                Text(group.streams.count == 1 ? String(localized: "1 stream") : String(localized: "\(group.streams.count) streams"))
                    .font(Theme.Font.caption)
                    .rowTextColor(secondary: true)
                // STAB-07: what's inside before opening it ("2 × 4K · 5 × 1080p").
                if let summary = group.qualitySummary {
                    Text(summary)
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                        .lineLimit(1)
                }
                if group.isLoading {
                    ProgressView().scaleEffect(0.7)
                }
                Spacer()
            }
            .padding(.vertical, Theme.Spacing.xs + 2)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.settingsRow)
        .focused($focusedRow, equals: key)
    }

    private func toggleExpansion(_ group: StreamsViewModel.Group) {
        if expandedGroups.contains(group.id) {
            // Collapsing a group that currently holds focus would otherwise leave focus on a
            // row that's about to disappear from the hierarchy — retarget to the header first.
            if let focusedRow, focusedRow.hasPrefix("\(group.id)#") {
                self.focusedRow = Self.headerKey(groupId: group.id)
            }
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
            // Expanding keeps focus on the header (SwiftUI doesn't move it on select), matching
            // the requirement that expand never steals focus.
        }
    }

    // MARK: - Rows

    /// - Parameter pinnedLabel: the "Recommended" / "Best Match" / "Last Used" capsule of the pinned row.
    ///
    /// STREAM-INSIGHT layout (fixed height, F10): the quality line ("4K · Dolby Vision · Atmos",
    /// the add-on's name when the title states nothing technical), then the chips — size, audio
    /// languages (VFF, VFQ, Anglais…), subtitles, cache state — then source · provider · seeders ·
    /// group, then the original title cut in the middle (in full in the footer).
    private func streamRow(_ stream: StreamItem, key: String, pinnedLabel: String? = nil) -> some View {
        let badges: [StreamBadge] = stream.badges
        let hintSize: Int64? = stream.behaviorHints.videoSize?.int64Value
        let info = model.info(for: stream)
        let sizeBytes: Int64? = model.showFileSizeBadges ? (info?.sizeBytes ?? hintSize) : nil
        let isTopPick = pinnedLabel == nil && model.isTopPick(stream)
        let isExcluded = info?.isExcluded == true
        let quality: String = {
            if let quality = info?.quality, !quality.isEmpty { return quality }
            return rowTitle(stream)
        }()
        let detail: String = info?.detail ?? ""
        let rawTitle: String = info?.rawTitle ?? StreamInsightText.shared.stripEmojiSingleLine(text: stream.streamLabel)

        return Button {
            play(stream, rowKey: key)
        } label: {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if !badges.isEmpty && model.badgesOnTop {
                        badgeRow(badges: badges, sizeBytes: nil)
                    }
                    HStack(spacing: Theme.Spacing.sm) {
                        if let pinnedLabel {
                            rowCapsule(pinnedLabel, systemImage: pinnedLabel == StreamInsightPresenter.recommendedLabel
                                       ? "checkmark.seal.fill" : nil)
                        } else if isTopPick {
                            rowCapsule(StreamInsightPresenter.recommendedLabel, systemImage: "checkmark.seal.fill")
                        }
                        Text(quality)
                            .font(Theme.Font.body.weight(.semibold))
                            .rowTextColor()
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if resolvingKey == key {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                    if let info {
                        StreamLanguageChipsRow(info: info, sizeBytes: sizeBytes)
                    } else if let sizeBytes {
                        StreamFileSizeChip(bytes: sizeBytes)
                    }
                    if isExcluded || info?.isLowQuality == true, let caveat = info?.caveat {
                        HStack(spacing: Theme.Spacing.xxs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(detail.isEmpty ? caveat : "\(caveat) \u{00B7} \(detail)")
                                .lineLimit(1)
                        }
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                    } else if !detail.isEmpty {
                        Text(detail)
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
                            .lineLimit(1)
                    }
                    if badges.isEmpty {
                        // The add-on's own title, emoji removed: one line here, in full in the footer.
                        Text(rawTitle)
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(0.8)
                    } else if !model.badgesOnTop {
                        badgeRow(badges: badges, sizeBytes: nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if model.showAddonLogo {
                    addonLogoColumn(stream)
                }
            }
            .padding(.vertical, Theme.Spacing.sm)
            .padding(.horizontal, Theme.Spacing.md)
            // F10: fixed row height (grows with the text size through @ScaledMetric).
            .frame(maxWidth: .infinity, minHeight: streamRowHeight, maxHeight: streamRowHeight, alignment: .leading)
            .clipped()
            // Filtered out by the viewer's own limits (CAM, size, resolution): still playable, dimmed.
            .opacity(isExcluded && focusedRow != key ? 0.55 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityText(quality: quality, info: info, sizeBytes: sizeBytes,
                                                       capsule: pinnedLabel ?? (isTopPick ? StreamInsightPresenter.recommendedLabel : nil))))
        }
        // `.settingsRow` (platter-free, soft white highlight + accent ring) replaces the system
        // `.glass` style: Liquid Glass's focus platter goes near-white, which made this row's
        // title text (statically `textPrimary`, near-white) unreadable on focus. AES-3: with a
        // faint resting card, so unfocused rows read as separate items instead of one wall of text
        // (focus still swaps it for the white platter).
        .buttonStyle(.settingsRow(restingFill: Theme.Palette.restingRowFill))
        .focused($focusedRow, equals: key)
        // FEAT-5: long-press → the OTHER player(s). With the built-in default, the menu offers
        // the installed external players; with an external default (plain Select already hands
        // off) it inverts to offer "Play in NuvioTV Player" plus any non-default externals. The
        // modifier is skipped entirely when no external player is installed, so the long-press
        // stays inert rather than opening an empty menu.
        .modifier(ExternalPlayMenu(
            players: externalPlayers,
            defaultPlayerId: activeDefaultExternalPlayer?.id,
            onExternal: { player in
                externalPlay(stream, rowKey: key, playerId: player.id)
            },
            onBuiltIn: {
                internalPlay(stream, rowKey: key)
            }
        ))
    }

    /// The "Recommended" / "Best Match" / "Last Used" capsule.
    private func rowCapsule(_ text: String, systemImage: String?) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
        }
        .font(Theme.Font.caption.weight(.semibold))
        .rowTextColor()
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, 2)
        .overlay(Capsule().strokeBorder(Theme.Palette.textSecondary, lineWidth: 1))
        .fixedSize()
    }

    /// VoiceOver: "Recommended, 4K · Dolby Vision · Atmos, audio VFF, English, subtitles French,
    /// 18.4 GB, WEB-DL · YggTorrent".
    private func accessibilityText(quality: String, info: StreamRowInfo?, sizeBytes: Int64?, capsule: String?) -> String {
        var parts: [String] = []
        if let capsule { parts.append(capsule) }
        parts.append(quality)
        if let info {
            let audioList = info.audio.map { $0.text }.joined(separator: ", ")
            let subtitleList = info.subtitles.map { $0.text }.joined(separator: ", ")
            if !audioList.isEmpty {
                parts.append(String(localized: "streams.a11y.audio", defaultValue: "audio \(audioList)",
                                    comment: "VoiceOver, source picker row: the audio languages. %@ is the list."))
            }
            if !subtitleList.isEmpty {
                parts.append(String(localized: "streams.a11y.subtitles", defaultValue: "subtitles \(subtitleList)",
                                    comment: "VoiceOver, source picker row: the subtitle languages. %@ is the list."))
            }
        }
        if let sizeBytes { parts.append(StreamFileSizeChip.label(for: sizeBytes)) }
        if let detail = info?.detail, !detail.isEmpty { parts.append(detail) }
        if let caveat = info?.caveat, info?.isExcluded == true { parts.append(caveat) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func badgeRow(badges: [StreamBadge], sizeBytes: Int64?) -> some View {
        // BUG-16: this used to be one plain HStack with up to 8 badge chips (each up to
        // `StreamBadgeMetrics.maxImageWidth` = 180pt for image-based community badge packs) plus
        // the size chip — none of them width-flexible. An HStack whose children are all
        // non-shrinking ignores the width it's offered and reports the full sum of its children
        // back to its parent instead. That inflated "ideal" width bubbled up through the
        // title/description VStack and the row's outer HStack, widening the *whole row* — and
        // since every row shares one LazyVStack, effectively the whole list — past the screen.
        // The addon-logo column and the tail end of the badges/size chip then rendered off the
        // trailing edge, which is what testers saw as "no space left" for title/size/seeders.
        //
        // Fix: hand `ViewThatFits` a ladder of candidates from "every badge" down to "just an
        // overflow count", widest first. It measures each against the width actually left over
        // once title/description and the addon-logo column have claimed theirs, and renders the
        // first one that fits — so this row can never again demand more width than it's given.
        // The size chip is pinned first in every candidate since it's core metadata (like
        // seeders), not decoration, and every candidate shares the same fixed container height,
        // so switching between them never changes the row's height class.
        let displayBadges = Array(badges.prefix(8))
        let hiddenBeyondCap = max(0, badges.count - 8)
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: displayBadges.count, through: 0, by: -1)), id: \.self) { visible in
                badgeRowVariant(
                    displayBadges: displayBadges,
                    visibleCount: visible,
                    hiddenCount: (displayBadges.count - visible) + hiddenBeyondCap,
                    sizeBytes: sizeBytes
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One `ViewThatFits` candidate for `badgeRow`: the size chip (if any) + the first
    /// `visibleCount` badges + a non-focusable "+N" overflow chip for everything else.
    /// `hiddenCount` folds in both badges dropped by this candidate and any beyond the 8-badge
    /// display cap, so the count the user sees is always accurate.
    private func badgeRowVariant(
        displayBadges: [StreamBadge],
        visibleCount: Int,
        hiddenCount: Int,
        sizeBytes: Int64?
    ) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let sizeBytes {
                StreamFileSizeChip(bytes: sizeBytes)
            }
            ForEach(Array(displayBadges.prefix(visibleCount).enumerated()), id: \.offset) { _, badge in
                StreamBadgeChipView(badge: badge)
            }
            if hiddenCount > 0 {
                BadgeOverflowChip(count: hiddenCount)
            }
        }
    }

    private func addonLogoColumn(_ stream: StreamItem) -> some View {
        VStack(spacing: Theme.Spacing.xxs) {
            let logo: String? = stream.addonLogo
            if let logo, !logo.isEmpty, let url = URL(string: logo) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(stream.addonName)
                .font(Theme.Font.caption)
                .rowTextColor(secondary: true)
                .lineLimit(1)
        }
        .frame(width: 150)
    }

    /// Row title with the mobile "- <Provider> Instant" suffix on debrid-cached torrent rows
    /// (`StreamCard.kt:instantServiceLabel`), shown only while debrid resolution is enabled and
    /// no custom stream-name template is active.
    private func rowTitle(_ stream: StreamItem) -> String {
        // STREAM-INSIGHT: never an add-on emoji in the UI.
        let base = StreamInsightText.shared.stripEmojiSingleLine(text: stream.streamLabel)
        guard model.instantSuffixEnabled,
              let status = stream.debridCacheStatus,
              status.state == .cached else { return base }
        var provider = DebridProviders.shared.shortName(id: status.providerId)
        if provider.trimmingCharacters(in: .whitespaces).isEmpty {
            provider = status.providerName.trimmingCharacters(in: .whitespaces)
        }
        if provider.isEmpty {
            provider = DebridProviders.shared.displayName(id: status.providerId)
        }
        return provider.isEmpty ? base : String(localized: "\(base) - \(provider) Instant")
    }

    // MARK: - Playback / debrid resolve

    /// The validated default external player, or nil for built-in. Membership in the probed
    /// `externalPlayers` list is required — a stale stored id (player uninstalled since it was
    /// chosen) must not hijack every Select into a failed handoff.
    private var activeDefaultExternalPlayer: ExternalPlayerApp? {
        guard !defaultExternalPlayerId.isEmpty else { return nil }
        return externalPlayers.first { $0.id == defaultExternalPlayerId }
    }

    /// Select on a stream row. Routes to the user's default player (Settings → Playback):
    /// external default ⇒ hand off (with automatic fallback to the built-in player if the
    /// handoff fails), otherwise the built-in pipeline.
    private func play(_ stream: StreamItem, rowKey: String) {
        if let defaultPlayer = activeDefaultExternalPlayer {
            externalPlay(stream, rowKey: rowKey, playerId: defaultPlayer.id, fallbackToInternal: true)
            return
        }
        internalPlay(stream, rowKey: rowKey)
    }

    private func internalPlay(_ stream: StreamItem, rowKey: String) {
        // STAB-03: Back from the player puts focus back on this row.
        lastPlayedRowKey = rowKey
        let direct: String? = stream.playableDirectUrl
        if let direct, !direct.isEmpty, let url = URL(string: direct) {
            // A manual stream pick is user interaction — reset the Still Watching run.
            NextEpisodeEngine.consecutiveAutoPlays = 0
            selected = context(url: url, stream: stream)
            return
        }

        // Torrent / clientResolve result → resolve through the in-app debrid connection.
        resolveThroughDebrid(stream, rowKey: rowKey) { resolved, resolvedUrl in
            guard let url = URL(string: resolvedUrl) else {
                showToast(Self.resolveFailureMessage(nil))
                return
            }
            NextEpisodeEngine.consecutiveAutoPlays = 0
            selected = context(url: url, stream: resolved)
        }
    }

    /// STAB-06: how long a debrid resolve may run before the row gives up and says so.
    private static let debridResolveTimeoutSeconds: Double = 20

    /// Resolves a torrent / clientResolve row to a playable link through the in-app debrid
    /// connection, one at a time (`resolvingKey` drives the row spinner). STAB-06: each resolve
    /// carries a generation; one that outlives its 20 s deadline, or answers after the list moved
    /// on (retarget, a player went up), is dropped — it never opens a player out of nowhere — and
    /// the deadline says so in a toast instead of spinning on.
    private func resolveThroughDebrid(_ stream: StreamItem, rowKey: String,
                                      onResolved: @escaping (StreamItem, String) -> Void) {
        guard resolvingKey == nil else { return }
        guard DirectDebridPlaybackResolver.shared.shouldResolveToPlayableStream(stream: stream) else {
            showToast(String(localized: "This stream needs a debrid account. Connect one in Settings \u{2192} Debrid."))
            return
        }
        resolveGeneration += 1
        let generation = resolveGeneration
        resolvingKey = rowKey
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debridResolveTimeoutSeconds) {
            guard generation == resolveGeneration, resolvingKey == rowKey else { return }
            resolveGeneration += 1
            resolvingKey = nil
            showToast(String(
                localized: "streams.resolve.timeout",
                defaultValue: "The debrid service didn\u{2019}t answer in time. Try again, or pick another source.",
                comment: "Source picker: a debrid link resolve took too long and was abandoned."
            ))
        }
        DirectDebridPlaybackResolver.shared.resolveToPlayableStream(
            stream: stream,
            season: season.map { KotlinInt(int: Int32($0)) },
            episode: episode.map { KotlinInt(int: Int32($0)) }
        ) { result, _ in
            // Kotlin suspend completions can land off-main; hop before touching view state.
            DispatchQueue.main.async {
                // Timed out, or superseded: this answer belongs to nobody any more.
                guard generation == resolveGeneration else { return }
                resolvingKey = nil
                if let success = result as? DirectDebridPlayableResult.Success {
                    let resolvedUrl: String? = success.stream.playableDirectUrl
                    if let resolvedUrl, !resolvedUrl.isEmpty {
                        onResolved(success.stream, resolvedUrl)
                        return
                    }
                }
                showToast(Self.resolveFailureMessage(result))
                // The toast promises a refresh — deliver it: stale cached links mean the whole
                // result set is old, so re-fetch (focus is preserved; see onChange guard).
                if result is DirectDebridPlayableResult.Stale {
                    model.reload()
                }
            }
        }
    }

    // MARK: - External player handoff (FEAT-5)

    /// Hands the stream to an installed external player (Infuse today) instead of the in-app
    /// player — reached from a row long-press, or from plain Select when that player is the
    /// user's default. Mirrors `internalPlay(_:rowKey:)`'s two branches — direct URLs open
    /// immediately; torrent/clientResolve results go through the same debrid resolve first,
    /// reusing `resolvingKey` so the row spinner and the one-at-a-time guard behave identically
    /// for both destinations.
    ///
    /// `fallbackToInternal` is set on the default-player route only: a failed handoff there
    /// would strand a user whose Select no longer plays anything, so it degrades to the built-in
    /// player. The explicit long-press route keeps the honest failure toast instead — the user
    /// asked for Infuse specifically, silently playing elsewhere would be surprising.
    private func externalPlay(_ stream: StreamItem, rowKey: String, playerId: String, fallbackToInternal: Bool = false) {
        lastPlayedRowKey = rowKey
        let direct: String? = stream.playableDirectUrl
        if let direct, !direct.isEmpty {
            openExternally(urlString: direct, stream: stream, playerId: playerId, fallbackToInternal: fallbackToInternal)
            return
        }

        resolveThroughDebrid(stream, rowKey: rowKey) { resolved, resolvedUrl in
            openExternally(
                urlString: resolvedUrl,
                stream: resolved,
                playerId: playerId,
                fallbackToInternal: fallbackToInternal
            )
        }
    }

    /// Builds the shared playback request and opens the target player via its x-callback-url
    /// scheme. Title/season/episode feed `buildPlayerTitle()` so Infuse shows
    /// "Show — S02E05" instead of a bare debrid CDN filename. Must run on the main thread
    /// (UIApplication.open under the hood).
    ///
    /// FEAT-21 (beta.12): the handoff now carries what the internal player would use —
    /// `resumePositionMs` from the same `progressForVideo` lookup MPV's resume path runs (same
    /// >10s floor, completed entries excluded), and the stream's addon subtitles, so players
    /// whose URL builders consume `sub`/`position` (VidHub `/play`, Infuse, VLC) resume and
    /// subtitle like the built-in player instead of starting cold.
    private func openExternally(urlString: String, stream: StreamItem, playerId: String, fallbackToInternal: Bool = false) {
        // PLY-7: request headers the addon requires for this stream (Referer / User-Agent / auth —
        // the built-in player sends them). None of the tvOS external players' URL schemes can carry
        // headers, so such a stream may fail over there. The default player's Select plays it here,
        // and says why; "Open in …" (a long press) is the viewer's explicit choice — it still hands
        // off, with a warning (many hosts don't actually enforce the header).
        let requestHeaders = StreamModelsKt.sanitizePlaybackHeaders(headers: stream.behaviorHints.proxyHeaders?.request)
        if !requestHeaders.isEmpty {
            if fallbackToInternal, let url = URL(string: urlString) {
                showToast(String(localized: "This source needs request headers that external players can’t send — playing in NuvioTV."))
                NextEpisodeEngine.consecutiveAutoPlays = 0
                selected = context(url: url, stream: stream)
                return
            }
            showToast(String(localized: "This source needs request headers that external players can’t send — it may not play there."))
        }
        let progress = WatchProgressRepository.shared.progressForVideo(
            videoId: videoId,
            parentMetaId: parentMetaId,
            seasonNumber: season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: episode.map { KotlinInt(int: Int32($0)) }
        )
        let resumeMs: Int64 = {
            guard let progress, !progress.isCompleted else { return 0 }
            if progress.lastPositionMs > 10_000 { return progress.lastPositionMs }
            // A percentage-only row (Simkl episode, Trakt playback, upstream b7657dbe4): an external
            // player needs a timecode, so the share is taken of the episode's own runtime, else of
            // the title's (what the Simkl projection used before), behind the same 10 s floor.
            guard progress.lastPositionMs <= 0, progress.durationMs <= 0, progress.progressFraction > 0,
                  let runtimeSec = externalResumeRuntimeSec() else { return 0 }
            let estimatedMs = Int64(Double(progress.progressFraction) * runtimeSec * 1000)
            return estimatedMs > 10_000 ? estimatedMs : 0
        }()
        // Infuse reports where it stopped through x-callback-url (upstream 99ced26a4): register the
        // launch it will report back on.
        var callbackLaunchId: String?
        var callbacks: (success: String, error: String)?
        if playerId == "infuse" {
            let launch = ExternalPlaybackCallbacks.PendingLaunch(
                id: UUID().uuidString,
                sourceUrl: urlString,
                profileId: ActiveProfileProvider.shared.activeProfileId,
                contentType: type,
                parentMetaId: parentMetaId,
                videoId: videoId,
                title: title,
                poster: poster,
                season: season,
                episode: episode,
                providerName: stream.addonName,
                providerAddonId: stream.addonId,
                streamTitle: stream.streamLabel,
                streamSubtitle: { let s: String? = stream.description_; return s }(),
                durationMs: progress.flatMap { $0.durationMs > 0 ? $0.durationMs : nil }
            )
            callbackLaunchId = launch.id
            callbacks = ExternalPlaybackCallbacks.prepare(launch)
        }
        let request = ExternalPlayerPlaybackRequest(
            sourceUrl: urlString,
            title: title,
            streamTitle: nil,
            // For a URL builder that can carry them — none of the tvOS ones can (the guard above).
            sourceHeaders: requestHeaders,
            resumePositionMs: resumeMs,
            subtitles: stream.externalSubtitles.map { sub in
                SubtitleInput(url: sub.url, name: { let n: String? = sub.name; return n }() ?? sub.language, lang: sub.language)
            },
            season: season.map { KotlinInt(int: Int32($0)) },
            episode: episode.map { KotlinInt(int: Int32($0)) },
            episodeTitle: nil,
            skipSegmentsJson: nil,
            callbackSuccessUrl: callbacks?.success,
            callbackErrorUrl: callbacks?.error
        )
        let result = ExternalPlayerPlatform.shared.open(request: request, playerId: playerId)
        // SharedCore lowercases the whole Kotlin enum entry name (see KMP bridging notes).
        guard result != ExternalPlayerOpenResult.opened else { return }
        if let callbackLaunchId { ExternalPlaybackCallbacks.cancel(id: callbackLaunchId) }
        if fallbackToInternal, let url = URL(string: urlString) {
            showToast(String(localized: "Couldn\u{2019}t open the external player \u{2014} playing in NuvioTV."))
            NextEpisodeEngine.consecutiveAutoPlays = 0
            selected = context(url: url, stream: stream)
        } else {
            showToast(String(localized: "Couldn\u{2019}t open the external player."))
        }
    }

    /// Seconds the target episode runs for, from its own metadata runtime, else the title's runtime
    /// text ("45 min"); nil when neither is known.
    private func externalResumeRuntimeSec() -> Double? {
        let list = episodes.isEmpty ? fetchedEpisodes : episodes
        let current = list.first { video in
            guard let s = video.season?.value, let e = video.episode?.value else { return false }
            return s == season && e == episode
        }
        if let minutes = current?.runtime?.value, minutes > 0 { return Double(minutes) * 60 }
        return NextEpisodeEngine.runtimeSec(parsing: meta?.runtime)
    }

    /// Mirrors the shared `DirectDebridPlayableResult.toastMessage()` wording (tvOS renders the
    /// English fallbacks; matching locally avoids depending on the ext-fun's bridged name).
    /// BUG-21: `Error` now carries a step-specific diagnostic ("TorBox: adding the item failed
    /// (HTTP 403 · BAD_TOKEN: …)") built shared-side — show it verbatim so a tester's toast
    /// names the exact failing call instead of the old catch-all.
    private static func resolveFailureMessage(_ result: DirectDebridPlayableResult?) -> String {
        switch result {
        case is DirectDebridPlayableResult.MissingApiKey:
            return String(localized: "Connect an account in Settings.")
        case is DirectDebridPlayableResult.NotCached:
            return String(localized: "Not cached on your debrid service.")
        case is DirectDebridPlayableResult.Stale:
            return String(localized: "This link expired. Refreshing results.")
        case let error as DirectDebridPlayableResult.Error:
            return error.message ?? String(localized: "Could not open this link.")
        default:
            return String(localized: "Could not open this link.")
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if toast == shown {
                withAnimation { toast = nil }
            }
        }
    }
}

/// Attaches the "play somewhere else" context menu only when at least one supported external
/// player is installed (FEAT-5). A conditional modifier rather than an inline `.contextMenu` so
/// the no-players case adds NOTHING to the row — an empty context menu would still swallow the
/// long-press and show a blank platter, which reads as broken.
///
/// The menu always offers the destinations plain Select does NOT: with the built-in player as
/// default it lists the external players; with an external default it lists "Play in NuvioTV
/// Player" first (the escape hatch back) plus any other installed externals. The default player
/// itself is omitted — Select already goes there, and a menu entry duplicating Select reads as
/// two different actions.
private struct ExternalPlayMenu: ViewModifier {
    let players: [ExternalPlayerApp]
    /// The validated default external player id, or nil when the built-in player is default.
    let defaultPlayerId: String?
    let onExternal: (ExternalPlayerApp) -> Void
    let onBuiltIn: () -> Void

    func body(content: Content) -> some View {
        if players.isEmpty {
            content
        } else {
            content.contextMenu {
                if defaultPlayerId != nil {
                    Button {
                        onBuiltIn()
                    } label: {
                        Label("Play in NuvioTV Player", systemImage: "play.tv")
                    }
                }
                ForEach(players.filter { $0.id != defaultPlayerId }, id: \.id) { player in
                    Button {
                        onExternal(player)
                    } label: {
                        Label("Open in \(player.name)", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
    }
}
