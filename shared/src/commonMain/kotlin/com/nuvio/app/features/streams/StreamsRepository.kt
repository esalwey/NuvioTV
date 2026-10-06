package com.nuvio.app.features.streams

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.build.FeaturePolicyProvider
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.fetchAddonResponseText
import com.nuvio.app.features.debrid.DirectDebridStreamPreparer
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.debrid.DebridStreamPresentation
import com.nuvio.app.features.debrid.LocalDebridAvailabilityService
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.plugins.PluginScraperHostProvider
import com.nuvio.app.features.plugins.pluginContentId
import com.nuvio.app.features.plugins.PluginsUiState
import com.nuvio.app.features.tmdb.TmdbService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withTimeoutOrNull
import com.nuvio.app.features.debrid.DebridSettings
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import kotlinx.coroutines.launch

object StreamsRepository {
    private val log = Logger.withTag("StreamsRepo")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("StreamsRepository"))
    private val _uiState = MutableStateFlow(StreamsUiState())
    val uiState: StateFlow<StreamsUiState> = _uiState.asStateFlow()

    private var activeJob: Job? = null
    private var activeRequestKey: String? = null

    /**
     * STAB-04: per-request cap on ONE addon's stream fetch, in milliseconds. 0 (the default) adds
     * no cap, so the platform HTTP client's own timeout applies (60 s on Apple, which the manifest
     * install path still relies on). tvOS sets this from the picker so a dead or rate-limited addon
     * reports a failure in seconds instead of holding the "Finding streams" spinner for a minute.
     * Per request, not on the shared client: Android keeps its behaviour unless it opts in.
     */
    var addonFetchTimeoutMillis: Long = 0L

    /** STAB-04: what [retryAddon] needs to refetch one addon of the current request. */
    private class AddonRetryContext(
        val requestToken: String,
        val type: String,
        val targets: Map<String, InstalledStreamAddonTarget>,
        val installedAddonOrder: List<String>,
        val streamBadgeRules: StreamBadgeRules,
        val debridSettings: DebridSettings,
    )

    private var retryContext: AddonRetryContext? = null

    /** Touched by load (UI calls and the BUG-74 remap re-entry), retryAddon and clear only; never from a fetch coroutine. */
    private val retryJobs = mutableMapOf<String, Job>()

    /** Whether a group's [AddonStreamGroup.error] came from [addonFetchTimeoutMillis] expiring. */
    fun isTimeoutError(error: String?): Boolean =
        error?.startsWith(STREAM_FETCH_TIMEOUT_PREFIX) == true

    fun requestToken(
        type: String,
        videoId: String,
        season: Int? = null,
        episode: Int? = null,
        manualSelection: Boolean = false,
    ): String =
        "$type::$videoId::$season::$episode::$manualSelection"

    fun load(type: String, videoId: String, parentMetaId: String? = null, season: Int? = null, episode: Int? = null, manualSelection: Boolean = false) {
        load(
            type = type,
            videoId = videoId,
            parentMetaId = parentMetaId,
            season = season,
            episode = episode,
            manualSelection = manualSelection,
            forceRefresh = false,
        )
    }

    fun reload(type: String, videoId: String, parentMetaId: String? = null, season: Int? = null, episode: Int? = null, manualSelection: Boolean = false) {
        load(
            type = type,
            videoId = videoId,
            parentMetaId = parentMetaId,
            season = season,
            episode = episode,
            manualSelection = manualSelection,
            forceRefresh = true,
        )
    }

    /**
     * [imdbVideoId] is BUG-74's resolved alternate id: non-null only on the second pass, after the
     * suspend TMDB lookup below has turned a `tmdb:` request into the `tt` one that most stream
     * addons are keyed on. Addons are then matched against whichever of the two they accept.
     */
    private fun load(type: String, videoId: String, parentMetaId: String?, season: Int?, episode: Int?, manualSelection: Boolean, forceRefresh: Boolean, imdbVideoId: String? = null, remapAttempted: Boolean = false) {
        val pluginUiState = if (FeaturePolicyProvider.policy.pluginsEnabled) {
            PluginScraperHostProvider.host.initialize()
            PluginScraperHostProvider.host.uiState.value
        } else {
            PluginsUiState(pluginsEnabled = false)
        }
        val requestToken = requestToken(
            type = type,
            videoId = videoId,
            season = season,
            episode = episode,
            manualSelection = manualSelection,
        )
        val requestKey = "$requestToken::pluginsGrouped=${pluginUiState.groupStreamsByRepository}"
        val currentState = _uiState.value
        if (
            !forceRefresh &&
            activeRequestKey == requestKey &&
            (currentState.groups.isNotEmpty() || currentState.emptyStateReason != null || currentState.isAnyLoading)
        ) {
            log.d { "Skipping stream reload for unchanged request type=$type id=$videoId" }
            return
        }

        activeRequestKey = requestKey
        activeJob?.cancel()
        cancelRetries()
        _uiState.value = StreamsUiState(requestToken = requestToken)

        PlayerSettingsRepository.ensureLoaded()
        val playerSettings = PlayerSettingsRepository.uiState.value
        val debridSettings = DebridSettingsRepository.snapshot()
        val streamBadgeRules = StreamBadgeSettingsRepository.snapshot()
        val autoPlayMode = playerSettings.streamAutoPlayMode
        val isAutoPlayEnabled = !manualSelection && autoPlayMode != StreamAutoPlayMode.MANUAL &&
            !(autoPlayMode == StreamAutoPlayMode.REGEX_MATCH &&
                !StreamAutoPlayPolicy.isRegexSelectionConfigured(playerSettings.streamAutoPlayRegex))

        // Look up persisted binge group when both settings are enabled
        val persistedBingeGroup = if (
            playerSettings.streamAutoPlayPreferBingeGroup &&
            playerSettings.streamAutoPlayReuseBingeGroup
        ) {
            parentMetaId?.let { BingeGroupCacheRepository.get(it) }
        } else null

        // Enable direct auto-play flow if normal auto-play is enabled,
        // OR if we have a persisted binge group in MANUAL mode
        val bingeGroupDirectFlow = !manualSelection &&
            persistedBingeGroup != null &&
            autoPlayMode == StreamAutoPlayMode.MANUAL
        val isDirectAutoPlayFlow = isAutoPlayEnabled || bingeGroupDirectFlow

        if (isDirectAutoPlayFlow) {
            _uiState.value = StreamsUiState(
                requestToken = requestToken,
                isDirectAutoPlayFlow = true,
                showDirectAutoPlayOverlay = true,
            )
        }

        val embeddedStreams = MetaDetailsRepository.findEmbeddedStreams(videoId)
        if (embeddedStreams.isNotEmpty()) {
            log.d { "Using ${embeddedStreams.size} embedded streams for type=$type id=$videoId" }
            val group = AddonStreamGroup(
                addonName = embeddedStreams.first().addonName,
                addonId = "embedded",
                streams = embeddedStreams,
                isLoading = false,
            )
            val presentedGroup = StreamBadgePresentation.apply(
                groups = listOf(group),
                rules = streamBadgeRules,
            ).firstOrNull() ?: group
            _uiState.value = StreamsUiState(
                requestToken = requestToken,
                groups = listOf(presentedGroup),
                activeAddonIds = setOf("embedded"),
                // Embedded streams come from the (installed) meta addon, so they classify as an
                // installed-addon source for the auto-play scope (Codex r2 on the 58864ec1 port).
                installedAddonIds = setOf("embedded"),
                isAnyLoading = false,
            )
            return
        }

        val installedAddons = AddonRepository.uiState.value.addons.enabledAddons()
        val pluginScrapers = if (FeaturePolicyProvider.policy.pluginsEnabled) {
            PluginScraperHostProvider.host.getEnabledScrapersForType(type)
        } else {
            emptyList()
        }
        val pluginProviderGroups = pluginScrapers.toPluginProviderGroups(
            repositories = pluginUiState.repositories,
            groupByRepository = pluginUiState.groupStreamsByRepository,
        )

        if (installedAddons.isEmpty() && pluginProviderGroups.isEmpty()) {
            _uiState.value = StreamsUiState(
                requestToken = requestToken,
                isAnyLoading = false,
                emptyStateReason = StreamsEmptyStateReason.NoAddonsInstalled,
            )
            return
        }

        // BUG-74: each addon is asked with the id IT accepts. `videoId` first (so a tmdb-only or
        // prefix-less addon keeps working exactly as before), then the resolved IMDb id if this is
        // the second pass. Before this, one id was used for the whole fan-out and every addon that
        // disagreed with its namespace was dropped without a word.
        val streamAddons = installedAddons
            .mapNotNull { addon ->
                val manifest = addon.manifest ?: return@mapNotNull null
                val streamResources = manifest.resources.filter { resource ->
                    resource.name == "stream" && resource.types.contains(type)
                }
                val requestId = when {
                    streamResources.any { StreamVideoIdRemap.accepts(it.idPrefixes, videoId) } -> videoId
                    imdbVideoId != null &&
                        streamResources.any { StreamVideoIdRemap.accepts(it.idPrefixes, imdbVideoId) } -> imdbVideoId
                    else -> return@mapNotNull null
                }

                InstalledStreamAddonTarget(
                    addonName = addon.displayTitle.ifBlank { manifest.name },
                    addonId = addon.streamAddonInstanceId(manifest.id),
                    manifest = manifest,
                    videoId = requestId,
                )
            }

        log.d { "Found ${streamAddons.size} addons for stream type=$type id=$videoId" }
        // Name BOTH ids on the second pass. The first version of this line printed only the
        // original, so a photographed log showed "id=tmdb:550" twice with different addon counts
        // and no visible reason — the remap is the reason, and the line has to say so.
        StreamDiagnostics.log(
            "match type=$type id=$videoId" +
                (imdbVideoId?.let { " +$it" } ?: "") +
                " → addons=${streamAddons.size}/${installedAddons.size} plugins=${pluginProviderGroups.size}"
        )

        // BUG-74: if a `tmdb:` request is leaving some of the user's stream addons unasked, resolve
        // the IMDb id and run the match again with BOTH ids available, so each addon can be asked
        // with the one it accepts. Gated on `remapAttempted`, not on the result, so a title with no
        // IMDb id on TMDB resolves once and then proceeds normally instead of looping.
        val typeStreamIdPrefixes = installedAddons.mapNotNull { addon ->
            addon.manifest?.resources
                ?.filter { it.name == "stream" && it.types.contains(type) }
                ?.flatMap { it.idPrefixes }
                ?.takeIf { it.isNotEmpty() }
        }
        val tmdbId = StreamVideoIdRemap.parseTmdbId(videoId)
        if (
            !remapAttempted &&
            tmdbId != null &&
            StreamVideoIdRemap.wouldReachMoreAddons(videoId, typeStreamIdPrefixes)
        ) {
            _uiState.value = StreamsUiState(requestToken = requestToken, isAnyLoading = true)
            // LAZY + assign + start, not a bare `activeJob = scope.launch {}`: the body must not be
            // able to run before the field holds it. It nulls that same field below, and a plain
            // launch could interleave the two so `activeJob` ended up pointing at this finished
            // remap instead of the real fetch — leaving `clear()` cancelling a corpse.
            val remapJob = scope.launch(start = CoroutineStart.LAZY) {
                val imdbId = TmdbService.tmdbToImdb(tmdbId = tmdbId, mediaType = type)
                // Cancellation is the supersede guard: `clear()` and any newer `load()` both cancel
                // `activeJob`, which is this job until the lines below, so a request replaced while
                // resolving dies at the suspension above and never re-enters.
                val remapped = imdbId?.let { StreamVideoIdRemap.withImdbId(videoId, it) }
                if (remapped != null) {
                    log.d { "Remapped tmdb id for streams: $videoId -> $remapped" }
                    StreamDiagnostics.log("remap $videoId → $remapped")
                } else {
                    log.w { "No IMDb id for tmdb:$tmdbId ($type) — tt-only stream addons stay unreachable" }
                    StreamDiagnostics.log("remap FAILED $videoId → no imdb id on tmdb")
                }
                // Re-enter either way. On failure `imdbVideoId` stays null and the second pass
                // matches exactly as the first did, so whatever addons DID accept the tmdb id are
                // still fetched — the resolution failing must not cost the user a working source.
                // Release both guards first: `activeRequestKey` so the reload isn't skipped as
                // "unchanged", `activeJob` so the reload's own `activeJob?.cancel()` can't cancel
                // the coroutine making the call. `videoId` stays the ORIGINAL — the second pass
                // needs both ids. parentMetaId passes through untouched; it keys the binge-group
                // cache, not an addon request.
                activeRequestKey = null
                activeJob = null
                load(
                    type = type,
                    videoId = videoId,
                    parentMetaId = parentMetaId,
                    season = season,
                    episode = episode,
                    manualSelection = manualSelection,
                    forceRefresh = forceRefresh,
                    imdbVideoId = remapped,
                    remapAttempted = true,
                )
            }
            activeJob = remapJob
            remapJob.start()
            return
        }

        if (streamAddons.isEmpty() && pluginProviderGroups.isEmpty()) {
            _uiState.value = StreamsUiState(
                requestToken = requestToken,
                isAnyLoading = false,
                // BUG-74: a `tmdb:` id that reached here either had no IMDb equivalent or found no
                // addon willing to take either form. Either way the id — not the user's addon
                // list — is why nothing was asked, and saying so is the whole point of the split.
                emptyStateReason = if (tmdbId != null) {
                    StreamsEmptyStateReason.IncompatibleContentId
                } else {
                    StreamsEmptyStateReason.NoCompatibleAddons
                },
            )
            return
        }

        // Initialise loading placeholders
        val installedAddonOrder = streamAddons.map { it.addonName }
        retryContext = AddonRetryContext(
            requestToken = requestToken,
            type = type,
            targets = streamAddons.associateBy { it.addonId },
            installedAddonOrder = installedAddonOrder,
            streamBadgeRules = streamBadgeRules,
            debridSettings = debridSettings,
        )
        val initialGroups = StreamAutoPlaySelector.orderAddonStreams(streamAddons.map { addon ->
            AddonStreamGroup(
                addonName = addon.addonName,
                addonId = addon.addonId,
                streams = emptyList(),
                isLoading = true,
            )
        } + pluginProviderGroups.map { providerGroup ->
            AddonStreamGroup(
                addonName = providerGroup.addonName,
                addonId = providerGroup.addonId,
                streams = emptyList(),
                isLoading = true,
            )
        }, installedAddonOrder)
        val isInitiallyLoading = initialGroups.any { it.isLoading }
        _uiState.value = StreamsUiState(
            requestToken = requestToken,
            groups = initialGroups,
            activeAddonIds = initialGroups.map { it.addonId }.toSet(),
            installedAddonIds = streamAddons.map { it.addonId }.toSet(),
            isAnyLoading = isInitiallyLoading,
            emptyStateReason = null,
            isDirectAutoPlayFlow = isDirectAutoPlayFlow,
            showDirectAutoPlayOverlay = isDirectAutoPlayFlow,
        )

        activeJob = scope.launch {
            val completions = Channel<StreamLoadCompletion>(capacity = Channel.BUFFERED)
            val pluginRemainingByAddonId = pluginProviderGroups
                .associate { it.addonId to it.scrapers.size }
                .toMutableMap()
            val pluginFirstErrorByAddonId = mutableMapOf<String, String>()
            val totalTasks = streamAddons.size +
                pluginProviderGroups.sumOf { it.scrapers.size }

            val installedAddonNames = installedAddonOrder.toSet()
            val installedAddonIds = streamAddons.map { it.addonId }.toSet()
            val debridAvailabilityJobs = mutableListOf<Job>()
            var autoSelectTriggered = false
            var timeoutElapsed = false
            fun evaluateAutoPlay(bingeGroupOnly: Boolean = false): StreamAutoPlayEvaluation =
                StreamAutoPlaySelector.evaluateAutoPlayStream(
                    streams = _uiState.value.groups.flatMap { it.streams },
                    mode = autoPlayMode,
                    regexPattern = playerSettings.streamAutoPlayRegex,
                    source = playerSettings.streamAutoPlaySource,
                    installedAddonNames = installedAddonNames,
                    selectedAddons = playerSettings.streamAutoPlaySelectedAddons,
                    selectedPlugins = playerSettings.streamAutoPlaySelectedPlugins,
                    preferredBingeGroup = persistedBingeGroup,
                    preferBingeGroupInSelection = persistedBingeGroup != null,
                    bingeGroupOnly = bingeGroupOnly,
                    debridEnabled = debridSettings.canResolvePlayableLinks,
                    activeResolverProviderId = debridSettings.activeResolverProviderId,
                )

            fun settleAutoPlay(evaluation: StreamAutoPlayEvaluation) {
                if (autoSelectTriggered) return
                autoSelectTriggered = true
                _uiState.update { current ->
                    if (evaluation.stream == null) {
                        current.copy(
                            autoPlayStream = null,
                            autoPlayCandidates = emptyList(),
                            isDirectAutoPlayFlow = false,
                            showDirectAutoPlayOverlay = false,
                        )
                    } else {
                        current.copy(
                            autoPlayStream = evaluation.stream,
                            autoPlayCandidates = evaluation.readyStreams,
                        )
                    }
                }
            }

            fun updateAutoPlayAfterStreamsChanged() {
                if (!isDirectAutoPlayFlow || autoSelectTriggered) return

                val earlyEvaluation = when {
                    timeoutElapsed -> evaluateAutoPlay()
                    persistedBingeGroup != null -> evaluateAutoPlay(bingeGroupOnly = true)
                    else -> null
                }
                if (earlyEvaluation?.stream != null) {
                    settleAutoPlay(earlyEvaluation)
                    return
                }

                if (
                    _uiState.value.groups.areAutoPlaySourcesLoaded(
                        source = playerSettings.streamAutoPlaySource,
                        installedAddonIds = installedAddonIds,
                    )
                ) {
                    settleAutoPlay(evaluateAutoPlay())
                }
            }

            fun publishCompletion(completion: StreamLoadCompletion) {
                if (completions.trySend(completion).isFailure) {
                    log.d { "Ignoring late stream load completion after channel close" }
                }
            }

            fun presentStreamGroup(group: AddonStreamGroup): AddonStreamGroup =
                presentAddonGroup(group, streamBadgeRules, debridSettings)

            fun publishAddonGroup(group: AddonStreamGroup) {
                _uiState.update { current ->
                    val updated = StreamAutoPlaySelector.orderAddonStreams(
                        groups = current.groups.map { currentGroup ->
                            if (currentGroup.addonId == group.addonId) group else currentGroup
                        },
                        installedOrder = installedAddonOrder,
                    )
                    val anyLoading = updated.any { it.isLoading }
                    current.copy(
                        groups = updated,
                        isAnyLoading = anyLoading,
                        emptyStateReason = updated.toEmptyStateReason(anyLoading),
                    )
                }
                updateAutoPlayAfterStreamsChanged()
            }

            fun publishAddonGroupAfterCacheCheck(group: AddonStreamGroup) {
                if (group.addonId !in installedAddonIds || group.streams.isEmpty()) {
                    publishAddonGroup(presentStreamGroup(group))
                    return
                }

                val eligibleGroupIds = setOf(group.addonId)
                val shouldWaitForCacheCheck = LocalDebridAvailabilityService.hasPendingCacheCheck(
                    groups = listOf(group),
                    eligibleGroupIds = eligibleGroupIds,
                )
                if (!shouldWaitForCacheCheck) {
                    publishAddonGroup(presentStreamGroup(group))
                    return
                }

                val checkingGroup = LocalDebridAvailabilityService.markChecking(
                    groups = listOf(group),
                    eligibleGroupIds = eligibleGroupIds,
                ).firstOrNull() ?: group

                val availabilityJob = launch {
                    val availabilityGroup = LocalDebridAvailabilityService.annotateCachedAvailability(
                        groups = listOf(checkingGroup),
                        eligibleGroupIds = eligibleGroupIds,
                    ).firstOrNull() ?: checkingGroup
                    publishAddonGroup(presentStreamGroup(availabilityGroup))
                }
                debridAvailabilityJobs += availabilityJob
            }

            updateAutoPlayAfterStreamsChanged()

            val timeoutJob = if (isDirectAutoPlayFlow) {
                val timeoutSeconds = playerSettings.streamAutoPlayTimeoutSeconds
                val isUnlimitedTimeout = timeoutSeconds == Int.MAX_VALUE
                // Timeout semantics:
                // - 0 (instant): timeoutElapsed immediately, full select on each response
                // - 1-30 (bounded): wait the configured delay, then full select
                // - unlimited (Int.MAX_VALUE): timeoutElapsed immediately, full select on each response,
                //   with 60s hard fallback to stream picker
                if (timeoutSeconds <= 0 || isUnlimitedTimeout) {
                    timeoutElapsed = true
                    // For unlimited: launch a hard 60s fallback to dismiss overlay
                    if (isUnlimitedTimeout) {
                        launch {
                            delay(60_000L)
                            if (!autoSelectTriggered) {
                                settleAutoPlay(evaluateAutoPlay())
                            }
                        }
                    } else {
                        null
                    }
                } else {
                    // Bounded timeout (1-30s)
                    launch {
                        delay(timeoutSeconds * 1_000L)
                        timeoutElapsed = true
                        if (!autoSelectTriggered) {
                            val allStreams = _uiState.value.groups.flatMap { it.streams }
                            if (allStreams.isNotEmpty()) {
                                val evaluation = evaluateAutoPlay()
                                if (evaluation.stream != null || !evaluation.hasPendingDebridCandidate) {
                                    settleAutoPlay(evaluation)
                                }
                            }
                        }
                    }
                }
            } else {
                null
            }

            streamAddons.forEach { addon ->
                launch {
                    val url = buildAddonResourceUrl(
                        manifestUrl = addon.manifest.transportUrl,
                        resource = "stream",
                        type = type,
                        id = addon.videoId,
                    )
                    log.d { "Fetching streams from: $url" }
                    StreamDiagnostics.log("fetch ${addon.addonName}: ${StreamDiagnostics.redactUrl(url)}")

                    val group = fetchAddonStreamGroup(addon = addon, url = url, forceRefresh = forceRefresh)
                    publishCompletion(StreamLoadCompletion.Addon(group))
                }
            }

            pluginProviderGroups.forEach { providerGroup ->
                val includeScraperNameInSubtitle = false
                providerGroup.scrapers.forEach { scraper ->
                    launch {
                        val completion = PluginScraperHostProvider.host.executeScraper(
                            scraper = scraper,
                            tmdbId = pluginContentId(
                                videoId = videoId,
                                season = season,
                                episode = episode,
                            ),
                            mediaType = type,
                            season = season,
                            episode = episode,
                        ).fold(
                            onSuccess = { results ->
                                StreamLoadCompletion.PluginScraper(
                                    addonId = providerGroup.addonId,
                                    streams = results.map { result ->
                                        result.toStreamItem(
                                            scraper = scraper,
                                            addonName = providerGroup.addonName,
                                            addonId = providerGroup.addonId,
                                            includeScraperNameInSubtitle = includeScraperNameInSubtitle,
                                        )
                                    },
                                    error = null,
                                )
                            },
                            onFailure = { error ->
                                StreamLoadCompletion.PluginScraper(
                                    addonId = providerGroup.addonId,
                                    streams = emptyList(),
                                    error = error.message ?: resourceString(
                                        "Failed to load ${scraper.name}",
                                        StringKey.streams_failed_to_load_scraper,
                                        scraper.name,
                                    ),
                                )
                            },
                        )
                        publishCompletion(completion)
                    }
                }
            }

            repeat(totalTasks) {
                when (val completion = completions.receive()) {
                    is StreamLoadCompletion.Addon -> {
                        val result = completion.group
                        publishAddonGroupAfterCacheCheck(result)
                    }

                    is StreamLoadCompletion.PluginScraper -> {
                        val remaining = (pluginRemainingByAddonId[completion.addonId] ?: 1) - 1
                        pluginRemainingByAddonId[completion.addonId] = remaining.coerceAtLeast(0)
                        if (!completion.error.isNullOrBlank() && pluginFirstErrorByAddonId[completion.addonId].isNullOrBlank()) {
                            pluginFirstErrorByAddonId[completion.addonId] = completion.error
                        }

                        _uiState.update { current ->
                            val updated = StreamAutoPlaySelector.orderAddonStreams(
                                groups = current.groups.map { group ->
                                    if (group.addonId != completion.addonId) {
                                        group
                                    } else {
                                        val mergedStreams = if (completion.streams.isEmpty()) {
                                            group.streams
                                        } else {
                                            (group.streams + completion.streams).sortedForGroupedDisplay()
                                        }
                                        val stillLoading = remaining > 0
                                        val finalError = if (mergedStreams.isEmpty() && !stillLoading) {
                                            pluginFirstErrorByAddonId[completion.addonId]
                                        } else {
                                            null
                                        }
                                        group.copy(
                                            streams = mergedStreams,
                                            isLoading = stillLoading,
                                            error = finalError,
                                        )
                                    }
                                },
                                installedOrder = installedAddonOrder,
                            )
                            val anyLoading = updated.any { it.isLoading }
                            current.copy(
                                groups = updated,
                                isAnyLoading = anyLoading,
                                emptyStateReason = updated.toEmptyStateReason(anyLoading),
                            )
                        }
                        updateAutoPlayAfterStreamsChanged()
                    }

                }
            }

            for (availabilityJob in debridAvailabilityJobs) {
                availabilityJob.join()
            }

            launch {
                DirectDebridStreamPreparer.prepare(
                    streams = _uiState.value.groups
                        .filter { it.addonId in installedAddonIds }
                        .flatMap { it.streams },
                    season = season,
                    episode = episode,
                    playerSettings = playerSettings,
                    installedAddonNames = installedAddonNames,
                ) { original, prepared ->
                    _uiState.update { current ->
                        current.copy(
                            groups = DirectDebridStreamPreparer.replacePreparedStream(
                                groups = current.groups,
                                original = original,
                                prepared = prepared,
                                eligibleGroupIds = installedAddonIds,
                            ),
                        )
                    }
                    updateAutoPlayAfterStreamsChanged()
                }
            }

            if (isDirectAutoPlayFlow && !autoSelectTriggered) {
                settleAutoPlay(evaluateAutoPlay())
            }
            timeoutJob?.cancel()
        }
    }

    fun selectFilter(addonId: String?) {
        _uiState.update { it.copy(selectedFilter = addonId) }
    }

    fun consumeAutoPlay() {
        activeRequestKey = null
        _uiState.update {
            it.copy(
                autoPlayStream = null,
                autoPlayCandidates = emptyList(),
                isDirectAutoPlayFlow = false,
                showDirectAutoPlayOverlay = false,
            )
        }
    }

    fun skipAutoPlayStream(stream: StreamItem): Boolean {
        var hasNext = false
        _uiState.update { current ->
            val failedIndex = current.autoPlayCandidates.indexOf(stream)
            val remaining = if (failedIndex >= 0) {
                current.autoPlayCandidates.drop(failedIndex + 1)
            } else {
                current.autoPlayCandidates.drop(1)
            }
            hasNext = remaining.isNotEmpty()
            current.copy(
                autoPlayStream = remaining.firstOrNull(),
                autoPlayCandidates = remaining,
                isDirectAutoPlayFlow = remaining.isNotEmpty(),
                showDirectAutoPlayOverlay = remaining.isNotEmpty(),
            )
        }
        return hasNext
    }

    fun cancelLoading() {
        activeJob?.cancel()
        activeJob = null
        _uiState.update { current ->
            if (!current.isAnyLoading && current.groups.none { it.isLoading }) {
                current
            } else {
                val updatedGroups = current.groups.map { group ->
                    if (group.isLoading) group.copy(isLoading = false) else group
                }
                current.copy(
                    groups = updatedGroups,
                    isAnyLoading = false,
                    emptyStateReason = if (updatedGroups.isEmpty()) {
                        current.emptyStateReason
                    } else {
                        updatedGroups.toEmptyStateReason(anyLoading = false)
                    },
                )
            }
        }
    }

    fun clear() {
        activeJob?.cancel()
        activeJob = null
        activeRequestKey = null
        cancelRetries()
        _uiState.value = StreamsUiState()
    }

    /**
     * STAB-04: refetch one addon of the current request (the picker's Retry on a failed row),
     * bypassing the HTTP cache, without touching the other addons' rows. Returns false when the
     * addon is not part of the current request (a plugin group, an embedded list, a request that
     * has since been replaced): the caller then falls back to a full [reload].
     */
    fun retryAddon(addonId: String): Boolean {
        val context = retryContext ?: return false
        val target = context.targets[addonId] ?: return false
        val current = _uiState.value
        if (current.requestToken != context.requestToken) return false
        val group = current.groups.firstOrNull { it.addonId == addonId } ?: return false
        if (group.isLoading) return true

        retryJobs.remove(addonId)?.cancel()
        _uiState.update { state ->
            if (state.requestToken != context.requestToken) {
                state
            } else {
                state.copy(
                    groups = state.groups.map {
                        if (it.addonId == addonId) it.copy(isLoading = true, error = null) else it
                    },
                    isAnyLoading = true,
                    emptyStateReason = null,
                )
            }
        }
        StreamDiagnostics.log("retry ${target.addonName}")
        retryJobs[addonId] = scope.launch {
            val url = buildAddonResourceUrl(
                manifestUrl = target.manifest.transportUrl,
                resource = "stream",
                type = context.type,
                id = target.videoId,
            )
            val fetched = fetchAddonStreamGroup(addon = target, url = url, forceRefresh = true)
            val eligible = setOf(addonId)
            val annotated = if (
                fetched.streams.isNotEmpty() &&
                LocalDebridAvailabilityService.hasPendingCacheCheck(groups = listOf(fetched), eligibleGroupIds = eligible)
            ) {
                val checking = LocalDebridAvailabilityService.markChecking(
                    groups = listOf(fetched),
                    eligibleGroupIds = eligible,
                ).firstOrNull() ?: fetched
                LocalDebridAvailabilityService.annotateCachedAvailability(
                    groups = listOf(checking),
                    eligibleGroupIds = eligible,
                ).firstOrNull() ?: checking
            } else {
                fetched
            }
            val presented = presentAddonGroup(annotated, context.streamBadgeRules, context.debridSettings)
            _uiState.update { state ->
                if (state.requestToken != context.requestToken) {
                    state
                } else {
                    val updated = StreamAutoPlaySelector.orderAddonStreams(
                        groups = state.groups.map { if (it.addonId == addonId) presented else it },
                        installedOrder = context.installedAddonOrder,
                    )
                    val anyLoading = updated.any { it.isLoading }
                    state.copy(
                        groups = updated,
                        isAnyLoading = anyLoading,
                        emptyStateReason = updated.toEmptyStateReason(anyLoading),
                    )
                }
            }
        }
        return true
    }

    private fun cancelRetries() {
        retryJobs.values.forEach { it.cancel() }
        retryJobs.clear()
        retryContext = null
    }

    /** One addon's stream fetch: its streams, or `error` set on failure. Throws only on cancellation. */
    private suspend fun fetchAddonStreamGroup(
        addon: InstalledStreamAddonTarget,
        url: String,
        forceRefresh: Boolean,
    ): AddonStreamGroup {
        val displayName = addon.addonName
        return runCatchingUnlessCancelled {
            val payload = fetchAddonStreamsPayload(url = url, forceRefresh = forceRefresh)
            StreamParser.parse(
                payload = payload,
                addonName = displayName,
                addonId = addon.addonId,
                addonLogo = addon.manifest.logoUrl,
            )
        }.fold(
            onSuccess = { streams ->
                log.d { "Got ${streams.size} streams from ${displayName}" }
                StreamDiagnostics.log("got ${streams.size} from $displayName")
                AddonStreamGroup(
                    addonName = displayName,
                    addonId = addon.addonId,
                    streams = streams,
                    isLoading = false,
                )
            },
            onFailure = { err ->
                log.w(err) { "Failed to fetch streams from ${displayName}" }
                StreamDiagnostics.log("FAILED $displayName: ${err.message ?: "unknown error"}")
                AddonStreamGroup(
                    addonName = displayName,
                    addonId = addon.addonId,
                    streams = emptyList(),
                    isLoading = false,
                    error = err.message,
                )
            },
        )
    }

    /**
     * STAB-04: [fetchAddonResponseText] under [addonFetchTimeoutMillis]. `withTimeoutOrNull`, not
     * `withTimeout`: the latter throws a CancellationException, which [runCatchingUnlessCancelled]
     * rethrows, so the addon would never report back and its row would spin forever.
     */
    private suspend fun fetchAddonStreamsPayload(url: String, forceRefresh: Boolean): String {
        val timeoutMillis = addonFetchTimeoutMillis
        if (timeoutMillis <= 0L) {
            return fetchAddonResponseText(url = url, forceRefresh = forceRefresh)
        }
        return withTimeoutOrNull(timeoutMillis) {
            fetchAddonResponseText(url = url, forceRefresh = forceRefresh)
        } ?: throw StreamFetchTimeoutException(timeoutMillis)
    }

    private fun presentAddonGroup(
        group: AddonStreamGroup,
        rules: StreamBadgeRules,
        debridSettings: DebridSettings,
    ): AddonStreamGroup {
        val badgeGroup = StreamBadgePresentation.apply(
            groups = listOf(group),
            rules = rules,
        ).firstOrNull() ?: group
        return DebridStreamPresentation.apply(
            groups = listOf(badgeGroup),
            settings = debridSettings,
        ).firstOrNull() ?: badgeGroup
    }

    fun setOverlayVisible(visible: Boolean, message: String? = null) {
        _uiState.update { it.copy(showDirectAutoPlayOverlay = visible, overlayMessage = message) }
    }
}

private const val STREAM_FETCH_TIMEOUT_PREFIX = "Timed out"

/** STAB-04: an addon's stream fetch outlived [StreamsRepository.addonFetchTimeoutMillis]. */
class StreamFetchTimeoutException(val timeoutMillis: Long) :
    Exception("$STREAM_FETCH_TIMEOUT_PREFIX after ${timeoutMillis / 1000} s")
