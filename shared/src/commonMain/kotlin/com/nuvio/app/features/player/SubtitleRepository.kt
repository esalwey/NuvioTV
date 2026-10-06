package com.nuvio.app.features.player

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.buildAddonResourceUrl
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.addons.fetchAddonResponseText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.time.TimeSource
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString

object SubtitleRepository {
    private const val ADDON_READY_TIMEOUT_MS = 8_000L

    // Per-addon network budget for the parallel fetch below. This STACKS on the readiness wait
    // above — the wait runs first, then every addon gets its own 10s — so a cold start whose
    // addons never answer is ~18s worst case before the fetch reports completion.
    private const val ADDON_FETCH_TIMEOUT_MS = 10_000L

    private val kermit = Logger.withTag("SubtitleRepo")

    // Kermit goes to os_log on Apple targets, which the tvOS device console pipe
    // (devicectl --console) can't see — mirror to stdout so device runs are diagnosable.
    private object log {
        fun d(message: () -> String) {
            val text = message()
            kermit.d { text }
            println("[SubtitleRepo] $text")
        }
        fun w(message: () -> String) {
            val text = message()
            kermit.w { text }
            println("[SubtitleRepo] WARN $text")
        }
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("SubtitleRepository"))
    private val json = Json { ignoreUnknownKeys = true }

    private val _addonSubtitles = MutableStateFlow<List<AddonSubtitle>>(emptyList())
    val addonSubtitles: StateFlow<List<AddonSubtitle>> = _addonSubtitles.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    // Request key of the last COMPLETED fetch — state, not an edge, so a consumer that subscribes
    // after the fetch finished (or whose fetch call was deduplicated) still sees completion.
    private val _completedRequest = MutableStateFlow<String?>(null)
    val completedRequest: StateFlow<String?> = _completedRequest.asStateFlow()

    private var activeFetchJob: Job? = null
    private var activeKey: String? = null

    fun requestKey(type: String, videoId: String): String =
        "${canonicalSubtitleType(type)}|$videoId"

    fun fetchAddonSubtitles(type: String, videoId: String) {
        val key = requestKey(type, videoId)
        // The stream picker prefetches and the player kicks again for the same content — don't
        // cancel a fetch (or discard results) that already covers this request.
        if (key == activeKey && (activeFetchJob?.isActive == true || _completedRequest.value == key)) return
        activeKey = key
        activeFetchJob?.cancel()
        activeFetchJob = scope.launch {
            val requestType = canonicalSubtitleType(type)
            _isLoading.value = true
            _error.value = null
            _addonSubtitles.value = emptyList()
            if (_completedRequest.value != null) _completedRequest.value = null

            val fetchStart = TimeSource.Monotonic.markNow()
            // The player can outrun addon bootstrap (cold launch straight into playback, debug
            // harness): wait briefly for the repository to initialize and manifest refreshes to
            // settle instead of snapshotting an empty/partial list. No-op once the app is warm.
            withTimeoutOrNull(ADDON_READY_TIMEOUT_MS) {
                AddonRepository.initializedState.first { it }
                AddonRepository.uiState.first { state ->
                    state.addons.enabledAddons().none { it.manifest == null && it.isRefreshing }
                }
            } ?: log.w { "Addon repository not ready after ${ADDON_READY_TIMEOUT_MS}ms — fetching with current snapshot" }
            val addons = AddonRepository.uiState.value.addons.enabledAddons()
            log.d { "Fetching subtitles type=$requestType id=$videoId across ${addons.size} enabled addons" }

            val subtitleAddons = addons.filter { addon ->
                val manifest = addon.manifest
                if (manifest == null) {
                    log.d { "Skip ${addon.displayTitle}: no manifest" }
                    return@filter false
                }
                val subtitleResource = manifest.resources.find { it.name.isSubtitleResourceName() }
                if (subtitleResource == null) {
                    log.d { "Skip ${addon.displayTitle}: no subtitles resource" }
                    return@filter false
                }
                if (!subtitleResource.supportsSubtitleType(requestType, videoId)) {
                    log.d {
                        "Skip ${addon.displayTitle}: type/id mismatch (types=${subtitleResource.types} " +
                            "idPrefixes=${subtitleResource.idPrefixes} vs type=$requestType id=$videoId)"
                    }
                    return@filter false
                }
                true
            }

            if (subtitleAddons.isEmpty()) {
                log.d { "No subtitle-capable addon for type=$requestType id=$videoId — nothing to query" }
                // An addon that declares a subtitles resource but doesn't cover this type/id is
                // still a real empty result, so keep the fork's user-visible message for it.
                if (addons.any { it.manifest?.resources?.any { r -> r.name.isSubtitleResourceName() } == true }) {
                    _error.value = resourceString(
                        "No subtitles found",
                        StringKey.compose_player_no_subtitles_found,
                    )
                }
                // Terminal path — both tvOS players poll `completedRequest`
                // (NativePlaybackCoordinator.subsFetchCompleted, MPVPlayerView's prefetch
                // side-load). Returning without setting it hangs the native player's subtitle wait.
                _completedRequest.value = key
                _isLoading.value = false
                return@launch
            }

            // One coroutine per addon: a slow/dead addon no longer delays the ones behind it, and
            // each addon's results are published as they land instead of at the very end.
            supervisorScope {
                subtitleAddons.map { addon ->
                    async {
                        val manifest = addon.manifest ?: return@async
                        val subtitleUrl = buildAddonResourceUrl(
                            manifestUrl = manifest.transportUrl,
                            resource = "subtitles",
                            type = requestType,
                            id = videoId,
                        )
                        log.d { "Querying ${addon.displayTitle}: $subtitleUrl" }

                        val addonStart = TimeSource.Monotonic.markNow()
                        try {
                            val response = withTimeoutOrNull(ADDON_FETCH_TIMEOUT_MS) {
                                withContext(Dispatchers.Default) {
                                    fetchAddonResponseText(subtitleUrl)
                                }
                            }
                            if (response == null) {
                                log.w {
                                    "${addon.displayTitle}: subtitle fetch timed out after " +
                                        "${addonStart.elapsedNow()} (budget ${ADDON_FETCH_TIMEOUT_MS}ms)"
                                }
                                return@async
                            }

                            val parsed = json.parseToJsonElement(response).jsonObject
                            val subtitlesArray = parsed["subtitles"]?.jsonArray
                            if (subtitlesArray == null) {
                                log.d { "${addon.displayTitle}: response has no subtitles array" }
                                return@async
                            }

                            val addonSubs = mutableListOf<AddonSubtitle>()
                            for (element in subtitlesArray) {
                                val obj = element.jsonObject
                                val id = obj.stringValue("id")
                                    ?: "${manifest.id}_${addonSubs.size}"
                                val url = obj.stringValue("url") ?: continue
                                val rawLang = obj.subtitleLanguage() ?: "unknown"
                                val normalizedLang = normalizeLanguageCode(rawLang) ?: rawLang

                                addonSubs.add(
                                    AddonSubtitle(
                                        id = id,
                                        url = url,
                                        language = normalizedLang,
                                        display = run {
                                            val languageLabel =
                                                SubtitleLanguageLabelProvider.labeler.label(rawLang)
                                            resourceString(
                                                "$languageLabel (${addon.displayTitle})",
                                                StringKey.player_addon_subtitle_display_format,
                                                languageLabel,
                                                addon.displayTitle,
                                            )
                                        },
                                        addonName = addon.displayTitle,
                                    )
                                )
                            }

                            log.d { "${addon.displayTitle}: ${addonSubs.size} subtitles in ${addonStart.elapsedNow()}" }
                            // Atomic CAS append — several addons can land at once. Re-check the
                            // request key so a superseded fetch that slipped past cancellation
                            // can't splice a previous title's subtitles into the current list.
                            if (addonSubs.isNotEmpty() && activeKey == key) {
                                _addonSubtitles.update { current -> current + addonSubs }
                            }
                        } catch (error: Throwable) {
                            if (error is CancellationException) throw error
                            log.w { "${addon.displayTitle}: subtitle fetch failed after ${addonStart.elapsedNow()} — $error" }
                        }
                    }
                }.awaitAll()
            }

            val total = _addonSubtitles.value.size
            log.d { "Subtitle fetch done: $total total in ${fetchStart.elapsedNow()}" }
            // Every addon here declared support for this type/id, so an empty list is a real miss.
            if (total == 0) {
                _error.value = resourceString(
                    "No subtitles found",
                    StringKey.compose_player_no_subtitles_found,
                )
            }
            _completedRequest.value = key
            _isLoading.value = false
        }
    }

    /**
     * Fork (PLY-A10): [clear] only while [key] is still the repository's request. A player tearing
     * down after Up Next already started (or prefetched) the next episode's fetch must not wipe
     * that episode's subtitles. Build [key] with [requestKey].
     */
    fun clearIfCurrent(key: String) {
        val current = activeKey ?: _completedRequest.value
        if (current == null || current == key) clear()
    }

    fun clear() {
        activeFetchJob?.cancel()
        activeKey = null
        _completedRequest.value = null
        _addonSubtitles.value = emptyList()
        _isLoading.value = false
        _error.value = null
    }
}

private fun canonicalSubtitleType(type: String): String =
    if (type.equals("tv", ignoreCase = true)) "series" else type.lowercase()

private fun String.isSubtitleResourceName(): Boolean =
    equals("subtitles", ignoreCase = true) || equals("subtitle", ignoreCase = true)

private fun AddonResource.supportsSubtitleType(type: String, videoId: String): Boolean {
    val canonical = canonicalSubtitleType(type)
    val typeMatches = types.isEmpty() || types.any { canonicalSubtitleType(it).equals(canonical, ignoreCase = true) }
    if (!typeMatches) return false
    return idPrefixes.isEmpty() || idPrefixes.any { prefix -> videoId.startsWith(prefix) }
}

private fun JsonObject.subtitleLanguage(): String? =
    stringValue("lang")
        ?: stringValue("language")
        ?: stringValue("languageCode")
        ?: stringValue("locale")
        ?: stringValue("label")

private fun JsonObject.stringValue(name: String): String? =
    this[name]
        ?.jsonPrimitive
        ?.contentOrNull
        ?.trim()
        ?.takeIf { it.isNotBlank() }
