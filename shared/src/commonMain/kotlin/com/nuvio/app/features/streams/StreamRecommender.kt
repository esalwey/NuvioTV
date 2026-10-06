package com.nuvio.app.features.streams

import com.nuvio.app.features.player.AudioLanguageOption
import com.nuvio.app.features.player.DeviceLanguagePreferences
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.player.SubtitleLanguageOption
import com.nuvio.app.features.player.normalizeLanguageCode
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** What the device and the title bring to a ranking (the preferences are [StreamRankingPreferences]). */
data class StreamRankingContext(
    /** The title's original language (ISO 639-1), when known — drives "Original" and VO matching. */
    val originalLanguage: String? = null,
    /** `PlayerSettingsRepository` audio language ("device", "original", "fr"…), for [StreamRankingPreferences.AUDIO_AUTO]. */
    val playerAudioLanguage: String? = null,
    val playerSecondaryAudioLanguage: String? = null,
    /** `PlayerSettingsRepository` subtitle language ("none", "device", "fr"…), for [StreamRankingPreferences.SUBTITLE_AUTO]. */
    val playerSubtitleLanguage: String? = null,
    val deviceLanguages: List<String> = emptyList(),
    /** The display path can show HDR (tvOS: `AVPlayer.eligibleForHDRPlayback`). */
    val supportsHdr: Boolean = true,
    /** Dolby Vision reaches the TV as Dolby Vision (HDR-capable display and the native DV player on). */
    val supportsDolbyVision: Boolean = true,
)

enum class StreamReasonKind {
    /** Audio in a wanted language; label = "VFF", "VFQ", "VF", "EN"… */
    LANGUAGE,
    /** The original-language audio; label = "VO" or the tag. */
    ORIGINAL_LANGUAGE,
    /** Original audio + subtitles in the wanted language; label = "VOSTFR" / "VOST EN"… */
    SUBTITLED,
    /** Right language, other version than the one asked for; label = "VFQ" for a VFF viewer. (negative) */
    OTHER_VARIANT,
    /** None of the wanted languages. (negative) */
    LANGUAGE_MISSING,
    /** label = "4K DV", "1080p HDR10". */
    QUALITY,
    /** label = "Atmos", "TrueHD 7.1", "DTS-HD MA". */
    AUDIO,
    /** label = "REMUX", "BluRay". */
    SOURCE,
    CACHED,
    NOT_CACHED,
    DIRECT,
    /** label = "CAM", "TS"… (negative, filtered when avoidLowQuality) */
    LOW_QUALITY,
    /** label = the stream's resolution (filtered). */
    OVER_RESOLUTION,
    /** (filtered) */
    OVER_SIZE,
    /** HDR/DV this display can't show. (negative) */
    HDR_UNSUPPORTED,
    /** The viewer asked to avoid HDR. (negative) */
    HDR_AVOIDED,
    THREE_D,
    NO_SEEDERS,
}

data class StreamReason(
    val kind: StreamReasonKind,
    /** Technical label, the same in every language ("VFF", "4K DV", "Atmos"); "" when the kind says it all. */
    val label: String = "",
    val positive: Boolean = true,
)

data class StreamRecommendation(
    val insight: StreamInsight,
    val score: Int,
    /** Short, ordered, explainable: positives first ("VFF", "4K DV", "Atmos", cached), then negatives. */
    val reasons: List<StreamReason>,
    /** Fails a hard filter (CAM/TS, max resolution, max size). Listed last, never recommended. */
    val isExcluded: Boolean,
)

data class RankedStream(
    val stream: StreamItem,
    val recommendation: StreamRecommendation,
    /** Position in the list handed to [StreamRecommender.rank]. */
    val originalIndex: Int,
    /** The single "Recommended" pick of the list. */
    val isTopPick: Boolean,
) {
    val insight: StreamInsight get() = recommendation.insight
}

/**
 * Fork (STREAM-INSIGHT): ranks streams for the current viewer — hard filters (CAM/TS, max
 * resolution, max size) plus a weighted score in which the audio language dominates (a VFF viewer
 * gets a 720p VFF before a 4K VFQ), then quality, HDR the display can show, audio, debrid cache,
 * seeders. Every score comes with short reasons the picker shows ("VFF · 4K DV · Atmos · Cached").
 */
object StreamRecommender {

    private const val EXCLUDED_PENALTY = 100_000

    /** Builds the context from the shared player settings and the device languages. */
    fun contextFromSettings(
        originalLanguage: String?,
        supportsHdr: Boolean,
        supportsDolbyVision: Boolean,
    ): StreamRankingContext {
        PlayerSettingsRepository.ensureLoaded()
        val settings = PlayerSettingsRepository.uiState.value
        return StreamRankingContext(
            originalLanguage = originalLanguage?.let(::primaryLanguage),
            playerAudioLanguage = settings.preferredAudioLanguage,
            playerSecondaryAudioLanguage = settings.secondaryPreferredAudioLanguage,
            playerSubtitleLanguage = settings.preferredSubtitleLanguage,
            deviceLanguages = runCatching { DeviceLanguagePreferences.preferredLanguageCodes() }.getOrDefault(emptyList()),
            supportsHdr = supportsHdr,
            supportsDolbyVision = supportsDolbyVision,
        )
    }

    /**
     * [streams] best first (stable: equal scores keep their order). Insights may be passed in when
     * the caller already parsed them (same order as [streams]). With the feature off, the order is
     * kept and nothing is marked recommended.
     */
    fun rank(
        streams: List<StreamItem>,
        preferences: StreamRankingPreferences,
        context: StreamRankingContext,
        insights: List<StreamInsight>? = null,
    ): List<RankedStream> {
        val parsed = insights?.takeIf { it.size == streams.size } ?: streams.map(StreamInsightParser::parse)
        val recommendations = parsed.map { recommend(it, preferences, context) }
        if (!preferences.enabled) {
            return streams.mapIndexed { index, stream -> RankedStream(stream, recommendations[index], index, false) }
        }
        val order = orderedIndices(recommendations)
        val topIndex = order.firstOrNull { !recommendations[it].isExcluded }
        return order.map { index ->
            RankedStream(streams[index], recommendations[index], index, isTopPick = index == topIndex)
        }
    }

    /** Indices of [recommendations] best first; stable. */
    fun orderedIndices(recommendations: List<StreamRecommendation>): List<Int> =
        recommendations.indices.sortedWith(
            compareByDescending<Int> { recommendations[it].score }.thenBy { it },
        )

    /** Ranking on parsed insights alone (tests, previews). */
    fun rankInsights(
        insights: List<StreamInsight>,
        preferences: StreamRankingPreferences,
        context: StreamRankingContext,
    ): List<StreamRecommendation> {
        val recommendations = insights.map { recommend(it, preferences, context) }
        return orderedIndices(recommendations).map { recommendations[it] }
    }

    fun recommend(
        insight: StreamInsight,
        preferences: StreamRankingPreferences,
        context: StreamRankingContext,
    ): StreamRecommendation {
        val positives = mutableListOf<StreamReason>()
        val negatives = mutableListOf<StreamReason>()
        var score = 0.0
        var excluded = false

        // Language (dominant).
        val wishes = resolveAudioWishes(preferences, context)
        val language = scoreLanguage(insight, wishes, preferences, context)
        score += language.points
        language.reason?.let { if (it.positive) positives += it else negatives += it }

        // Hard filters.
        if (insight.isLowQuality) {
            negatives += StreamReason(StreamReasonKind.LOW_QUALITY, insight.source.label, positive = false)
            score -= 400
            if (preferences.avoidLowQuality) excluded = true
        }
        if (preferences.maxResolution > 0 && insight.resolution.lines > preferences.maxResolution) {
            negatives += StreamReason(StreamReasonKind.OVER_RESOLUTION, insight.resolution.label, positive = false)
            excluded = true
        }
        val sizeBytes = insight.sizeBytes
        if (preferences.maxSizeGb > 0 && sizeBytes != null &&
            sizeBytes > preferences.maxSizeGb.toLong() * 1024L * 1024L * 1024L
        ) {
            negatives += StreamReason(StreamReasonKind.OVER_SIZE, positive = false)
            excluded = true
        }

        // Resolution.
        score += when (insight.resolution) {
            StreamResolution.P2160 -> 120.0
            StreamResolution.P1440 -> 100.0
            StreamResolution.P1080 -> 90.0
            StreamResolution.P720 -> 55.0
            StreamResolution.P480 -> 25.0
            StreamResolution.SD -> 10.0
            StreamResolution.UNKNOWN -> 45.0
        }

        // HDR, against what this display can show.
        val hdr = scoreHdr(insight, preferences, context)
        score += hdr.first
        hdr.second?.let { negatives += it }
        val qualityLabel = insight.compactQualityLabel
        val showsQuality = insight.resolution.rank >= StreamResolution.P1080.rank || (insight.hasHdr && hdr.first > 0)
        if (qualityLabel.isNotEmpty() && showsQuality && !insight.isLowQuality) {
            positives += StreamReason(StreamReasonKind.QUALITY, qualityLabel)
        }

        // Audio format.
        val lossless = insight.audioCodecs.any {
            it == StreamAudioCodec.TRUEHD || it == StreamAudioCodec.DTS_HD_MA || it == StreamAudioCodec.DTS_X ||
                it == StreamAudioCodec.FLAC || it == StreamAudioCodec.LPCM
        }
        if (insight.hasAtmos) score += 20
        if (lossless) score += 15
        if (StreamAudioCodec.EAC3 in insight.audioCodecs) score += 8
        val channels = insight.audioChannels
        if (channels == "5.1" || channels == "6.1" || channels == "7.1") score += 6
        if (insight.hasAtmos || lossless) insight.audioSummary?.let { positives += StreamReason(StreamReasonKind.AUDIO, it) }

        // Source and codec.
        score += when (insight.source) {
            StreamSourceKind.REMUX -> 35.0
            StreamSourceKind.BLURAY -> 28.0
            StreamSourceKind.WEB_DL -> 24.0
            StreamSourceKind.WEBRIP -> 14.0
            StreamSourceKind.HDTV -> 4.0
            StreamSourceKind.DVDRIP -> -10.0
            else -> 0.0
        }
        if (insight.source == StreamSourceKind.REMUX) positives += StreamReason(StreamReasonKind.SOURCE, insight.source.label)
        when (insight.videoCodec) {
            StreamVideoCodec.HEVC -> score += 4
            // No hardware AV1 decode on most Apple TVs; XviD is a decade-old encode.
            StreamVideoCodec.AV1 -> score -= 10
            StreamVideoCodec.XVID -> score -= 15
            else -> Unit
        }
        if (insight.is3D) {
            score -= 150
            negatives += StreamReason(StreamReasonKind.THREE_D, "3D", positive = false)
        }

        // Ready to play.
        when (insight.cacheState) {
            StreamCacheState.CACHED -> {
                score += if (preferences.preferCached) 90 else 20
                positives += StreamReason(StreamReasonKind.CACHED, insight.debridService.orEmpty())
            }
            StreamCacheState.NOT_CACHED -> {
                if (preferences.preferCached) score -= 45
                negatives += StreamReason(StreamReasonKind.NOT_CACHED, insight.debridService.orEmpty(), positive = false)
            }
            StreamCacheState.UNKNOWN -> if (insight.isDirectLink && !insight.isTorrent) {
                score += if (preferences.preferCached) 40 else 10
            }
        }
        val seeders = insight.seeders
        if (insight.isTorrent && insight.cacheState != StreamCacheState.CACHED && seeders != null) {
            if (seeders == 0) {
                score -= 60
                negatives += StreamReason(StreamReasonKind.NO_SEEDERS, positive = false)
            } else {
                score += min(30.0, 6.0 * ln(seeders + 1.0) / ln(2.0))
            }
        }
        // A little more bitrate for the same resolution, capped so it never beats a real feature.
        if (sizeBytes != null && sizeBytes > 0) {
            score += min(12.0, sizeBytes / (1024.0 * 1024 * 1024) * 0.6)
        }

        val finalScore = score.roundToInt() - if (excluded) EXCLUDED_PENALTY else 0
        return StreamRecommendation(
            insight = insight,
            score = finalScore,
            reasons = positives + negatives,
            isExcluded = excluded,
        )
    }

    // region Language

    /** One wanted audio language, in priority order. */
    sealed class AudioWish {
        /**
         * @param variant the version asked for explicitly (VFF/VFQ): other versions score much lower.
         * @param lean a soft preference among versions (the player's "French" leans to France).
         */
        data class Language(
            val language: String,
            val variant: StreamLanguageVariant? = null,
            val lean: StreamLanguageVariant? = null,
        ) : AudioWish()

        data object Original : AudioWish()
    }

    fun resolveAudioWishes(preferences: StreamRankingPreferences, context: StreamRankingContext): List<AudioWish> {
        val wishes = mutableListOf<AudioWish>()
        if (preferences.audioLanguage == StreamRankingPreferences.AUDIO_AUTO) {
            val player = normalizeLanguageCode(context.playerAudioLanguage) ?: AudioLanguageOption.DEVICE
            when (player) {
                AudioLanguageOption.DEVICE ->
                    context.deviceLanguages.take(2).mapNotNullTo(wishes) { wishFor(it, fromPlayer = true) }
                AudioLanguageOption.DEFAULT -> Unit
                else -> wishFor(player, fromPlayer = true)?.let(wishes::add)
            }
            wishFor(context.playerSecondaryAudioLanguage, fromPlayer = true)?.let(wishes::add)
        } else {
            wishFor(preferences.audioLanguage, fromPlayer = false)?.let(wishes::add)
        }
        preferences.fallbackAudioLanguages.mapNotNullTo(wishes) { wishFor(it, fromPlayer = false) }
        return wishes.distinct()
    }

    /**
     * A stored preference code as a wish. Player codes follow the player's own convention ("fr" is
     * France French, "fr-ca" Québec), so they only lean; the stream settings' explicit "fr-fr" /
     * "fr-ca" ask for that version.
     */
    internal fun wishFor(raw: String?, fromPlayer: Boolean): AudioWish? {
        val code = raw?.trim()?.lowercase()?.replace('_', '-')?.takeIf { it.isNotEmpty() } ?: return null
        return when (code) {
            StreamRankingPreferences.AUDIO_AUTO, AudioLanguageOption.DEVICE, AudioLanguageOption.DEFAULT,
            SubtitleLanguageOption.NONE, SubtitleLanguageOption.FORCED,
            -> null
            AudioLanguageOption.ORIGINAL -> AudioWish.Original
            "fr-fr" -> AudioWish.Language("fr", StreamLanguageVariant.FRANCE)
            "fr-ca" -> if (fromPlayer) {
                AudioWish.Language("fr", lean = StreamLanguageVariant.QUEBEC)
            } else {
                AudioWish.Language("fr", StreamLanguageVariant.QUEBEC)
            }
            "fr" -> AudioWish.Language("fr", lean = if (fromPlayer) StreamLanguageVariant.FRANCE else null)
            "es-es" -> AudioWish.Language("es", StreamLanguageVariant.SPAIN)
            "es-419" -> if (fromPlayer) {
                AudioWish.Language("es", lean = StreamLanguageVariant.LATIN_AMERICA)
            } else {
                AudioWish.Language("es", StreamLanguageVariant.LATIN_AMERICA)
            }
            "es" -> AudioWish.Language("es", lean = if (fromPlayer) StreamLanguageVariant.SPAIN else null)
            "pt-br" -> if (fromPlayer) {
                AudioWish.Language("pt", lean = StreamLanguageVariant.BRAZIL)
            } else {
                AudioWish.Language("pt", StreamLanguageVariant.BRAZIL)
            }
            "pt-pt" -> AudioWish.Language("pt", StreamLanguageVariant.PORTUGAL)
            "pt" -> AudioWish.Language("pt", lean = if (fromPlayer) StreamLanguageVariant.PORTUGAL else null)
            else -> primaryLanguage(code)?.let { AudioWish.Language(it) }
        }
    }

    /** The subtitle language that makes an original-audio stream acceptable (VOSTFR for French). */
    fun resolveSubtitleLanguage(
        preferences: StreamRankingPreferences,
        context: StreamRankingContext,
        wishes: List<AudioWish> = resolveAudioWishes(preferences, context),
    ): String? {
        val fromWish = (wishes.firstOrNull() as? AudioWish.Language)?.language
        return when (val setting = preferences.subtitleLanguage) {
            StreamRankingPreferences.SUBTITLE_NONE -> null
            StreamRankingPreferences.SUBTITLE_AUTO -> {
                when (val player = normalizeLanguageCode(context.playerSubtitleLanguage)) {
                    null, SubtitleLanguageOption.NONE, SubtitleLanguageOption.FORCED, AudioLanguageOption.DEFAULT -> fromWish
                    SubtitleLanguageOption.DEVICE -> context.deviceLanguages.firstOrNull()?.let(::primaryLanguage) ?: fromWish
                    else -> primaryLanguage(player) ?: fromWish
                }
            }
            else -> primaryLanguage(setting) ?: fromWish
        }
    }

    private class LanguageScore(val points: Double, val reason: StreamReason?)

    private fun scoreLanguage(
        insight: StreamInsight,
        wishes: List<AudioWish>,
        preferences: StreamRankingPreferences,
        context: StreamRankingContext,
    ): LanguageScore {
        if (wishes.isEmpty()) return LanguageScore(0.0, null)
        var best = 0.0
        var bestReason: StreamReason? = null
        wishes.forEachIndexed { index, wish ->
            val base = if (index == 0) 1000.0 else max(300.0, 700.0 - 100.0 * (index - 1))
            val (quality, reason) = matchWish(wish, insight, context)
            val points = base * quality
            if (points > best || (bestReason == null && reason != null && points == best)) {
                best = points
                bestReason = reason
            }
        }

        // Original audio + subtitles in the viewer's language (VOSTFR) when no dub matched.
        val subtitleLanguage = resolveSubtitleLanguage(preferences, context, wishes)
        val primaryWish = wishes.first() as? AudioWish.Language
        val subtitles = subtitleLanguage?.let { wanted -> insight.subtitleLanguages.firstOrNull { it.language == wanted } }
        val original = context.originalLanguage
        val hasOriginalAudio = insight.includesOriginalAudio ||
            (original != null && insight.hasAudioLanguage(original)) ||
            insight.audioLanguages.isEmpty()
        if (subtitles != null && hasOriginalAudio && primaryWish != null && !insight.hasAudioLanguage(primaryWish.language)) {
            val label = if (subtitles.language == "fr") "VOSTFR" else "VOST ${subtitles.language.uppercase()}"
            if (preferences.acceptSubtitledOriginal) {
                val points = 450.0 * subtitles.confidence.weight
                if (points > best) {
                    best = points
                    bestReason = StreamReason(StreamReasonKind.SUBTITLED, label)
                }
            } else if (best < 300.0) {
                bestReason = StreamReason(StreamReasonKind.SUBTITLED, label, positive = false)
            }
        }
        if (bestReason == null && best == 0.0 && insight.audioLanguages.isNotEmpty()) {
            bestReason = StreamReason(
                StreamReasonKind.LANGUAGE_MISSING,
                insight.audioLanguages.joinToString(" ") { it.tag },
                positive = false,
            )
        }
        return LanguageScore(best, bestReason)
    }

    private fun matchWish(
        wish: AudioWish,
        insight: StreamInsight,
        context: StreamRankingContext,
    ): Pair<Double, StreamReason?> {
        val original = context.originalLanguage
        when (wish) {
            AudioWish.Original -> {
                if (original != null) {
                    insight.audioLanguages.filter { it.language == original }.maxByOrNull { it.confidence.weight }?.let {
                        return it.confidence.weight to StreamReason(StreamReasonKind.ORIGINAL_LANGUAGE, "VO")
                    }
                }
                insight.originalAudioConfidence?.let {
                    return 0.9 * it.weight to StreamReason(StreamReasonKind.ORIGINAL_LANGUAGE, "VO")
                }
                if (insight.audioLanguages.isEmpty()) {
                    return 0.6 to StreamReason(StreamReasonKind.ORIGINAL_LANGUAGE, "VO")
                }
                if (original == null && insight.hasAudioLanguage("en")) {
                    return 0.5 to StreamReason(StreamReasonKind.ORIGINAL_LANGUAGE, "EN")
                }
                return 0.0 to null
            }
            is AudioWish.Language -> {
                val matches = insight.audioLanguages.filter { it.language == wish.language }
                if (matches.isEmpty()) {
                    if (original == wish.language) {
                        insight.originalAudioConfidence?.let {
                            return 0.85 * it.weight to StreamReason(StreamReasonKind.LANGUAGE, wish.language.uppercase())
                        }
                        if (insight.audioLanguages.isEmpty()) {
                            // Untagged releases are, in practice, the original version.
                            return 0.75 to StreamReason(StreamReasonKind.LANGUAGE, wish.language.uppercase())
                        }
                    }
                    return 0.0 to null
                }
                var bestQuality = 0.0
                var bestReason: StreamReason? = null
                matches.forEach { match ->
                    val confidence = match.confidence.weight
                    val (quality, reason) = if (wish.variant != null) {
                        when {
                            match.variant == wish.variant ->
                                confidence to StreamReason(StreamReasonKind.LANGUAGE, match.tag)
                            wish.variant == StreamLanguageVariant.FRANCE && match.variant == StreamLanguageVariant.INTERNATIONAL ->
                                0.85 * confidence to StreamReason(StreamReasonKind.LANGUAGE, match.tag)
                            match.variant == StreamLanguageVariant.UNSPECIFIED ->
                                0.7 * confidence to StreamReason(StreamReasonKind.LANGUAGE, match.tag)
                            else ->
                                // Still a French dub, just not the accent asked for: above
                                // subtitles (0.45), well below the wanted version.
                                0.5 * confidence to StreamReason(StreamReasonKind.OTHER_VARIANT, match.tag, positive = false)
                        }
                    } else {
                        var value = confidence
                        val lean = wish.lean
                        if (lean != null && match.variant != StreamLanguageVariant.UNSPECIFIED) {
                            value += when {
                                match.variant == lean -> 0.04
                                lean == StreamLanguageVariant.FRANCE && match.variant == StreamLanguageVariant.INTERNATIONAL -> 0.0
                                else -> -0.06
                            }
                        }
                        value to StreamReason(StreamReasonKind.LANGUAGE, match.tag)
                    }
                    if (quality > bestQuality) {
                        bestQuality = quality
                        bestReason = reason
                    }
                }
                return bestQuality to bestReason
            }
        }
    }

    // endregion

    private fun scoreHdr(
        insight: StreamInsight,
        preferences: StreamRankingPreferences,
        context: StreamRankingContext,
    ): Pair<Double, StreamReason?> {
        if (!insight.hasHdr) return 0.0 to null
        if (preferences.hdrMode == StreamRankingPreferences.HDR_AVOID) {
            return -60.0 to StreamReason(StreamReasonKind.HDR_AVOIDED, insight.primaryHdr?.label.orEmpty(), positive = false)
        }
        val boost = if (preferences.hdrMode == StreamRankingPreferences.HDR_PREFER) 2.0 else 1.0
        if (!context.supportsHdr) {
            // Tone-mapped down to SDR: still watchable, just not better than an SDR release.
            return -15.0 to StreamReason(StreamReasonKind.HDR_UNSUPPORTED, insight.primaryHdr?.label.orEmpty(), positive = false)
        }
        if (insight.hasDolbyVision) {
            if (context.supportsDolbyVision) return 45.0 * boost to null
            // DV without a native DV path: fine with an HDR10 base layer, wrong colours without (profile 5).
            val hasFallback = StreamHdrFormat.HDR10 in insight.hdrFormats || StreamHdrFormat.HDR10_PLUS in insight.hdrFormats ||
                insight.dolbyVisionProfile?.startsWith("8") == true || insight.dolbyVisionProfile?.startsWith("7") == true
            return if (hasFallback) {
                25.0 * boost to null
            } else {
                -40.0 to StreamReason(StreamReasonKind.HDR_UNSUPPORTED, "DV", positive = false)
            }
        }
        val points = when (insight.primaryHdr) {
            StreamHdrFormat.HDR10_PLUS -> 35.0
            StreamHdrFormat.HDR10, StreamHdrFormat.HDR -> 30.0
            StreamHdrFormat.HLG -> 15.0
            else -> 0.0
        }
        return points * boost to null
    }

    internal fun primaryLanguage(code: String?): String? {
        val normalized = normalizeLanguageCode(code) ?: return null
        val primary = normalized.substringBefore('-')
        return primary.takeIf { it.length in 2..3 && it.all { char -> char in 'a'..'z' } }
    }
}

/**
 * Fork (STREAM-INSIGHT): the audio-language targets for the player once a stream is chosen — the
 * stream settings' explicit version first ("fr-ca" for a Québec viewer, so a MULTi VFF+VFQ file
 * starts on the VFQ track), then the player's own targets. Wiring: the player's audio-target
 * resolution (tvOS `PlayerAudioLanguagePlan.audioTargets`) passes its targets through
 * [audioTargets]; with the feature off or "Same as audio language" it returns them unchanged.
 */
object StreamPlaybackLanguageHints {

    fun audioTargets(
        streamName: String?,
        streamDescription: String?,
        url: String?,
        baseTargets: List<String>,
        originalLanguage: String?,
    ): List<String> {
        val preferences = StreamRankingSettingsRepository.snapshot()
        val insight = StreamInsightParser.parseText(streamName, streamDescription, streamDescription, url = url)
        return audioTargets(insight, preferences, baseTargets, originalLanguage)
    }

    fun audioTargets(
        insight: StreamInsight,
        preferences: StreamRankingPreferences,
        baseTargets: List<String>,
        originalLanguage: String?,
    ): List<String> {
        if (!preferences.enabled || preferences.audioLanguage == StreamRankingPreferences.AUDIO_AUTO) return baseTargets
        val original = StreamRecommender.primaryLanguage(originalLanguage)
        val context = StreamRankingContext(originalLanguage = original)
        val wishes = StreamRecommender.resolveAudioWishes(preferences, context)
        val hints = mutableListOf<String>()
        for (wish in wishes) {
            when (wish) {
                StreamRecommender.AudioWish.Original -> original?.let(hints::add)
                is StreamRecommender.AudioWish.Language -> {
                    val inStream = insight.hasAudioLanguage(wish.language) ||
                        (insight.audioLanguages.isEmpty() && !insight.includesOriginalAudio)
                    if (!inStream) continue
                    val variant = wish.variant ?: insight.audioLanguages
                        .firstOrNull { it.language == wish.language && it.variant == wish.lean }?.variant
                    hints += StreamLanguage(wish.language, variant ?: StreamLanguageVariant.UNSPECIFIED).playerTarget
                }
            }
            if (hints.isNotEmpty()) break
        }
        // No wanted dub, but the original with subtitles was accepted: start on the original.
        if (hints.isEmpty() && preferences.acceptSubtitledOriginal && original != null &&
            (insight.includesOriginalAudio || insight.hasAudioLanguage(original))
        ) {
            hints += original
        }
        return (hints + baseTargets).distinct()
    }
}
