package com.nuvio.app.features.streams

/*
 * Fork (STREAM-INSIGHT): what an add-on stream actually is, read out of its messy title.
 *
 * Add-ons (Torrentio, Comet, MediaFusion, Jackett-based ones, debrid add-ons…) describe a stream
 * with free text: a scene release name, emoji-keyed metadata lines ("👤 45 💾 2.3 GB ⚙️ YggTorrent"),
 * flag emoji for languages and bracketed debrid markers ("[RD+]"). [StreamInsightParser] turns all
 * of that into this structured value; [StreamRecommender] ranks streams with it, and the tvOS
 * picker renders it as a clean row (quality line, language chips, size, provider).
 *
 * Language deductions carry a [StreamConfidence]: a "VFF" tag is certain, a lone 🇨🇦 flag is a
 * guess. French variants are never assumed — plain "FRENCH"/"VF"/"FR" stays
 * [StreamLanguageVariant.UNSPECIFIED] ("VF"), it is NOT read as VFF.
 */

enum class StreamResolution(val rank: Int, val label: String) {
    UNKNOWN(0, ""),
    SD(1, "SD"),
    P480(2, "480p"),
    P720(3, "720p"),
    P1080(4, "1080p"),
    P1440(5, "1440p"),
    P2160(6, "4K"),
    ;

    /** Vertical line count, for the "max resolution" preference (0 when unknown). */
    val lines: Int
        get() = when (this) {
            UNKNOWN -> 0
            SD -> 360
            P480 -> 480
            P720 -> 720
            P1080 -> 1080
            P1440 -> 1440
            P2160 -> 2160
        }
}

enum class StreamSourceKind(val rank: Int, val label: String, val isLowQuality: Boolean) {
    UNKNOWN(0, "", false),
    CAM(-4, "CAM", true),
    TELESYNC(-3, "TS", true),
    TELECINE(-2, "TC", true),
    SCREENER(-1, "SCR", true),
    DVDRIP(1, "DVDRip", false),
    HDTV(2, "HDTV", false),
    WEBRIP(3, "WEBRip", false),
    WEB_DL(4, "WEB-DL", false),
    BLURAY(5, "BluRay", false),
    REMUX(6, "REMUX", false),
}

enum class StreamVideoCodec(val label: String) {
    HEVC("HEVC"),
    AVC("AVC"),
    AV1("AV1"),
    VP9("VP9"),
    XVID("XviD"),
    MPEG2("MPEG-2"),
}

enum class StreamHdrFormat(val label: String) {
    DOLBY_VISION("Dolby Vision"),
    HDR10_PLUS("HDR10+"),
    HDR10("HDR10"),
    HLG("HLG"),
    /** "HDR" without saying which. */
    HDR("HDR"),
}

enum class StreamAudioCodec(val label: String, val rank: Int) {
    TRUEHD("TrueHD", 9),
    DTS_X("DTS:X", 9),
    DTS_HD_MA("DTS-HD MA", 8),
    FLAC("FLAC", 7),
    LPCM("PCM", 7),
    DTS_HD("DTS-HD", 6),
    EAC3("DD+", 5),
    DTS("DTS", 4),
    AC3("DD", 3),
    OPUS("Opus", 3),
    AAC("AAC", 2),
    MP3("MP3", 1),
}

/**
 * Regional variant of an audio/subtitle language. French: FRANCE = VFF/TRUEFRENCH,
 * QUEBEC = VFQ, INTERNATIONAL = VFI, UNSPECIFIED = "VF"/"FRENCH"/"FR"/🇫🇷 (variant unknown).
 */
enum class StreamLanguageVariant {
    UNSPECIFIED,
    FRANCE,
    QUEBEC,
    INTERNATIONAL,
    SPAIN,
    LATIN_AMERICA,
    BRAZIL,
    PORTUGAL,
}

enum class StreamConfidence(val weight: Double) {
    HIGH(1.0),
    MEDIUM(0.85),
    LOW(0.6),
}

enum class StreamCacheState {
    CACHED,
    NOT_CACHED,
    UNKNOWN,
}

data class StreamLanguage(
    /** ISO 639-1 primary code ("fr", "en", "es", "pt", "ja"…). */
    val language: String,
    val variant: StreamLanguageVariant = StreamLanguageVariant.UNSPECIFIED,
    val confidence: StreamConfidence = StreamConfidence.MEDIUM,
    /** What the deduction was read from ("VFF", "🇫🇷", "MULTi", "FRENCH"…), for diagnostics. */
    val evidence: List<String> = emptyList(),
) {
    /** BCP 47-ish code: "fr-FR", "fr-CA", "es-419", "pt-BR"… ("fr" when the variant is unknown). */
    val code: String
        get() = when (variant) {
            StreamLanguageVariant.FRANCE -> "$language-FR"
            StreamLanguageVariant.QUEBEC -> "$language-CA"
            StreamLanguageVariant.SPAIN -> "$language-ES"
            StreamLanguageVariant.LATIN_AMERICA -> "$language-419"
            StreamLanguageVariant.BRAZIL -> "$language-BR"
            StreamLanguageVariant.PORTUGAL -> "$language-PT"
            StreamLanguageVariant.INTERNATIONAL,
            StreamLanguageVariant.UNSPECIFIED,
            -> language
        }

    /**
     * Short release-style tag: "VFF", "VFQ", "VFI", "VF" for French (the jargon French viewers
     * read at a glance), "LAT"/"CAST" for Spanish, "PT-BR"/"PT-PT", else the upper-case code.
     */
    val tag: String
        get() = when {
            language == "fr" -> when (variant) {
                StreamLanguageVariant.FRANCE -> "VFF"
                StreamLanguageVariant.QUEBEC -> "VFQ"
                StreamLanguageVariant.INTERNATIONAL -> "VFI"
                else -> "VF"
            }
            variant == StreamLanguageVariant.LATIN_AMERICA -> "LAT"
            variant == StreamLanguageVariant.SPAIN -> "CAST"
            variant == StreamLanguageVariant.BRAZIL -> "PT-BR"
            variant == StreamLanguageVariant.PORTUGAL -> "PT-PT"
            else -> language.uppercase()
        }

    /**
     * The language target in the player's own convention ([com.nuvio.app.features.player
     * .normalizeLanguageCode] output): "fr" = France French, "fr-ca" = Québec, "es-419", "pt-br".
     */
    val playerTarget: String
        get() = when (variant) {
            StreamLanguageVariant.QUEBEC -> "$language-ca"
            StreamLanguageVariant.LATIN_AMERICA -> "$language-419"
            StreamLanguageVariant.BRAZIL -> "$language-br"
            else -> language
        }
}

data class StreamInsight(
    val resolution: StreamResolution = StreamResolution.UNKNOWN,
    val source: StreamSourceKind = StreamSourceKind.UNKNOWN,
    val videoCodec: StreamVideoCodec? = null,
    val hdrFormats: List<StreamHdrFormat> = emptyList(),
    /** "5", "7", "8.1", "7 FEL"… when the release states it. */
    val dolbyVisionProfile: String? = null,
    /** The release explicitly says SDR. */
    val isSdr: Boolean = false,
    val is3D: Boolean = false,
    val bitDepth: Int? = null,
    val audioCodecs: List<StreamAudioCodec> = emptyList(),
    val hasAtmos: Boolean = false,
    /** "2.0", "5.1", "7.1"… */
    val audioChannels: String? = null,
    val audioLanguages: List<StreamLanguage> = emptyList(),
    val subtitleLanguages: List<StreamLanguage> = emptyList(),
    /** VO / VOST / MULTi / DUAL: the original-language track is (probably) in the file. */
    val includesOriginalAudio: Boolean = false,
    val originalAudioConfidence: StreamConfidence? = null,
    val isMultiAudio: Boolean = false,
    val isDualAudio: Boolean = false,
    val hasMultiSubtitles: Boolean = false,
    val hasHardcodedSubtitles: Boolean = false,
    /** A scene "DUBBED" release with no other track named: the original audio is not in the file. */
    val isDubbed: Boolean = false,
    val sizeBytes: Long? = null,
    val seeders: Int? = null,
    val peers: Int? = null,
    /** Tracker / indexer / site the release came from ("YggTorrent", "ThePirateBay"). */
    val provider: String? = null,
    val cacheState: StreamCacheState = StreamCacheState.UNKNOWN,
    /** Debrid service short code ("RD", "AD", "TB", "PM"…) when the stream names one. */
    val debridService: String? = null,
    val seasons: List<Int> = emptyList(),
    val episodes: List<Int> = emptyList(),
    val isSeasonPack: Boolean = false,
    val releaseGroup: String? = null,
    /** The release name as the add-on gave it, emoji removed (for "show the original title"). */
    val releaseName: String? = null,
    /** A plain playable http(s) link (no resolve step). */
    val isDirectLink: Boolean = false,
    /** A torrent / magnet that still needs a debrid resolve or P2P. */
    val isTorrent: Boolean = false,
) {
    val isLowQuality: Boolean
        get() = source.isLowQuality

    val hasHdr: Boolean
        get() = hdrFormats.isNotEmpty()

    val hasDolbyVision: Boolean
        get() = StreamHdrFormat.DOLBY_VISION in hdrFormats

    /** The headline HDR format: Dolby Vision, else HDR10+, HDR10, HLG, generic HDR. */
    val primaryHdr: StreamHdrFormat?
        get() = listOf(
            StreamHdrFormat.DOLBY_VISION,
            StreamHdrFormat.HDR10_PLUS,
            StreamHdrFormat.HDR10,
            StreamHdrFormat.HLG,
            StreamHdrFormat.HDR,
        ).firstOrNull { it in hdrFormats }

    val bestAudioCodec: StreamAudioCodec?
        get() = audioCodecs.maxByOrNull { it.rank }

    /** "Atmos", "TrueHD 7.1", "DD+ 5.1", "AAC 2.0"… nil when nothing about the audio is known. */
    val audioSummary: String?
        get() {
            if (hasAtmos) return "Atmos"
            val codec = bestAudioCodec?.label
            return listOfNotNull(codec, audioChannels).joinToString(" ").takeIf { it.isNotBlank() }
        }

    /**
     * "4K · Dolby Vision · Atmos", "1080p · HDR10 · DD+ 5.1", "CAM · 720p". Technical labels,
     * identical in every UI language. Empty when the title says nothing technical.
     */
    val qualitySummary: String
        get() {
            val parts = mutableListOf<String>()
            if (source.isLowQuality) parts += source.label
            if (resolution != StreamResolution.UNKNOWN) parts += resolution.label
            primaryHdr?.let { parts += it.label }
            if (is3D) parts += "3D"
            audioSummary?.let { parts += it }
            if (source == StreamSourceKind.REMUX) parts += source.label
            return parts.joinToString(" · ")
        }

    /** "4K DV", "1080p HDR10", "4K" — the compact quality reason used by the recommender. */
    val compactQualityLabel: String
        get() {
            val hdr = when (primaryHdr) {
                StreamHdrFormat.DOLBY_VISION -> "DV"
                null -> null
                else -> primaryHdr?.label
            }
            return listOfNotNull(resolution.label.takeIf { it.isNotEmpty() }, hdr).joinToString(" ")
        }

    /** Episode info: "S01E05", "S01E05-E07", "S01 (pack)" style compact label; nil for movies. */
    val episodeLabel: String?
        get() {
            if (seasons.isEmpty() && episodes.isEmpty()) return null
            fun two(value: Int) = if (value < 10) "0$value" else value.toString()
            val seasonPart = when {
                seasons.size > 1 -> "S${two(seasons.min())}-S${two(seasons.max())}"
                seasons.size == 1 -> "S${two(seasons.first())}"
                else -> ""
            }
            val episodePart = when {
                episodes.size > 1 -> "E${two(episodes.min())}-E${two(episodes.max())}"
                episodes.size == 1 -> "E${two(episodes.first())}"
                else -> ""
            }
            return (seasonPart + episodePart).takeIf { it.isNotEmpty() }
        }

    fun hasAudioLanguage(language: String): Boolean = audioLanguages.any { it.language == language }

    fun hasSubtitleLanguage(language: String): Boolean = subtitleLanguages.any { it.language == language }
}
