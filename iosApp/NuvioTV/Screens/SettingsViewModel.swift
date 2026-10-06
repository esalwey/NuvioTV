import Combine
import SharedCore

/// Backs the Settings screen. All settings persist locally (profile-scoped) via the shared
/// repositories — no config/sign-in needed.
///
/// - Playback: `PlayerSettingsRepository.skipIntroEnabled` (gates the in-player Skip pill).
/// - Home Rows: `HomeCatalogSettingsRepository` (enable/disable + reorder). `HomeRepository` already
///   reads these preferences, so changes take effect on Home after a refresh (which we trigger).
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var skipIntroEnabled = true
    /// The selected app theme's enum name ("CRIMSON", "OCEAN", ...). Persisted profile-scoped via
    /// the tvOS ThemeSettingsStore adapter; the root AppThemeModel applies it to the palette.
    @Published private(set) var themeName = "CRIMSON"
    @Published private(set) var catalogs: [HomeCatalogSettingsItem] = []
    /// Whether the Home hero (rotating banner built from up to 2 catalog sources) shows at all.
    @Published private(set) var heroEnabled = true
    /// Home rows append the media type to catalog titles (synced; default on).
    @Published private(set) var showCatalogType = true
    /// UX-8: hide the entire Discover section on the Search screen (synced; default off).
    @Published private(set) var hideDiscover = false
    /// Upstream 7c1c6578: keep and show recent searches (per profile, this Apple TV; default on).
    @Published private(set) var recentSearchesEnabled = true
    /// SET-2 / upstream 6fb46976b: rating visibility on detail pages (synced per profile).
    @Published private(set) var showOverallRatings = true
    /// `EpisodeRatingsVisibility.name`: "SHOW_ALL", "HIDE_EPISODES" or "HIDE_UNWATCHED_EPISODES".
    @Published private(set) var episodeRatingsVisibility = "SHOW_ALL"
    /// TMDB enrichment (cast profiles, studios/networks, collections, artwork). Gated on a user key.
    @Published private(set) var tmdbEnabled = false
    @Published private(set) var tmdbHasKey = false
    /// Chip code for the metadata-language row: "device" while no language is stored (the shared
    /// repo derives it from the device language), else the stored code's primary subtag.
    @Published private(set) var tmdbLanguageSelection = "device"
    /// MDBList external ratings (IMDb/RT/Metacritic/Trakt/Letterboxd on Detail). Gated on a user key;
    /// the shared MetaDetailsRepository applies the enrichment itself on every load.
    @Published private(set) var mdbListEnabled = false
    @Published private(set) var mdbListHasKey = false
    /// Subtitle appearance (applied by the player on file load). Nil until settings load.
    @Published private(set) var subtitleStyle: SubtitleStyleState?
    /// Preferred track languages (player auto-selects a matching track on load).
    @Published private(set) var preferredAudioLanguage = "device"
    @Published private(set) var preferredSubtitleLanguage = "none"
    /// Stream auto-play (shared `PlayerSettings`, this Apple TV's settings namespace). The stream
    /// picker is always manual on tvOS, so these decide how Up Next picks the NEXT episode's
    /// stream (`NextEpisodeAutoPlay.select`). Values are the Kotlin enum names.
    @Published private(set) var streamAutoPlayMode = "MANUAL"
    @Published private(set) var streamAutoPlaySource = "ALL_SOURCES"
    @Published private(set) var streamAutoPlayRegex = ""
    /// Poster card style (size in dp, corner radius in dp, hide titles, landscape catalog rows).
    @Published private(set) var posterWidthDp: Int32 = 126
    @Published private(set) var posterCornerRadiusDp: Int32 = 12
    @Published private(set) var posterHideLabels = false
    @Published private(set) var posterLandscapeRows = false
    /// Card-depth styling (master toggle + edge/sheen/coverage strengths + per-surface flags).
    @Published private(set) var cardDepth = CardDepthStyle.default
    /// FEAT-10: every search-capable catalog across the enabled addons — the rows behind
    /// Settings → Content Sources → Search Sources. Derived from the addon watcher below.
    @Published private(set) var searchSourceOptions: [SearchCatalogOption] = []
    /// FEAT-10: disabled-source keys, mirrored from `SearchViewModel.SearchSourceSettings`
    /// into a published property so the pane's toggles re-render on change.
    @Published private(set) var disabledSearchSourceKeys: Set<String> = SearchViewModel.SearchSourceSettings.disabledKeys
    /// BUG-33 defect 1 instrumentation: passthrough of `SearchUiState.lastFanOut` — watched
    /// directly off `SearchRepository.shared.uiState` (mirroring `searchSourceOptions` above)
    /// rather than through `SearchViewModel`: the Search and Settings tabs hold independent
    /// `@StateObject` instances in `MainTabView`, so there's no shared instance to read from.
    /// Nil until the first search of this app session, or after `SearchViewModel.queryChanged`
    /// clears back to an empty query.
    @Published private(set) var lastSearchFanOut: String?
    /// Which backend owns the Library tab: "local", "trakt", or "simkl". `SettingsPickerRow`
    /// selection key, not the raw Kotlin enum — mirrors `tmdbLanguageSelection`'s string-key
    /// pattern so the Content Sources pane's picker doesn't switch over the bridged enum in the
    /// view. Backed by the provider-neutral `TrackingSettingsRepository` facade (currently
    /// persists through the Trakt settings store — see the Kotlin object's doc comment).
    @Published private(set) var librarySourceMode = "trakt"
    /// Which backend owns Continue Watching / watched history: "trakt", "simkl", or "nuvio_sync".
    @Published private(set) var watchProgressSource = "trakt"

    /// FEAT-10: flip one search source on/off (persists locally + updates the published mirror).
    ///
    /// The new set is computed in shared code (`resolveSearchSourceToggle`), never by inserting or
    /// removing the row's own key here: a row can be disabled by a LEGACY bare base key that
    /// switches off its whole collision group, and dropping only the row's suffixed key would
    /// leave that bare key behind — the row would stay off forever (Codex round-2 finding N1).
    /// The resolver drops the bare key and re-persists the other group members under their own
    /// keys, so only this row changes state. Persisting uses `setAll`, a single UserDefaults write
    /// of the whole resolved set, rather than a remove/add diff loop — a diff loop can be
    /// interrupted by app termination between the two passes and drop the legacy bare key without
    /// having pinned its sibling keys yet, silently re-enabling them.
    func setSearchSource(key: String, disabled: Bool) {
        let current = SearchViewModel.SearchSourceSettings.disabledKeys
        // Kotlin Set<String> arrives as a Swift Set of AnyHashable.
        let resolvedRaw = SearchRepository.shared.resolveSearchSourceToggle(
            optionKey: key,
            disabled: disabled,
            currentDisabledKeys: current,
            addons: enabledAddons
        )
        let resolved = Set(resolvedRaw.compactMap { $0 as? String })

        SearchViewModel.SearchSourceSettings.setAll(resolved)
        disabledSearchSourceKeys = SearchViewModel.SearchSourceSettings.disabledKeys
    }

    private var themeWatcher: FlowWatcher?
    private var playerWatcher: FlowWatcher?
    private var catalogWatcher: FlowWatcher?
    private var addonWatcher: FlowWatcher?
    private var tmdbWatcher: FlowWatcher?
    private var mdbListWatcher: FlowWatcher?
    private var posterStyleWatcher: FlowWatcher?
    private var cardDepthWatcher: FlowWatcher?
    private var trackingSettingsWatcher: FlowWatcher?
    private var searchStateWatcher: FlowWatcher?
    private var searchHistoryWatcher: FlowWatcher?
    private var metaScreenWatcher: FlowWatcher?
    private var enabledAddons: [ManagedAddon] = []

    func start() {
        guard playerWatcher == nil else { return }

        ThemeSettingsRepository.shared.ensureLoaded()
        themeWatcher = FlowWatcherKt.watch(ThemeSettingsRepository.shared.selectedTheme) { [weak self] emitted in
            guard let self, let theme = emitted as? AppTheme else { return }
            self.themeName = theme.name
        }

        PlayerSettingsRepository.shared.ensureLoaded()
        upNextThreshold = UpNextPreferences.threshold(
            settings: PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState)
        playerWatcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PlayerSettingsUiState else { return }
            self.skipIntroEnabled = state.skipIntroEnabled
            self.subtitleStyle = state.subtitleStyle
            self.preferredAudioLanguage = state.preferredAudioLanguage
            self.preferredSubtitleLanguage = state.preferredSubtitleLanguage
            self.streamAutoPlayMode = state.streamAutoPlayMode.name
            self.streamAutoPlaySource = state.streamAutoPlaySource.name
            self.streamAutoPlayRegex = state.streamAutoPlayRegex
            // The shared (synced) Up Next threshold — may change through profile sync.
            self.upNextThreshold = UpNextPreferences.threshold(settings: state)
        }

        TmdbSettingsRepository.shared.ensureLoaded()
        tmdbWatcher = FlowWatcherKt.watch(TmdbSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? TmdbSettings else { return }
            self.tmdbEnabled = state.enabled
            self.tmdbHasKey = state.hasApiKey
            // Stored languages may carry a region ("de-DE" from the phone's field); the chip row
            // keys on the primary subtag.
            self.tmdbLanguageSelection = TmdbSettingsRepository.shared.hasExplicitLanguage()
                ? String(state.language.split(separator: "-").first ?? Substring(state.language))
                : "device"
        }

        MdbListSettingsRepository.shared.ensureLoaded()
        mdbListWatcher = FlowWatcherKt.watch(MdbListSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MdbListSettings else { return }
            self.mdbListEnabled = state.enabled
            self.mdbListHasKey = state.hasApiKey
        }

        PosterCardStyleRepository.shared.ensureLoaded()
        posterStyleWatcher = FlowWatcherKt.watch(PosterCardStyleRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PosterCardStyleUiState else { return }
            self.posterWidthDp = state.widthDp
            self.posterCornerRadiusDp = state.cornerRadiusDp
            self.posterHideLabels = state.hideLabelsEnabled
            self.posterLandscapeRows = state.catalogLandscapeModeEnabled
        }

        CardDepthStyleRepository.shared.ensureLoaded()
        cardDepthWatcher = FlowWatcherKt.watch(CardDepthStyleRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? CardDepthStyleUiState else { return }
            self.cardDepth = CardDepthStyle(from: state)
        }

        // Library Source / Watch Progress Source (Content Sources pane). `TrackingSettingsRepository`
        // is the provider-neutral facade added alongside Simkl; its uiState is still the Trakt
        // settings type under the hood (`TrackingSettingsUiState` is a Kotlin typealias for
        // `TraktSettingsUiState`), so that's what the watcher casts to.
        TrackingSettingsRepository.shared.ensureLoaded()
        trackingSettingsWatcher = FlowWatcherKt.watch(TrackingSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? TraktSettingsUiState else { return }
            self.librarySourceMode = Self.librarySourceModeKey(state.librarySourceMode)
            self.watchProgressSource = Self.watchProgressSourceKey(state.watchProgressSource)
        }

        // The catalog list is derived from the installed add-ons; sync it whenever they change so
        // the Home Rows list stays current (tvOS has to call this itself).
        addonWatcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            let enabled = AddonModelsKt.enabledAddons(state.addons)
            self.enabledAddons = enabled
            // FEAT-10: keep the Search Sources rows in step with the installed addons.
            self.searchSourceOptions = SearchRepository.shared.searchCatalogOptions(addons: enabled)
            // "Home Rows blank" bug (docs/steven-batch-plan-2026-08-29.md, "data clobber"):
            // HomeCatalogSettingsRepository derives its published items ONLY from the in-memory
            // `definitions` set here. Feeding it an empty/pending-manifest emission — app start
            // pre-refresh, a server pull publishing addons whose manifests haven't fetched yet,
            // a profile switch, or an addon removal — used to zero `definitions` and blank the
            // Home Rows / catalog selection section. Mirror HomeViewModel.onAddonsChanged's
            // guards (only addons with a loaded manifest can contribute catalogs, and never sync
            // an empty result), which is why Home never blanked from this same emission stream.
            let ready = enabled.filter { $0.manifest != nil }
            guard !ready.isEmpty else { return }
            HomeCatalogSettingsRepository.shared.syncCatalogs(addons: ready)
        }
        catalogWatcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? HomeCatalogSettingsUiState else { return }
            self.catalogs = state.items
            self.showCatalogType = state.showCatalogType
            self.heroEnabled = state.heroEnabled
            self.hideDiscover = state.hideDiscover
        }

        // BUG-33 defect 1 instrumentation: the Search Sources pane's fan-out caption. Watches
        // the same shared `SearchRepository.uiState` the Search tab's `SearchViewModel` watches.
        searchStateWatcher = FlowWatcherKt.watch(SearchRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? SearchUiState else { return }
            self.lastSearchFanOut = state.lastFanOut
        }

        SearchHistoryRepository.shared.ensureLoaded()
        searchHistoryWatcher = FlowWatcherKt.watch(SearchHistoryRepository.shared.enabled) { [weak self] emitted in
            guard let self, let enabled = emitted as? KotlinBoolean else { return }
            self.recentSearchesEnabled = enabled.boolValue
        }

        MetaScreenSettingsRepository.shared.ensureLoaded()
        metaScreenWatcher = FlowWatcherKt.watch(MetaScreenSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? MetaScreenSettingsUiState else { return }
            self.showOverallRatings = state.showOverallRatings
            self.episodeRatingsVisibility = state.episodeRatingsVisibility.name
        }

        // "Home Rows blank" bug: Settings must not depend on Home/Search having mounted first to
        // hydrate the addon list. Without this call, entering Settings directly — post-wipe or
        // post-profile-switch, before Home ever ran its own `AddonRepository.initialize()` — left
        // `AddonRepository.shared.uiState` at its initial empty state forever, so the addon
        // watcher above never saw a ready addon and the catalog pane stayed permanently blank.
        AddonRepository.shared.initialize()
    }

    func stop() {
        themeWatcher?.cancel(); themeWatcher = nil
        playerWatcher?.cancel(); playerWatcher = nil
        catalogWatcher?.cancel(); catalogWatcher = nil
        addonWatcher?.cancel(); addonWatcher = nil
        tmdbWatcher?.cancel(); tmdbWatcher = nil
        mdbListWatcher?.cancel(); mdbListWatcher = nil
        posterStyleWatcher?.cancel(); posterStyleWatcher = nil
        cardDepthWatcher?.cancel(); cardDepthWatcher = nil
        trackingSettingsWatcher?.cancel(); trackingSettingsWatcher = nil
        searchStateWatcher?.cancel(); searchStateWatcher = nil
        searchHistoryWatcher?.cancel(); searchHistoryWatcher = nil
        metaScreenWatcher?.cancel(); metaScreenWatcher = nil
    }

    // MARK: - Actions

    func setTheme(_ theme: AppTheme) {
        ThemeSettingsRepository.shared.setTheme(theme: theme)
    }

    func setSkipIntro(_ enabled: Bool) {
        PlayerSettingsRepository.shared.setSkipIntroEnabled(enabled: enabled)
    }

    // MARK: - Device-local player tuning (UserDefaults — hardware knobs, deliberately unsynced)

    /// Streaming buffer size in MiB (0 = mpv defaults). Applies to the next playback.
    @Published var bufferMB: Int = UserDefaults.standard.integer(forKey: PlayerTuning.bufferMBKey)
    /// Network readahead in seconds (0 = mpv defaults). Applies to the next playback.
    @Published var readaheadSec: Int = UserDefaults.standard.integer(forKey: PlayerTuning.readaheadSecKey)
    /// Ask tvOS to match the display's refresh rate (and dynamic range) to the content.
    @Published var matchFrameRate: Bool = UserDefaults.standard.bool(forKey: PlayerTuning.matchFrameRateKey)
    /// Use mpv's `gpu-next` (libplacebo) renderer for better HDR (real Apple TV only).
    @Published var enhancedRenderer: Bool = UserDefaults.standard.bool(forKey: PlayerTuning.enhancedRendererKey)
    /// Route Dolby Vision / native-friendly files to the AVPlayer engine for true DV output (beta).
    @Published var nativeDolbyVision: Bool = UserDefaults.standard.bool(forKey: PlayerTuning.nativeDVKey)
    /// Native-DV sub-setting: keep DV Profile 7 FEL files on mpv (full-fidelity data path) instead
    /// of converting them to Profile 8.1 for the native player.
    @Published var dvP7FelMpv: Bool = UserDefaults.standard.bool(forKey: PlayerTuning.dvP7FelMpvKey)

    func setBufferMB(_ value: Int) {
        bufferMB = value
        UserDefaults.standard.set(value, forKey: PlayerTuning.bufferMBKey)
    }

    func setReadaheadSec(_ value: Int) {
        readaheadSec = value
        UserDefaults.standard.set(value, forKey: PlayerTuning.readaheadSecKey)
    }

    func setMatchFrameRate(_ value: Bool) {
        matchFrameRate = value
        UserDefaults.standard.set(value, forKey: PlayerTuning.matchFrameRateKey)
    }

    func setEnhancedRenderer(_ value: Bool) {
        enhancedRenderer = value
        UserDefaults.standard.set(value, forKey: PlayerTuning.enhancedRendererKey)
    }

    func setNativeDolbyVision(_ value: Bool) {
        nativeDolbyVision = value
        UserDefaults.standard.set(value, forKey: PlayerTuning.nativeDVKey)
    }

    func setDvP7FelMpv(_ value: Bool) {
        dvP7FelMpv = value
        UserDefaults.standard.set(value, forKey: PlayerTuning.dvP7FelMpvKey)
    }

    // MARK: - Up Next (Settings → Playback → Next Episode)
    //
    // Every Up Next row is device-local (`UpNextPreferences`, tvOS defaults, never pushed to the
    // phone). Until "Before the End" is picked here, the profile's synced next-episode threshold
    // (set on the phone) applies — see `UpNextPreferences` for the policy.

    /// Automatic next episode (tvOS default ON).
    @Published var upNextAutoplay: Bool = UpNextPreferences.autoplayEnabled
    /// Show Up Next when the credits start, when their timing is known (default ON).
    @Published var upNextUseCredits: Bool = UpNextPreferences.useCredits
    /// Countdown length in seconds (5/10/15, default 5).
    @Published var upNextCountdown: Int = UpNextPreferences.countdownSec
    /// "Still watching?" gate (default ON).
    @Published var upNextAskStillWatching: Bool = UpNextPreferences.askStillWatching
    /// Effective threshold: this TV's pick, else the profile's synced one, else 30 s.
    @Published private(set) var upNextThreshold: UpNextThreshold =
        .secondsBeforeEnd(Double(UpNextPreferences.defaultSecondsBeforeEnd))

    /// Picker value for "Before the End": 15/30/45/60, or `upNextCustomThresholdTag` for a value
    /// synced from the phone that isn't one of those (kept visible so it isn't silently replaced).
    static let upNextCustomThresholdTag = -1

    var upNextSecondsBeforeEnd: Int {
        if case .secondsBeforeEnd(let seconds) = upNextThreshold {
            let rounded = Int(seconds.rounded())
            if UpNextPreferences.secondsBeforeEndOptions.contains(rounded) { return rounded }
        }
        return Self.upNextCustomThresholdTag
    }

    var upNextSecondsBeforeEndOptions: [Int] {
        let options = UpNextPreferences.secondsBeforeEndOptions
        return upNextSecondsBeforeEnd == Self.upNextCustomThresholdTag
            ? options + [Self.upNextCustomThresholdTag] : options
    }

    func upNextSecondsBeforeEndLabel(_ value: Int) -> String {
        guard value == Self.upNextCustomThresholdTag else { return String(localized: "\(value) s") }
        switch upNextThreshold {
        case .percent(let percent):
            let share = "\(Int(percent.rounded()))%"
            return String(localized: "\(share) of the episode")
        case .secondsBeforeEnd(let seconds):
            let total = Int(seconds.rounded())
            return total >= 60 && total % 60 == 0 ? String(localized: "\(total / 60) min") : String(localized: "\(total) s")
        }
    }

    func setUpNextAutoplay(_ value: Bool) {
        upNextAutoplay = value
        UpNextPreferences.setAutoplayEnabled(value)
    }

    func setUpNextUseCredits(_ value: Bool) {
        upNextUseCredits = value
        UpNextPreferences.setUseCredits(value)
    }

    func setUpNextCountdown(_ seconds: Int) {
        upNextCountdown = seconds
        UpNextPreferences.setCountdownSec(seconds)
    }

    func setUpNextAskStillWatching(_ value: Bool) {
        upNextAskStillWatching = value
        UpNextPreferences.setAskStillWatching(value)
    }

    /// Stores this TV's "N seconds before the end" (the custom tag is display-only).
    func setUpNextSecondsBeforeEnd(_ seconds: Int) {
        guard seconds != Self.upNextCustomThresholdTag else { return }
        UpNextPreferences.setSecondsBeforeEnd(seconds)
        upNextThreshold = .secondsBeforeEnd(Double(seconds))
    }

    // MARK: - Stream auto-play (Settings → Playback → Next Episode Stream)

    func setStreamAutoPlayMode(_ key: String) {
        let mode: StreamAutoPlayMode
        switch key {
        case "FIRST_STREAM": mode = .firstStream
        case "REGEX_MATCH": mode = .regexMatch
        default: mode = .manual
        }
        PlayerSettingsRepository.shared.setStreamAutoPlayMode(mode: mode)
    }

    func setStreamAutoPlaySource(_ key: String) {
        let source: StreamAutoPlaySource
        switch key {
        case "INSTALLED_ADDONS_ONLY": source = .installedAddonsOnly
        case "ENABLED_PLUGINS_ONLY": source = .enabledPluginsOnly
        default: source = .allSources
        }
        PlayerSettingsRepository.shared.setStreamAutoPlaySource(source: source)
    }

    /// Saves the "Regex match" pattern; false (nothing saved) when the shared selector could not use
    /// it — it would then match nothing and Up Next would find no stream. Checked by the shared
    /// policy itself (Kotlin `Regex`, case-insensitive — the engine the selector compiles with, not
    /// ICU's NSRegularExpression), which also refuses a pattern with no letter or digit. Empty is
    /// the explicit "None" choice.
    @discardableResult
    func setStreamAutoPlayRegex(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !StreamAutoPlayPolicy.shared.isRegexSelectionConfigured(regexPattern: trimmed) {
            return false
        }
        PlayerSettingsRepository.shared.setStreamAutoPlayRegex(regex: trimmed)
        return true
    }

    // MARK: - TMDB

    /// Save a key and turn enrichment on. Order matters: `setEnabled(true)` is a no-op while the key
    /// is blank, so set the key first (the repo trims it and persists via NSUserDefaults).
    func saveTmdbKey(_ key: String) {
        TmdbSettingsRepository.shared.setApiKey(value: key)
        TmdbSettingsRepository.shared.setEnabled(value: true)
    }

    // MARK: - MDBList

    /// Save a key and enable external ratings (provider sub-toggles all default on). Enrichment
    /// applies to titles opened after enabling.
    func saveMdbListKey(_ key: String) {
        MdbListSettingsRepository.shared.setApiKey(value: key)
        MdbListSettingsRepository.shared.setEnabled(value: true)
    }

    func setMdbListEnabled(_ enabled: Bool) {
        MdbListSettingsRepository.shared.setEnabled(value: enabled)
    }

    func clearMdbListKey() {
        MdbListSettingsRepository.shared.setApiKey(value: "")
        MdbListSettingsRepository.shared.setEnabled(value: false)
    }

    func setTmdbEnabled(_ enabled: Bool) {
        TmdbSettingsRepository.shared.setEnabled(value: enabled)
    }

    /// "device" clears the stored metadata language (the shared repo then follows this Apple TV's
    /// language); any other code stores it explicitly. Either way the Home hero's TMDB enrichment
    /// refetches. Assigned directly too because clearing to an identical derived language doesn't
    /// re-emit the settings flow.
    func setTmdbLanguage(_ code: String) {
        if code == "device" {
            TmdbSettingsRepository.shared.clearLanguage()
        } else {
            TmdbSettingsRepository.shared.setLanguage(value: code)
        }
        tmdbLanguageSelection = code
    }

    /// Append the media type to catalog row titles ("Popular - Movies" vs just "Popular").
    /// Cross-device synced; the shared HomeRepository composes the titles either way.
    func setShowCatalogType(_ enabled: Bool) {
        HomeCatalogSettingsRepository.shared.setShowCatalogType(enabled: enabled)
    }

    /// UX-8 (u/mrStevenx3, asked three ways): hide the whole Discover section on the Search
    /// screen — the bare search field remains. Per-profile, cross-device synced (shared
    /// home-catalog namespace, same channel as Show Catalog Type).
    func setHideDiscover(_ enabled: Bool) {
        HomeCatalogSettingsRepository.shared.setHideDiscover(enabled: enabled)
    }

    /// Upstream 7c1c6578 (#1934): off stops recording and hides the Recent Searches chips; the
    /// saved list is kept and comes back when switched on again.
    func setRecentSearchesEnabled(_ enabled: Bool) {
        SearchHistoryRepository.shared.setEnabled(enabled: enabled)
    }

    // MARK: - Ratings visibility (SET-2 / upstream 6fb46976b)

    /// Standard (add-on IMDb) and TMDB ratings on detail pages. MDBList scores follow the MDBList
    /// switch in Content Sources.
    func setShowOverallRatings(_ enabled: Bool) {
        MetaScreenSettingsRepository.shared.setShowOverallRatings(enabled: enabled)
    }

    /// Keys are `EpisodeRatingsVisibility.name`.
    func setEpisodeRatingsVisibility(_ key: String) {
        let visibility: EpisodeRatingsVisibility
        switch key {
        case "HIDE_EPISODES": visibility = .hideEpisodes
        case "HIDE_UNWATCHED_EPISODES": visibility = .hideUnwatchedEpisodes
        default: visibility = .showAll
        }
        MetaScreenSettingsRepository.shared.setEpisodeRatingsVisibility(visibility: visibility)
    }

    /// Clearing the key also disables enrichment (handled inside the repo).
    func clearTmdbKey() {
        TmdbSettingsRepository.shared.setApiKey(value: "")
    }

    // MARK: - Subtitles

    /// Rebuild the whole `SubtitleStyleState` with one field changed (KMP has no partial copy in
    /// Swift), then persist. Colors are argb longs (0xAARRGGBB). No-ops until the style has loaded.
    private func updateSubtitleStyle(_ transform: (SubtitleStyleState) -> SubtitleStyleState) {
        guard let current = subtitleStyle else { return }
        PlayerSettingsRepository.shared.setSubtitleStyle(style: transform(current))
    }

    func setSubtitleTextColor(_ argb: Int64) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: argb, backgroundColor: $0.backgroundColor, outlineColor: $0.outlineColor, outlineEnabled: $0.outlineEnabled, outlineWidth: $0.outlineWidth, bold: $0.bold, fontSizeSp: $0.fontSizeSp, bottomOffset: $0.bottomOffset, stripSdh: $0.stripSdh, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    func setSubtitleFontSize(_ sizeSp: Int32) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: $0.textColor, backgroundColor: $0.backgroundColor, outlineColor: $0.outlineColor, outlineEnabled: $0.outlineEnabled, outlineWidth: $0.outlineWidth, bold: $0.bold, fontSizeSp: sizeSp, bottomOffset: $0.bottomOffset, stripSdh: $0.stripSdh, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    func setSubtitleBackground(_ argb: Int64) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: $0.textColor, backgroundColor: argb, outlineColor: $0.outlineColor, outlineEnabled: $0.outlineEnabled, outlineWidth: $0.outlineWidth, bold: $0.bold, fontSizeSp: $0.fontSizeSp, bottomOffset: $0.bottomOffset, stripSdh: $0.stripSdh, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    func setSubtitleBold(_ bold: Bool) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: $0.textColor, backgroundColor: $0.backgroundColor, outlineColor: $0.outlineColor, outlineEnabled: $0.outlineEnabled, outlineWidth: $0.outlineWidth, bold: bold, fontSizeSp: $0.fontSizeSp, bottomOffset: $0.bottomOffset, stripSdh: $0.stripSdh, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    func setSubtitleOutline(_ enabled: Bool) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: $0.textColor, backgroundColor: $0.backgroundColor, outlineColor: $0.outlineColor, outlineEnabled: enabled, outlineWidth: $0.outlineWidth, bold: $0.bold, fontSizeSp: $0.fontSizeSp, bottomOffset: $0.bottomOffset, stripSdh: $0.stripSdh, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    func setSubtitleStripSdh(_ enabled: Bool) {
        updateSubtitleStyle {
            SubtitleStyleState(textColor: $0.textColor, backgroundColor: $0.backgroundColor, outlineColor: $0.outlineColor, outlineEnabled: $0.outlineEnabled, outlineWidth: $0.outlineWidth, bold: $0.bold, fontSizeSp: $0.fontSizeSp, bottomOffset: $0.bottomOffset, stripSdh: enabled, useForcedSubtitles: $0.useForcedSubtitles, showOnlyPreferredLanguages: $0.showOnlyPreferredLanguages)
        }
    }

    // MARK: - Track languages

    func setPreferredAudioLanguage(_ code: String) {
        PlayerSettingsRepository.shared.setPreferredAudioLanguage(language: code)
    }

    func setPreferredSubtitleLanguage(_ code: String) {
        PlayerSettingsRepository.shared.setPreferredSubtitleLanguage(language: code)
    }

    // MARK: - Poster style

    func setPosterWidth(_ dp: Int32) {
        PosterCardStyleRepository.shared.setWidthDp(widthDp: dp)
    }

    func setPosterCorner(_ dp: Int32) {
        PosterCardStyleRepository.shared.setCornerRadiusDp(cornerRadiusDp: dp)
    }

    func setPosterHideLabels(_ enabled: Bool) {
        PosterCardStyleRepository.shared.setHideLabelsEnabled(enabled: enabled)
    }

    func setPosterLandscapeRows(_ enabled: Bool) {
        PosterCardStyleRepository.shared.setCatalogLandscapeModeEnabled(enabled: enabled)
    }

    func resetPosterStyle() {
        PosterCardStyleRepository.shared.resetToDefaults()
    }

    // MARK: - Card depth

    func setCardDepthEnabled(_ enabled: Bool) {
        CardDepthStyleRepository.shared.setEnabled(enabled: enabled)
    }

    func setCardDepthEdge(_ strength: Int32) {
        CardDepthStyleRepository.shared.setEdgeStrength(strength: strength)
    }

    func setCardDepthSheen(_ strength: Int32) {
        CardDepthStyleRepository.shared.setSheenStrength(strength: strength)
    }

    func setCardDepthCoverage(_ coverage: Int32) {
        CardDepthStyleRepository.shared.setEdgeCoverage(coverage: coverage)
    }

    func setCardDepthSurface(_ surface: CardDepthSurface, _ enabled: Bool) {
        // NB: Kotlin/Native lowercases the whole enum-entry name across the ObjC bridge, so the
        // Kotlin `ContinueWatching`/`EpisodeCards` surface here as `.continuewatching`/`.episodecards`.
        let shared: NuvioCardDepthSurface
        switch surface {
        case .posters: shared = .posters
        case .continueWatching: shared = .continuewatching
        case .episodeCards: shared = .episodecards
        case .cast: shared = .cast
        case .trailers: shared = .trailers
        }
        CardDepthStyleRepository.shared.setSurfaceEnabled(surface: shared, enabled: enabled)
    }

    func resetCardDepth() {
        CardDepthStyleRepository.shared.resetToDefaults()
    }

    // MARK: - Library Source / Watch Progress Source

    /// "local", "trakt", or "simkl" → the shared `LibrarySourceMode`. Comparisons use `==` against
    /// the bridged Kotlin enum rather than `switch` (same caution as `setCardDepthSurface`: Kotlin
    /// enum entries are not guaranteed to import as an exhaustively-switchable Swift enum).
    private static func librarySourceModeKey(_ mode: LibrarySourceMode) -> String {
        if mode == .trakt { return "trakt" }
        if mode == .simkl { return "simkl" }
        return "local"
    }

    private static func watchProgressSourceKey(_ source: WatchProgressSource) -> String {
        if source == .trakt { return "trakt" }
        if source == .simkl { return "simkl" }
        return "nuvio_sync"
    }

    /// Falls back to the local Nuvio library (the shared repo's own fallback, `local`) for any
    /// unrecognized key rather than the Trakt default, since a stray key here is a UI bug, not an
    /// unauthenticated-provider condition.
    func setLibrarySourceMode(_ key: String) {
        let mode: LibrarySourceMode
        switch key {
        case "trakt": mode = .trakt
        case "simkl": mode = .simkl
        default: mode = .local
        }
        TrackingSettingsRepository.shared.setLibrarySourceMode(source: mode)
    }

    func setWatchProgressSource(_ key: String) {
        let source: WatchProgressSource
        switch key {
        case "trakt": source = .trakt
        case "simkl": source = .simkl
        default: source = .nuvioSync
        }
        // Route through the repository/coordinator rather than writing the setting directly.
        // TrackingSettingsRepository.setWatchProgressSource only persists the value and updates
        // the chip — WatchProgressRepository and WatchedRepository stay on the previous source
        // until something else happens to refresh them. In guest sessions
        // SyncManager.requestForegroundPull returns early without starting the coordinator, so
        // that refresh may not arrive until relaunch. selectWatchProgressSource sets the value
        // AND runs the source transition.
        WatchProgressRepository.shared.selectWatchProgressSource(
            profileId: ProfileRepository.shared.activeProfileId,
            source: source
        ) { _ in }
    }

    /// Show/hide the Home hero entirely. The shared repo republishes `HomeUiState` from already
    /// -fetched catalog data (`HomeRepository.applyCurrentSettings()`), so no `refreshHome()` call
    /// is needed here — unlike `toggleCatalog`/`moveUp`/`moveDown`, which can add/remove rows.
    func setHeroEnabled(_ enabled: Bool) {
        HomeCatalogSettingsRepository.shared.setHeroEnabled(enabled: enabled)
    }

    /// Enable/disable a catalog as one of the (max 2) sources the Home hero aggregates from.
    /// Deliberately local-only on the Kotlin side (`pushRemote = false` in
    /// `HomeCatalogSettingsRepository.setHeroSourceEnabled`) — do not add sync here. Pass the
    /// item's exact `key`; never construct or split it (BUG-12 class of bug).
    func setHeroSource(key: String, enabled: Bool) {
        HomeCatalogSettingsRepository.shared.setHeroSourceEnabled(key: key, enabled: enabled)
    }

    func toggleCatalog(_ item: HomeCatalogSettingsItem) {
        HomeCatalogSettingsRepository.shared.setEnabled(key: item.key, enabled: !item.enabled)
        refreshHome()
    }

    func moveUp(_ item: HomeCatalogSettingsItem) {
        HomeCatalogSettingsRepository.shared.moveUp(key: item.key)
        refreshHome()
    }

    func moveDown(_ item: HomeCatalogSettingsItem) {
        HomeCatalogSettingsRepository.shared.moveDown(key: item.key)
        refreshHome()
    }

    /// Re-apply the new catalog preferences to Home so the change is visible when the user returns.
    private func refreshHome() {
        HomeRepository.shared.refresh(addons: enabledAddons, force: true)
    }

    deinit {
        playerWatcher?.cancel()
        catalogWatcher?.cancel()
        addonWatcher?.cancel()
        tmdbWatcher?.cancel()
        posterStyleWatcher?.cancel()
        cardDepthWatcher?.cancel()
        trackingSettingsWatcher?.cancel()
        searchStateWatcher?.cancel()
        searchHistoryWatcher?.cancel()
        metaScreenWatcher?.cancel()
    }
}
