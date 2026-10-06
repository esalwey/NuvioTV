package com.nuvio.app.features.player

import com.nuvio.app.features.addons.AddonResource
import com.nuvio.app.features.addons.ManagedAddon
import com.nuvio.app.features.addons.enabledAddons

fun buildAddonSubtitleFetchKey(
    addons: List<ManagedAddon>,
    type: String?,
    videoId: String?,
): String? {
    val normalizedType = type?.takeIf { it.isNotBlank() } ?: return null
    val normalizedVideoId = videoId?.takeIf { it.isNotBlank() } ?: return null
    val compatibleSubtitleAddons = addons.enabledAddons().mapNotNull { addon ->
        val manifest = addon.manifest ?: return@mapNotNull null
        val supportsSubtitles = manifest.resources.any { resource ->
            resource.isCompatibleSubtitleResource(
                type = normalizedType,
                videoId = normalizedVideoId,
            )
        }
        if (!supportsSubtitles) return@mapNotNull null
        "${manifest.id}:${manifest.transportUrl}"
    }

    if (compatibleSubtitleAddons.isEmpty()) return null
    return buildString {
        append(normalizedType)
        append('|')
        append(normalizedVideoId)
        append('|')
        append(compatibleSubtitleAddons.sorted().joinToString("|"))
    }
}

fun AddonResource.isCompatibleSubtitleResource(type: String, videoId: String): Boolean {
    val isSubtitleResource = name.equals("subtitles", ignoreCase = true) ||
        name.equals("subtitle", ignoreCase = true)
    if (!isSubtitleResource) return false

    val requestType = if (type.equals("tv", ignoreCase = true)) "series" else type
    val typeMatches = types.isEmpty() || types.any { it.equals(requestType, ignoreCase = true) }
    if (!typeMatches) return false

    return idPrefixes.isEmpty() || idPrefixes.any { prefix -> videoId.startsWith(prefix) }
}

// Fork: retained (upstream deleted in 4f79bfe0) — still used by composeApp PlayerScreenRuntimeTrackActions.kt; remove when the runtime half is ported.
fun <T> findPreferredTrackIndex(
    tracks: List<T>,
    targets: List<String>,
    language: (T) -> String?,
): Int {
    if (targets.isEmpty()) return -1
    for (target in targets) {
        val matchIndex = tracks.indexOfFirst { track ->
            languageMatchesPreference(
                trackLanguage = language(track),
                targetLanguage = target,
            )
        }
        if (matchIndex >= 0) {
            return matchIndex
        }
    }
    return -1
}

// Fork: public (upstream: internal) — consumed cross-module by composeApp + tvOS Swift.
enum class SubtitleAutoSelectionMode {
    FORCED_ONLY,
    NORMAL_ONLY,
}

// Fork: public (upstream: internal) — consumed cross-module by composeApp + tvOS Swift.
data class SubtitleAutoSelectionPlan(
    val targets: List<String>,
    val mode: SubtitleAutoSelectionMode,
)

// Fork: public (upstream: internal) — consumed cross-module by composeApp + tvOS Swift.
fun resolveAudioTrackLanguageTarget(track: AudioTrack?): String? {
    if (track == null) return null

    val directLanguage = normalizeLanguageCode(track.language)
        ?.takeUnless { it == "und" || it == "unknown" }
    if (directLanguage != null) return directLanguage

    // Fork seam: upstream reads composeApp's AvailableLanguageOptions (code + label pairs);
    // :shared only carries the codes (PlayerLanguageOptionCodes.kt).
    val selectableLanguages = AvailableLanguageOptionCodes
        .mapNotNull(::normalizeLanguageCode)
        .toSet()
    return listOf(track.label, track.id).firstNotNullOfOrNull { value ->
        normalizeLanguageCode(value)?.takeIf(selectableLanguages::contains)
    }
}

// Fork: public (upstream: internal) — consumed cross-module by composeApp + tvOS Swift.
fun resolveSubtitleAutoSelectionPlan(
    selectedAudioTrack: AudioTrack?,
    preferredAudioTargets: List<String>,
    preferredSubtitleTargets: List<String>,
    useForcedSubtitles: Boolean,
): SubtitleAutoSelectionPlan? {
    if (useForcedSubtitles && selectedAudioTrack == null) return null

    val subtitleTargets = preferredSubtitleTargets
        .map { target -> SubtitleLanguageMatching.normalizeLanguageCode(target) }
        .filter { target ->
            target.isNotBlank() &&
                target != SubtitleLanguageOption.NONE &&
                target != SubtitleLanguageOption.FORCED &&
                target != AudioLanguageOption.DEFAULT
        }
        .distinct()
    val primarySubtitleTarget = subtitleTargets.firstOrNull()
    val forcedTarget = when {
        !useForcedSubtitles -> null
        primarySubtitleTarget != null &&
            selectedAudioTrack != null &&
            audioMatchesSubtitleTargetForForced(selectedAudioTrack, primarySubtitleTarget) ->
            primarySubtitleTarget
        primarySubtitleTarget == null &&
            selectedAudioTrack != null &&
            preferredAudioTargets.any { target ->
                audioTrackMatchesLanguage(selectedAudioTrack, target)
            } -> selectedAudioLanguageTarget(selectedAudioTrack)
        else -> null
    }

    return SubtitleAutoSelectionPlan(
        targets = forcedTarget?.let(::listOf) ?: subtitleTargets,
        mode = if (forcedTarget != null) {
            SubtitleAutoSelectionMode.FORCED_ONLY
        } else {
            SubtitleAutoSelectionMode.NORMAL_ONLY
        },
    )
}

fun audioMatchesSubtitleTargetForForced(
    audioTrack: AudioTrack,
    target: String,
): Boolean {
    if (audioTrackMatchesLanguage(audioTrack, target)) return true

    val normalizedTarget = SubtitleLanguageMatching.normalizeLanguageCode(target)
    val baseTarget = normalizedTarget.substringBefore('-')
    if (baseTarget == normalizedTarget) return false

    val audioVariant = SubtitleLanguageMatching.detectTrackLanguageVariant(
        language = audioTrack.language,
        name = audioTrack.label,
        trackId = audioTrack.id,
    )
    return audioVariant == baseTarget || audioVariant == normalizedTarget
}

// Fork: public (upstream: internal) — composeApp track actions/tests consume cross-module.
fun findPreferredSubtitleTrackIndex(
    tracks: List<SubtitleTrack>,
    targets: List<String>,
    mode: SubtitleAutoSelectionMode,
    selectedAudioTrack: AudioTrack? = null,
): Int = findBestInternalSubtitleTrackIndex(
    tracks = tracks,
    targets = targets,
    forcedOnly = mode == SubtitleAutoSelectionMode.FORCED_ONLY,
    normalOnly = mode == SubtitleAutoSelectionMode.NORMAL_ONLY,
    selectedAudioTrack = selectedAudioTrack,
)

fun findBestInternalSubtitleTrackIndex(
    tracks: List<SubtitleTrack>,
    targets: List<String>,
    forcedOnly: Boolean = false,
    normalOnly: Boolean = false,
    selectedAudioTrack: AudioTrack? = null,
): Int {
    for ((targetPosition, target) in targets.withIndex()) {
        if (forcedOnly) {
            val forcedIndex = findBestForcedSubtitleTrackIndex(
                tracks = tracks,
                target = target,
                selectedAudioTrack = selectedAudioTrack,
            )
            if (forcedIndex >= 0) return forcedIndex
            if (targetPosition == 0) return -1
            continue
        }

        // Fork (LANG-10): canonical, so a device target "fr-FR" gets the France/Québec tie-break.
        val normalizedTarget = SubtitleLanguageMatching.canonicalLanguageVariant(target)
        val candidateIndexes = tracks.indices.filter { index ->
            val track = tracks[index]
            (!normalOnly || !track.isForced) && subtitleTrackMatchesLanguage(track, target)
        }
        if (candidateIndexes.isEmpty()) {
            if (normalizedTarget == "pt-br") {
                val brazilianFromGenericPt = findBrazilianPortugueseInGenericPtTracks(tracks, normalOnly)
                if (brazilianFromGenericPt >= 0) return brazilianFromGenericPt
                if (targetPosition == 0) return -1
            }
            if (normalizedTarget == "es-419") {
                val latinoFromGenericEs = findLatinoSpanishInGenericEsTracks(tracks, normalOnly)
                if (latinoFromGenericEs >= 0) return latinoFromGenericEs
                if (targetPosition == 0) return -1
            }
            continue
        }

        val preferredCandidateIndexes = candidateIndexes.filter { index -> !tracks[index].isForced }
            .takeIf { it.isNotEmpty() }
            ?: if (normalOnly) {
                continue
            } else {
                candidateIndexes
            }

        if (preferredCandidateIndexes.size == 1) {
            if (normalizedTarget == "pt" || normalizedTarget == "es") {
                val track = tracks[preferredCandidateIndexes.first()]
                val variant = SubtitleLanguageMatching.detectTrackLanguageVariant(
                    language = track.language,
                    name = track.label,
                    trackId = track.id,
                )
                // No second clause on the track's raw language code — it equals the
                // variant exactly when the track is explicitly tagged (pt-BR,
                // es-419), which is the case this guard exists for. Upstream's
                // form accepts those for generic pt/es targets (report candidate).
                if (variant != normalizedTarget) {
                    continue
                }
            }
            return preferredCandidateIndexes.first()
        }

        if (normalizedTarget == "pt" || normalizedTarget == "pt-br") {
            val tieBroken = breakPortugueseSubtitleTie(tracks, preferredCandidateIndexes, normalizedTarget)
            if (tieBroken >= 0) return tieBroken
        }
        if (normalizedTarget == "es" || normalizedTarget == "es-419") {
            val tieBroken = breakSpanishSubtitleTie(tracks, preferredCandidateIndexes, normalizedTarget)
            if (tieBroken >= 0) return tieBroken
        }
        if (normalizedTarget == "fr" || normalizedTarget == "fr-ca") {
            val tieBroken = breakFrenchSubtitleTie(tracks, preferredCandidateIndexes, normalizedTarget)
            if (tieBroken >= 0) return tieBroken
        }
        return preferredCandidateIndexes.first()
    }
    return -1
}

fun findBestForcedSubtitleTrackIndex(
    tracks: List<SubtitleTrack>,
    target: String,
    selectedAudioTrack: AudioTrack?,
): Int {
    val directMatch = tracks.indexOfFirst { track ->
        track.isForced &&
            subtitleTrackMatchesLanguage(track, target) &&
            selectedAudioTrack != null &&
            subtitleTrackMatchesSelectedAudioLanguage(track, selectedAudioTrack)
    }
    if (directMatch >= 0) return directMatch

    val normalizedTarget = SubtitleLanguageMatching.canonicalLanguageVariant(target)
    if (normalizedTarget == "pt-br" || normalizedTarget == "es-419") {
        return tracks.indexOfFirst { track ->
            track.isForced &&
                selectedAudioTrack != null &&
                subtitleTrackMatchesSelectedAudioLanguage(track, selectedAudioTrack) &&
                SubtitleLanguageMatching.detectTrackLanguageVariant(
                    language = track.language,
                    name = track.label,
                    trackId = track.id,
                ) == normalizedTarget
        }
    }
    return -1
}

fun subtitleTrackMatchesLanguage(track: SubtitleTrack, target: String): Boolean {
    return SubtitleLanguageMatching.trackMatchesLanguage(
        name = track.label,
        language = track.language,
        trackId = track.id,
        target = target,
    )
}

fun audioTrackMatchesLanguage(track: AudioTrack, target: String): Boolean {
    return SubtitleLanguageMatching.trackMatchesLanguage(
        name = track.label,
        language = track.language,
        trackId = track.id,
        target = target,
    )
}

fun selectedAudioLanguageTarget(track: AudioTrack): String? {
    track.language
        ?.takeIf { it.isNotBlank() && !it.equals("und", ignoreCase = true) }
        ?.let { return it }

    val haystack = listOf(track.label, track.id).joinToString(" ").lowercase()
    // Fork seam: upstream iterates composeApp's AvailableLanguageOptions and reads `option.code`;
    // :shared carries the bare codes (PlayerLanguageOptionCodes.kt), so iterate them directly.
    return AvailableLanguageOptionCodes.firstOrNull { languageCode ->
        val code = languageCode.lowercase()
        val name = SubtitleLanguageMatching.languageCodeToName(languageCode)
        SubtitleLanguageMatching.languageCodeAppearsInHaystack(haystack, code) ||
            (name.isNotBlank() && haystack.contains(name))
    }
}

fun subtitleTrackMatchesSelectedAudioLanguage(
    track: SubtitleTrack,
    selectedAudioTrack: AudioTrack,
): Boolean {
    selectedAudioLanguageTarget(selectedAudioTrack)?.let { audioLanguage ->
        if (subtitleTrackMatchesLanguage(track, audioLanguage)) return true
    }

    val subtitleLanguageName = track.language
        ?.takeIf { it.isNotBlank() && !it.equals("und", ignoreCase = true) }
        ?.let { SubtitleLanguageMatching.languageCodeToName(it) }
    val audioHaystack = listOfNotNull(
        selectedAudioTrack.label,
        selectedAudioTrack.language,
        selectedAudioTrack.id,
    ).joinToString(" ").lowercase()
    return !subtitleLanguageName.isNullOrBlank() && audioHaystack.contains(subtitleLanguageName)
}

fun addonSubtitleIsForced(subtitle: AddonSubtitle): Boolean {
    return listOfNotNull(subtitle.id, subtitle.url, subtitle.addonName)
        .any { value -> value.contains("forced", ignoreCase = true) }
}

fun addonSubtitleMatchesLanguage(subtitle: AddonSubtitle, target: String): Boolean {
    if (SubtitleLanguageMatching.matchesLanguageCode(subtitle.language, target)) return true
    val normalizedTarget = SubtitleLanguageMatching.normalizeLanguageCode(target)
    val targetName = SubtitleLanguageMatching.languageCodeToName(target)
    val haystack = listOfNotNull(subtitle.language, subtitle.id, subtitle.url, subtitle.addonName)
        .joinToString(" ")
        .lowercase()
    return SubtitleLanguageMatching.languageCodeAppearsInHaystack(haystack, normalizedTarget) ||
        (targetName.isNotBlank() && haystack.contains(targetName))
}

fun addonSubtitleMatchesSelectedAudioLanguage(
    subtitle: AddonSubtitle,
    selectedAudioTrack: AudioTrack,
): Boolean {
    selectedAudioLanguageTarget(selectedAudioTrack)?.let { audioLanguage ->
        if (addonSubtitleMatchesLanguage(subtitle, audioLanguage)) return true
    }

    val subtitleLanguageName = subtitle.language
        .takeIf { it.isNotBlank() && !it.equals("und", ignoreCase = true) }
        ?.let { SubtitleLanguageMatching.languageCodeToName(it) }
    val audioHaystack = listOfNotNull(
        selectedAudioTrack.label,
        selectedAudioTrack.language,
        selectedAudioTrack.id,
    ).joinToString(" ").lowercase()
    return !subtitleLanguageName.isNullOrBlank() && audioHaystack.contains(subtitleLanguageName)
}

fun findBrazilianPortugueseInGenericPtTracks(
    tracks: List<SubtitleTrack>,
    normalOnly: Boolean = false,
): Int {
    val genericPtIndexes = tracks.indices.filter { index ->
        if (normalOnly && tracks[index].isForced) return@filter false
        val trackLanguage = tracks[index].language ?: return@filter false
        SubtitleLanguageMatching.normalizeLanguageCode(trackLanguage) == "pt"
    }
    if (genericPtIndexes.isEmpty()) return -1

    val brazilianNonForced = genericPtIndexes.filter { index ->
        !tracks[index].isForced &&
            subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.BRAZILIAN_TAGS) &&
            !subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.EUROPEAN_PT_TAGS)
    }
    if (brazilianNonForced.isNotEmpty()) return brazilianNonForced.first()

    return genericPtIndexes.firstOrNull { index ->
        subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.BRAZILIAN_TAGS) &&
            !subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.EUROPEAN_PT_TAGS)
    } ?: genericPtIndexes.firstOrNull { index ->
        subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.BRAZILIAN_TAGS)
    } ?: -1
}

fun findLatinoSpanishInGenericEsTracks(
    tracks: List<SubtitleTrack>,
    normalOnly: Boolean = false,
): Int {
    val genericEsIndexes = tracks.indices.filter { index ->
        if (normalOnly && tracks[index].isForced) return@filter false
        val trackLanguage = tracks[index].language ?: return@filter false
        SubtitleLanguageMatching.normalizeLanguageCode(trackLanguage) == "es"
    }
    if (genericEsIndexes.isEmpty()) return -1

    val latinoNonForced = genericEsIndexes.filter { index ->
        !tracks[index].isForced &&
            subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.LATINO_TAGS) &&
            !subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.CASTILIAN_TAGS)
    }
    if (latinoNonForced.isNotEmpty()) return latinoNonForced.first()

    return genericEsIndexes.firstOrNull { index ->
        subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.LATINO_TAGS) &&
            !subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.CASTILIAN_TAGS)
    } ?: genericEsIndexes.firstOrNull { index ->
        subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.LATINO_TAGS)
    } ?: -1
}

fun breakPortugueseSubtitleTie(
    tracks: List<SubtitleTrack>,
    candidateIndexes: List<Int>,
    normalizedTarget: String,
): Int {
    fun hasBrazilianTags(index: Int) =
        subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.BRAZILIAN_TAGS)

    fun hasEuropeanTags(index: Int) =
        subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.EUROPEAN_PT_TAGS)

    return if (normalizedTarget == "pt-br") {
        candidateIndexes.firstOrNull { hasBrazilianTags(it) && !hasEuropeanTags(it) }
            ?: candidateIndexes.firstOrNull { hasBrazilianTags(it) }
            ?: candidateIndexes.first()
    } else {
        candidateIndexes.firstOrNull { hasEuropeanTags(it) && !hasBrazilianTags(it) }
            ?: candidateIndexes.firstOrNull { hasEuropeanTags(it) }
            ?: candidateIndexes.firstOrNull { !hasBrazilianTags(it) }
            ?: candidateIndexes.first()
    }
}

fun breakSpanishSubtitleTie(
    tracks: List<SubtitleTrack>,
    candidateIndexes: List<Int>,
    normalizedTarget: String,
): Int {
    fun hasLatinoTags(index: Int) =
        subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.LATINO_TAGS)

    fun hasCastilianTags(index: Int) =
        subtitleHasAnyTag(tracks[index], SubtitleLanguageMatching.CASTILIAN_TAGS)

    return if (normalizedTarget == "es-419") {
        candidateIndexes.firstOrNull { hasLatinoTags(it) && !hasCastilianTags(it) }
            ?: candidateIndexes.firstOrNull { hasLatinoTags(it) }
            ?: candidateIndexes.first()
    } else {
        candidateIndexes.firstOrNull { hasCastilianTags(it) && !hasLatinoTags(it) }
            ?: candidateIndexes.firstOrNull { hasCastilianTags(it) }
            ?: candidateIndexes.firstOrNull { !hasLatinoTags(it) }
            ?: candidateIndexes.first()
    }
}

/**
 * Fork (LANG-10): France vs Quebec French among same-language candidates: the one whose title or
 * code states the target's variant ("VFF" for fr, "VFQ" for fr-ca), else the first.
 */
fun breakFrenchSubtitleTie(
    tracks: List<SubtitleTrack>,
    candidateIndexes: List<Int>,
    normalizedTarget: String,
): Int {
    if (candidateIndexes.isEmpty()) return -1
    fun variant(index: Int) = SubtitleLanguageMatching.detectTrackLanguageVariant(
        language = tracks[index].language,
        name = tracks[index].label,
        trackId = tracks[index].id,
    )
    val exact = candidateIndexes.firstOrNull { variant(it) == normalizedTarget }
    if (exact != null) return exact
    if (normalizedTarget == "fr") {
        candidateIndexes.firstOrNull { variant(it) != "fr-ca" }?.let { return it }
    }
    return candidateIndexes.first()
}

private fun subtitleHasAnyTag(track: SubtitleTrack, tags: List<String>): Boolean {
    return SubtitleLanguageMatching.subtitleHasAnyTag(
        name = track.label,
        language = track.language,
        trackId = track.id,
        tags = tags,
    )
}

fun filterAddonSubtitlesForSettings(
    subtitles: List<AddonSubtitle>,
    settings: PlayerSettingsUiState,
): List<AddonSubtitle> {
    val shouldFilter = settings.subtitleStyle.showOnlyPreferredLanguages
    if (!shouldFilter) return subtitles

    val targets = preferredSubtitleTargetsForSettings(settings)
    // Fork (LANG-14): no preferred language to filter by (subtitles "None", no secondary) keeps
    // the whole list. Filtering against nothing used to hide every addon subtitle.
    if (targets.isEmpty()) return subtitles

    return subtitles.filter { subtitle ->
        targets.any { target ->
            SubtitleLanguageMatching.matchesLanguageCode(subtitle.language, target)
        }
    }
}

// Fork: public (upstream: internal) — composeApp track actions/tests consume cross-module.
fun preferredSubtitleTargetsForSettings(settings: PlayerSettingsUiState): List<String> {
    return resolvePreferredSubtitleLanguageTargets(
        preferredSubtitleLanguage = settings.preferredSubtitleLanguage,
        secondaryPreferredSubtitleLanguage = settings.secondaryPreferredSubtitleLanguage,
        deviceLanguages = DeviceLanguagePreferences.preferredLanguageCodes(),
    ).filterNot { it == SubtitleLanguageOption.FORCED }
}

/**
 * The audio track a saved choice names (LANG-09). Fork (LANG-10): variant-aware — the saved
 * language and name decide the variant ("fre" + "VFQ" is fr-ca), and only tracks of that variant
 * are considered when the file has one: a reused track id or a name like "French" can no longer
 * land on the France dub when the viewer picked the Québec one (or the reverse). Within the
 * variant: the saved id when its name still fits, the saved name exactly, the saved name as a
 * part, then the first track of the variant.
 */
fun findPersistedAudioTrackIndex(
    tracks: List<AudioTrack>,
    preference: PersistedPlayerTrackPreference,
): Int {
    val targetId = preference.audioTrackId?.trim()?.lowercase()?.takeIf { it.isNotBlank() }
    val targetName = preference.audioName?.trim()?.lowercase()?.takeIf { it.isNotBlank() }
    val targetLanguage = normalizeLanguageCode(preference.audioLanguage)
        ?.takeUnless { it == "und" || it == "unknown" }
    val languageCandidates = if (targetLanguage == null) {
        tracks
    } else {
        tracks.filter { audioTrackMatchesTarget(it, targetLanguage) }
    }
    if (languageCandidates.isEmpty()) return -1
    val targetVariant = if (targetLanguage == null) {
        null
    } else {
        SubtitleLanguageMatching.detectTrackLanguageVariant(
            language = preference.audioLanguage,
            name = preference.audioName,
            trackId = null,
        ).takeIf { it.isNotBlank() }
    }
    val candidates = targetVariant?.let { variant ->
        languageCandidates.filter { audioTrackLanguageVariant(it) == variant }
    }.orEmpty().ifEmpty { languageCandidates }
    if (targetId != null) {
        candidates.firstOrNull {
            it.id.trim().lowercase() == targetId &&
                (targetName == null || it.label.trim().lowercase().contains(targetName))
        }?.let { return it.index }
    }
    if (targetName != null) {
        candidates.firstOrNull { it.label.trim().lowercase() == targetName }
            ?.let { return it.index }
        candidates.firstOrNull { it.label.trim().lowercase().contains(targetName) }
            ?.let { return it.index }
    }
    if (targetLanguage == null) return -1
    return candidates.first().index
}

// region Fork (LANG-10): variant-aware audio choice, shared by both tvOS engines.

/**
 * One audio track against one language target: its code ("fre", "fr-CA", "jpn"), else — only when
 * the track has no usable code — what its title says ("VFQ", "Español", "English"). A coded
 * track is never matched against its own code by its title ("Français" on an "eng" track is not
 * French).
 */
fun audioTrackMatchesTarget(track: AudioTrack, target: String): Boolean {
    if (languageMatchesPreference(track.language, target)) return true
    val code = track.language?.trim()?.lowercase().orEmpty()
    if (code.isNotEmpty() && code != "und" && code != "unknown") return false
    val stated = languageFromTrackText(track.label) ?: normalizeLanguageCode(track.label) ?: return false
    return languageMatchesPreference(stated, target)
}

/** The language variant a track is ("fr", "fr-ca", "pt-br", "es-419", "ja"), from its code and title. */
fun audioTrackLanguageVariant(track: AudioTrack): String =
    SubtitleLanguageMatching.detectTrackLanguageVariant(
        language = track.language,
        name = track.label,
        trackId = null,
    )

/**
 * The tracks a preference resolves to, best first, as their [AudioTrack.index]: the first target
 * (in priority order) that matches ANY track decides; among its matches the target's exact variant
 * comes first ("fr" → the VFF dub, "fr-CA" → the VFQ one, "fr-FR" from the Apple TV's language
 * counts as "fr"); a France-French target with no stated France dub still avoids the Québec one.
 * Empty when no target matches. Callers that must not re-select an already playing track check
 * whether the list contains the selected one.
 */
fun preferredAudioTrackCandidates(tracks: List<AudioTrack>, targets: List<String>): List<Int> {
    for (target in targets) {
        val matches = tracks.filter { audioTrackMatchesTarget(it, target) }
        if (matches.isEmpty()) continue
        val wanted = SubtitleLanguageMatching.canonicalLanguageVariant(target)
        val exact = matches.filter { audioTrackLanguageVariant(it) == wanted }
        if (exact.isNotEmpty()) return exact.map { it.index }
        if (wanted == "fr") {
            val notQuebec = matches.filter { audioTrackLanguageVariant(it) != "fr-ca" }
            if (notQuebec.isNotEmpty()) return notQuebec.map { it.index }
        }
        return matches.map { it.index }
    }
    return emptyList()
}

/** The first of [preferredAudioTrackCandidates], or -1. */
fun findPreferredAudioTrackIndex(tracks: List<AudioTrack>, targets: List<String>): Int =
    preferredAudioTrackCandidates(tracks, targets).firstOrNull() ?: -1

/**
 * The track playback should start on: the title's saved choice ([findPersistedAudioTrackIndex])
 * when one is saved and fits this file, else the preferred-language pick
 * ([findPreferredAudioTrackIndex]). -1 = leave the player's default. Plain strings so the native
 * engine can call it from its remux worker without sharing a preference object across threads.
 */
fun resolveInitialAudioTrackIndex(
    tracks: List<AudioTrack>,
    targets: List<String>,
    savedLanguage: String?,
    savedName: String?,
    savedTrackId: String?,
): Int {
    if (!savedLanguage.isNullOrBlank()) {
        val persisted = findPersistedAudioTrackIndex(
            tracks,
            PersistedPlayerTrackPreference(
                audioLanguage = savedLanguage,
                audioName = savedName,
                audioTrackId = savedTrackId,
            ),
        )
        if (persisted >= 0) return persisted
    }
    return findPreferredAudioTrackIndex(tracks, targets)
}

// endregion

/**
 * Upstream c9d6f5f63 (public here: the tvOS players call it from Swift). The addon subtitle to
 * restore for a saved addon choice: the saved file itself when the list still has it (the same
 * episode), else — the next episode, whose addon subtitles are other files — the one in the saved
 * language, from the saved provider when it has one, preferring the saved display name. Never the
 * saved URL for a list that doesn't contain it (another episode's file).
 */
fun findPersistedAddonSubtitle(
    subtitles: List<AddonSubtitle>,
    preference: PersistedPlayerTrackPreference,
): AddonSubtitle? {
    preference.addonSubtitleUrl?.takeIf { it.isNotBlank() }?.let { url ->
        subtitles.firstOrNull { it.url == url }?.let { return it }
    }
    val language = preference.subtitleLanguage?.takeIf { it.isNotBlank() } ?: return null
    val candidates = subtitles.filter { addonSubtitleMatchesLanguage(it, language) }
    val providerCandidates = preference.addonSubtitleAddonName?.takeIf { it.isNotBlank() }?.let { name ->
        candidates.filter { it.addonName.equals(name, ignoreCase = true) }
    }.orEmpty()
    val preferredCandidates = providerCandidates.ifEmpty { candidates }
    return preferredCandidates.firstOrNull {
        it.display.equals(preference.subtitleName, ignoreCase = true)
    } ?: preferredCandidates.firstOrNull()
}

/**
 * Upstream c9d6f5f63's gate while addon subtitles are still arriving: restore `subtitle` (a
 * [findPersistedAddonSubtitle] match) right away only when it is the saved file or comes from the
 * saved provider — another provider's match waits, since the saved one may still arrive.
 */
fun canRestorePersistedAddonSubtitleWhileLoading(
    subtitle: AddonSubtitle,
    preference: PersistedPlayerTrackPreference,
): Boolean =
    subtitle.url == preference.addonSubtitleUrl ||
        preference.addonSubtitleAddonName.isNullOrBlank() ||
        subtitle.addonName.equals(preference.addonSubtitleAddonName, ignoreCase = true)

fun findPersistedSubtitleTrackIndex(
    tracks: List<SubtitleTrack>,
    preference: PersistedPlayerTrackPreference,
): Int {
    preference.subtitleTrackId?.takeIf { it.isNotBlank() }?.let { trackId ->
        tracks.firstOrNull { it.id == trackId }?.let { return it.index }
    }

    val languageCandidates = preference.subtitleLanguage?.takeIf { it.isNotBlank() }?.let { language ->
        tracks.indices.filter { index ->
            SubtitleLanguageMatching.matchesLanguageCode(tracks[index].language, language) ||
                subtitleTrackMatchesLanguage(tracks[index], language)
        }
    }.orEmpty()
    // An explicit false must exclude forced tracks too, or a stream that lists
    // its forced track first hijacks a persisted regular-subtitle choice —
    // upstream filters only on true (report candidate).
    val forcedFiltered = when (preference.subtitleIsForced) {
        true -> languageCandidates.filter { index -> tracks[index].isForced }
        false -> languageCandidates.filter { index -> !tracks[index].isForced }
        null -> languageCandidates
    }
    if (forcedFiltered.size == 1) return tracks[forcedFiltered.first()].index
    if (forcedFiltered.size > 1) {
        val targetVariant = SubtitleLanguageMatching.detectTrackLanguageVariant(
            language = preference.subtitleLanguage,
            name = preference.subtitleName,
            trackId = preference.subtitleTrackId,
        )
        val variantMatch = forcedFiltered.firstOrNull { index ->
            SubtitleLanguageMatching.detectTrackLanguageVariant(
                language = tracks[index].language,
                name = tracks[index].label,
                trackId = tracks[index].id,
            ) == targetVariant
        }
        return tracks[variantMatch ?: forcedFiltered.first()].index
    }

    preference.subtitleName?.takeIf { it.isNotBlank() }?.let { name ->
        val nameMatches = tracks.filter { it.label.equals(name, ignoreCase = true) }
        val forcedNameMatches = when (preference.subtitleIsForced) {
            true -> nameMatches.filter { it.isForced }
            false -> nameMatches.filter { !it.isForced }
            null -> nameMatches
        }
        forcedNameMatches.firstOrNull()?.let { return it.index }
    }
    return -1
}

// region Fork (LANG-09/10, spec §8.1): accessibility-aware defaults, shared by both tvOS engines.
//
// Additive: new functions, so the Swift-visible selectors of the existing ones (and composeApp's
// callers) stay unchanged.

private val SdhWords = setOf("sdh", "cc", "hoh", "sme")
private val SdhPhrases = listOf(
    "hearing impaired", "hard of hearing", "closed captions", "closed caption",
    "malentendant", "malentendants", "sourds",
)

/**
 * A subtitle title that marks SDH / closed captions ("English SDH", "Français (SME)",
 * "English [CC]", "Hearing Impaired"). Whole words, case and diacritics folded.
 */
fun subtitleTextLooksSdh(text: String?): Boolean {
    val folded = text?.lowercase()?.let(::stripLanguageDiacritics)?.takeIf { it.isNotBlank() } ?: return false
    val words = folded.split(' ', '(', ')', '[', ']', '-', '_', '.', ',', '/', '|', ':')
        .filter { it.isNotBlank() }
    if (words.any { it in SdhWords }) return true
    val spaced = words.joinToString(" ", prefix = " ", postfix = " ")
    return SdhPhrases.any { spaced.contains(" $it ") }
}

/**
 * [resolveSubtitleAutoSelectionPlan] plus the tvOS defaults of spec §8.1:
 * - the "Forced" subtitle-language option means forced subtitles in the audio's language;
 * - with "Use forced subtitles" on and no subtitle language, audio in the device's primary
 *   language (not only a preferred audio language) also gets forced subtitles;
 * - with the system "Closed Captions + SDH" setting on, subtitles are always on: the subtitle
 *   targets, else the audio's language, else the device's primary language (callers then prefer
 *   SDH tracks via [findPreferredSubtitleTrackIndexPreferringSdh]).
 * Null in the same case as [resolveSubtitleAutoSelectionPlan] (forced subtitles wanted, audio
 * unknown): leave the player's own defaults alone.
 */
fun resolveSubtitleAutoSelectionPlanWithDefaults(
    selectedAudioTrack: AudioTrack?,
    preferredAudioTargets: List<String>,
    preferredSubtitleTargets: List<String>,
    useForcedSubtitles: Boolean,
    deviceLanguages: List<String>,
    closedCaptionsEnabled: Boolean,
): SubtitleAutoSelectionPlan? {
    val subtitleTargets = preferredSubtitleTargets
        .map { target -> SubtitleLanguageMatching.normalizeLanguageCode(target) }
        .filter { target ->
            target.isNotBlank() &&
                target != SubtitleLanguageOption.NONE &&
                target != SubtitleLanguageOption.FORCED &&
                target != AudioLanguageOption.DEFAULT
        }
        .distinct()
    // Base language only: Apple lists "fr-FR" first, and a "fre" track must still match it.
    val devicePrimary = deviceLanguages.firstNotNullOfOrNull { normalizeLanguageCode(it) }
        ?.substringBefore('-')
        ?.takeIf { it.isNotBlank() }
    val audioLanguage = selectedAudioTrack
        ?.let { selectedAudioLanguageTarget(it) }
        ?.let { SubtitleLanguageMatching.normalizeLanguageCode(it) }
        ?.takeIf { it.isNotBlank() && it != "und" && it != "unknown" }

    if (closedCaptionsEnabled) {
        val targets = subtitleTargets.ifEmpty { listOfNotNull(audioLanguage ?: devicePrimary) }
        return SubtitleAutoSelectionPlan(targets = targets, mode = SubtitleAutoSelectionMode.NORMAL_ONLY)
    }

    val forcedOption = preferredSubtitleTargets.firstOrNull()
        ?.let { SubtitleLanguageMatching.normalizeLanguageCode(it) } == SubtitleLanguageOption.FORCED
    if (forcedOption) {
        if (selectedAudioTrack == null) return null
        return SubtitleAutoSelectionPlan(
            targets = listOfNotNull(audioLanguage),
            mode = SubtitleAutoSelectionMode.FORCED_ONLY,
        )
    }

    val plan = resolveSubtitleAutoSelectionPlan(
        selectedAudioTrack = selectedAudioTrack,
        preferredAudioTargets = preferredAudioTargets,
        preferredSubtitleTargets = preferredSubtitleTargets,
        useForcedSubtitles = useForcedSubtitles,
    ) ?: return null
    if (useForcedSubtitles &&
        plan.targets.isEmpty() &&
        subtitleTargets.isEmpty() &&
        selectedAudioTrack != null &&
        audioLanguage != null &&
        devicePrimary != null &&
        audioTrackMatchesLanguage(selectedAudioTrack, devicePrimary)
    ) {
        return SubtitleAutoSelectionPlan(
            targets = listOf(audioLanguage),
            mode = SubtitleAutoSelectionMode.FORCED_ONLY,
        )
    }
    return plan
}

/**
 * [findPreferredSubtitleTrackIndex], then the SDH rule among the tracks that share the picked
 * track's language variant and forced flag: with [preferSdh] (system closed captions on) an SDH
 * track wins; without it a plain track wins over an SDH one. -1 when nothing matched.
 */
fun findPreferredSubtitleTrackIndexPreferringSdh(
    tracks: List<SubtitleTrack>,
    targets: List<String>,
    mode: SubtitleAutoSelectionMode,
    selectedAudioTrack: AudioTrack?,
    preferSdh: Boolean,
): Int {
    val picked = findPreferredSubtitleTrackIndex(
        tracks = tracks,
        targets = targets,
        mode = mode,
        selectedAudioTrack = selectedAudioTrack,
    )
    if (picked !in tracks.indices) return picked
    val pickedTrack = tracks[picked]
    fun variant(track: SubtitleTrack) = SubtitleLanguageMatching.detectTrackLanguageVariant(
        language = track.language,
        name = track.label,
        trackId = track.id,
    )
    val pickedVariant = variant(pickedTrack)
    val siblings = tracks.indices.filter { index ->
        tracks[index].isForced == pickedTrack.isForced && variant(tracks[index]) == pickedVariant
    }
    fun isSdh(index: Int) = subtitleTextLooksSdh(tracks[index].label)
    return if (preferSdh) {
        if (isSdh(picked)) picked else siblings.firstOrNull { isSdh(it) } ?: picked
    } else {
        if (!isSdh(picked)) picked else siblings.firstOrNull { !isSdh(it) } ?: picked
    }
}

// endregion
