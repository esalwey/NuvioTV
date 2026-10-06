package com.nuvio.app.features.streams

import com.nuvio.app.features.player.normalizeLanguageCode
import com.nuvio.app.features.player.stripLanguageDiacritics

/**
 * Everything [StreamInsightParser] reads. Built from a [StreamItem] by [StreamInsightParser.inputFor];
 * tests and the player build it directly from strings.
 */
data class StreamInsightInput(
    /** Add-on stream `name` ("[RD+] Torrentio\n4k DV | HDR"). */
    val name: String? = null,
    val title: String? = null,
    val description: String? = null,
    /** `behaviorHints.filename`. */
    val filename: String? = null,
    /** `behaviorHints.videoSize`. */
    val videoSize: Long? = null,
    /** `behaviorHints.bingeGroup` (technical hints only, never languages). */
    val bingeGroup: String? = null,
    /** Playable / external URL; its last path segment is read when no filename is given. */
    val url: String? = null,
    /** Other names for the same release (debrid cached name, clientResolve torrent/file names). */
    val extraReleaseNames: List<String> = emptyList(),
    /** Structured fields some debrid add-ons send (`clientResolve.stream.raw.parsed`). */
    val parsed: StreamClientResolveParsed? = null,
    val tracker: String? = null,
    /** Size from structured data other than videoSize (debrid cache check, clientResolve). */
    val sizeHint: Long? = null,
    /** The in-app debrid cache check, when one ran. */
    val debridCacheState: StreamDebridCacheState? = null,
    val debridProviderName: String? = null,
    val clientResolveCached: Boolean? = null,
    /** Languages of subtitles the add-on attached to the stream. */
    val subtitleLanguages: List<String> = emptyList(),
    val isTorrent: Boolean = false,
    val isDirectLink: Boolean = false,
)

/**
 * Fork (STREAM-INSIGHT): reads resolution, source, codecs, HDR, audio, languages (with French /
 * Spanish / Portuguese variants), subtitles, size, seeders, provider, debrid cache state, episode
 * info and release group out of add-on stream text. See [StreamInsight] for the output.
 *
 * Matching is token based: tokens are runs of letters/digits, so "FR" never matches inside
 * "FRENCH", "VO" never inside "VOSTFR" or "VOD", "VF" never inside "VFF". Ambiguous words
 * (language names, short codes, CAM/TS) only count after a release "anchor" (a year, a
 * resolution, SxxEyy, a source or codec tag) or on a line that is clearly about languages (flag
 * emoji, 🌐/🗣️/🔊 markers, "Audio: …", the add-on's own stream name) — so "The French Dispatch",
 * "Cam (2018)" or "Step Up 3D" are not read as tags.
 */
object StreamInsightParser {

    fun parse(stream: StreamItem): StreamInsight = parse(inputFor(stream))

    /** Convenience for callers that only hold strings (the player, tests). */
    fun parseText(
        name: String?,
        title: String?,
        description: String?,
        filename: String? = null,
        videoSize: Long? = null,
        url: String? = null,
    ): StreamInsight = parse(
        StreamInsightInput(
            name = name,
            title = title,
            description = description,
            filename = filename,
            videoSize = videoSize,
            url = url,
        ),
    )

    fun inputFor(stream: StreamItem): StreamInsightInput {
        val resolve = stream.clientResolve
        val raw = resolve?.stream?.raw
        return StreamInsightInput(
            name = stream.name,
            title = stream.title,
            description = stream.description,
            filename = stream.behaviorHints.filename,
            videoSize = stream.behaviorHints.videoSize,
            bingeGroup = stream.behaviorHints.bingeGroup,
            url = stream.playableDirectUrl ?: stream.externalOpenUrl,
            extraReleaseNames = listOfNotNull(
                raw?.filename,
                resolve?.filename,
                raw?.torrentName,
                resolve?.torrentName,
                stream.debridCacheStatus?.cachedName,
                raw?.parsed?.rawTitle,
            ),
            parsed = raw?.parsed,
            tracker = raw?.tracker ?: raw?.indexer,
            sizeHint = stream.debridCacheStatus?.cachedSize ?: raw?.size ?: raw?.folderSize,
            debridCacheState = stream.debridCacheStatus?.state,
            debridProviderName = stream.debridCacheStatus?.providerName,
            clientResolveCached = resolve?.isCached,
            subtitleLanguages = stream.externalSubtitles.map { it.language },
            isTorrent = stream.isTorrentStream,
            isDirectLink = stream.playableDirectUrl != null,
        )
    }

    fun parse(input: StreamInsightInput): StreamInsight {
        val lines = buildLines(input)
        val acc = Accumulator()
        for (line in lines) {
            if (line.role != LineRole.TECH_ONLY) readLanguages(line, acc)
            readTechnical(line, acc)
            if (line.role != LineRole.TECH_ONLY) {
                readEpisodes(line, acc)
                readMetadata(line, acc)
            }
        }
        readStructured(input, acc)
        val (audio, subtitles) = finalizeLanguages(acc)
        val (cacheState, service) = readCache(input)
        val releaseName = pickReleaseName(input)
        return StreamInsight(
            resolution = acc.resolutions.maxByOrNull { it.rank } ?: StreamResolution.UNKNOWN,
            source = pickSource(acc.sources),
            videoCodec = acc.videoCodecs.firstOrNull(),
            hdrFormats = finalizeHdr(acc.hdr),
            dolbyVisionProfile = acc.dvProfile?.let { profile ->
                if (acc.dvLayer != null && !profile.contains(' ')) "$profile ${acc.dvLayer}" else profile
            } ?: acc.dvLayer?.let { "7 $it" },
            isSdr = acc.sdr && acc.hdr.isEmpty(),
            is3D = acc.threeD,
            bitDepth = acc.bitDepth,
            audioCodecs = finalizeAudioCodecs(acc.audioCodecs),
            hasAtmos = acc.atmos,
            audioChannels = acc.channels.maxByOrNull { channelRank(it) },
            audioLanguages = audio,
            subtitleLanguages = subtitles,
            includesOriginalAudio = acc.original != null,
            originalAudioConfidence = acc.original,
            isMultiAudio = acc.multi,
            isDualAudio = acc.dual,
            hasMultiSubtitles = acc.multiSubs,
            hasHardcodedSubtitles = acc.hardSubs,
            sizeBytes = input.videoSize?.takeIf { it > 0 }
                ?: input.sizeHint?.takeIf { it > 0 }
                ?: acc.markedSize
                ?: acc.textSize,
            seeders = acc.seeders,
            peers = acc.peers,
            provider = acc.provider ?: input.tracker?.trim()?.takeIf { it.isNotEmpty() },
            cacheState = cacheState,
            debridService = service ?: input.debridProviderName?.trim()?.takeIf { it.isNotEmpty() },
            seasons = acc.seasons.toList().sorted(),
            episodes = acc.episodes.toList().sorted(),
            isSeasonPack = (acc.seasons.isNotEmpty() && acc.episodes.isEmpty()) || acc.seasons.size > 1 ||
                (acc.complete && acc.episodes.isEmpty()),
            releaseGroup = releaseName?.let(::extractReleaseGroup) ?: input.parsed?.group?.trim()?.takeIf { it.isNotEmpty() },
            releaseName = releaseName,
            isDirectLink = input.isDirectLink,
            isTorrent = input.isTorrent,
        )
    }

    // region Lines and tokens

    private enum class LineRole {
        /** The add-on's own stream name: always about the stream, never a movie title. */
        ADDON_NAME,

        /** A release name or an add-on description line (may contain the movie title). */
        RELEASE,

        /** Text we synthesized from structured fields. */
        STRUCTURED,

        /** bingeGroup: technical hints only. */
        TECH_ONLY,
    }

    private class Tok(val raw: String, val start: Int, val end: Int) {
        val upper: String = raw.uppercase()
        val folded: String = stripLanguageDiacritics(raw.lowercase())
        val isUpperCase: Boolean = raw.any { it.isLetter() } && raw == upper
    }

    private class Line(
        val text: String,
        val role: LineRole,
        val flags: List<String>,
        val languageMarker: Boolean,
        val subtitleMarker: Boolean,
        val audioMarker: Boolean,
    ) {
        val tokens: List<Tok> = tokenize(text)
        val anchorIndex: Int = tokens.indexOfFirst { isAnchorToken(it) }

        /** Text between token [i] and token [i]+1 ("" when adjacent or at the end). */
        fun separatorAfter(i: Int): String {
            val next = tokens.getOrNull(i + 1) ?: return ""
            return text.substring(tokens[i].end, next.start)
        }
    }

    private const val SEEDERS_MARK = '¶'   // ¶  ← 👤 👥 🌱
    private const val PROVIDER_MARK = '¤'  // ¤  ← ⚙️ 🔎 🔍 🔗
    private const val SIZE_MARK = '§'      // §  ← 💾
    private const val RATING_MARK = '¦'    // ¦  ← ⭐ 🌟

    private fun buildLines(input: StreamInsightInput): List<Line> {
        val result = mutableListOf<Line>()
        val seen = HashSet<String>()
        fun add(text: String?, role: LineRole) {
            if (text.isNullOrBlank()) return
            text.split('\n').forEach { rawLine ->
                val line = prepareLine(rawLine, role) ?: return@forEach
                val key = "${role.name}|${line.text.trim().lowercase()}|${line.flags.joinToString()}"
                if (seen.add(key)) result += line
            }
        }
        add(input.name, LineRole.ADDON_NAME)
        add(input.title, LineRole.RELEASE)
        add(input.description, LineRole.RELEASE)
        add(input.filename, LineRole.RELEASE)
        input.extraReleaseNames.forEach { add(it, LineRole.RELEASE) }
        if (input.filename.isNullOrBlank()) add(urlFileName(input.url), LineRole.RELEASE)
        input.parsed?.let { parsed ->
            val technical = listOfNotNull(
                parsed.resolution,
                parsed.quality,
                parsed.codec,
                parsed.bitDepth,
            ) + parsed.hdr + parsed.audio + parsed.channels
            add(technical.joinToString(" "), LineRole.STRUCTURED)
        }
        add(input.bingeGroup, LineRole.TECH_ONLY)
        return result
    }

    /** Emoji turned into markers/spaces, flags collected, URLs dropped. Null for an empty line. */
    private fun prepareLine(raw: String, role: LineRole): Line? {
        val builder = StringBuilder(raw.length + 8)
        val flags = mutableListOf<String>()
        var languageMarker = false
        var subtitleMarker = false
        var audioMarker = false
        var index = 0
        while (index < raw.length) {
            val char = raw[index]
            if (char.isHighSurrogate() && index + 1 < raw.length && raw[index + 1].isLowSurrogate()) {
                val codePoint = StreamInsightText.toCodePoint(char, raw[index + 1])
                if (codePoint in 0x1F1E6..0x1F1FF) {
                    val hasPair = index + 3 < raw.length && raw[index + 2].isHighSurrogate() && raw[index + 3].isLowSurrogate()
                    val second = if (hasPair) StreamInsightText.toCodePoint(raw[index + 2], raw[index + 3]) else -1
                    if (second in 0x1F1E6..0x1F1FF) {
                        flags += "${'A' + (codePoint - 0x1F1E6)}${'A' + (second - 0x1F1E6)}"
                        builder.append(' ')
                        index += 4
                        continue
                    }
                    builder.append(' ')
                    index += 2
                    continue
                }
                when (codePoint) {
                    0x1F464, 0x1F465, 0x1F331 -> builder.append(" $SEEDERS_MARK ")
                    0x1F50E, 0x1F50D, 0x1F517 -> builder.append(" $PROVIDER_MARK ")
                    0x1F4BE, 0x1F4E6 -> builder.append(" $SIZE_MARK ")
                    0x1F31F -> builder.append(" $RATING_MARK ")
                    0x1F310, 0x1F5E3, 0x1F30D, 0x1F30E, 0x1F30F, 0x1F399, 0x1F3F3 -> {
                        languageMarker = true
                        builder.append(' ')
                    }
                    0x1F50A, 0x1F509, 0x1F508, 0x1F3A7, 0x1F3B5, 0x1F3B6 -> {
                        audioMarker = true
                        builder.append(' ')
                    }
                    0x1F4AC, 0x1F4DD, 0x1F5E8 -> {
                        subtitleMarker = true
                        builder.append(' ')
                    }
                    else -> builder.append(' ')
                }
                index += 2
                continue
            }
            when {
                char.code == 0x2699 -> builder.append(" $PROVIDER_MARK ")
                char.code == 0x2B50 -> builder.append(" $RATING_MARK ")
                char == SEEDERS_MARK || char == PROVIDER_MARK || char == SIZE_MARK || char == RATING_MARK ->
                    builder.append(' ')
                StreamInsightText.isEmojiCodePoint(char.code) -> builder.append(' ')
                else -> builder.append(char)
            }
            index += 1
        }
        var text = builder.toString()
        text = URL_REGEX.replace(text, " ")
        text = WWW_REGEX.replace(text, " ")
        text = BRACKETED_DOMAIN_REGEX.replace(text, " ")
        if (text.isBlank() && flags.isEmpty()) return null
        return Line(text, role, flags, languageMarker, subtitleMarker, audioMarker)
    }

    private val URL_REGEX = Regex("(?i)https?://\\S+")
    private val WWW_REGEX = Regex("(?i)www\\.[^\\s\\]\\)]+")
    private val BRACKETED_DOMAIN_REGEX = Regex(
        "(?i)[\\[\\(\\{]\\s*[^\\]\\)\\}]{0,40}\\.(com|net|org|fr|io|to|tv|ws|cc|me|ag|si|ch|biz|info|xyz|lol|nz|se|li|cx|vip|site|club|pw|cam|is|la|ec|sx|mx)\\s*[\\]\\)\\}]",
    )

    private fun tokenize(text: String): List<Tok> {
        val tokens = mutableListOf<Tok>()
        var start = -1
        for (index in text.indices) {
            if (text[index].isLetterOrDigit()) {
                if (start < 0) start = index
            } else if (start >= 0) {
                tokens += Tok(text.substring(start, index), start, index)
                start = -1
            }
        }
        if (start >= 0) tokens += Tok(text.substring(start), start, text.length)
        return tokens
    }

    private fun urlFileName(url: String?): String? {
        val trimmed = url?.trim()?.takeIf { it.startsWith("http", ignoreCase = true) } ?: return null
        val path = trimmed.substringBefore('?').substringBefore('#')
        val segment = path.substringAfterLast('/').takeIf { it.isNotBlank() } ?: return null
        val decoded = percentDecode(segment)
        // Only a file-like segment is worth reading ("Movie.2020.1080p.mkv"), not an opaque id.
        return decoded.takeIf { it.count { c -> c == '.' || c == ' ' } >= 2 }
    }

    private fun percentDecode(value: String): String {
        if ('%' !in value && '+' !in value) return value
        val bytes = ArrayList<Byte>(value.length)
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char == '%' && index + 2 < value.length) {
                val hex = value.substring(index + 1, index + 3).toIntOrNull(16)
                if (hex != null) {
                    bytes += hex.toByte()
                    index += 3
                    continue
                }
            }
            if (char == '+') {
                bytes += ' '.code.toByte()
            } else {
                char.toString().encodeToByteArray().forEach { bytes += it }
            }
            index += 1
        }
        return bytes.toByteArray().decodeToString()
    }

    // endregion

    // region Anchors

    private val RESOLUTION_TOKENS = setOf(
        "2160P", "2160I", "4K", "UHD", "4KUHD", "1440P", "QHD", "1080P", "1080I", "FHD", "FULLHD",
        "720P", "720I", "576P", "576I", "480P", "480I", "360P", "240P",
    )
    private val SOURCE_ANCHORS = setOf(
        "BLURAY", "BDRIP", "BRRIP", "BDREMUX", "REMUX", "UHDREMUX", "BDMV", "WEB", "WEBDL", "WEBRIP",
        "HDTV", "PDTV", "DVDRIP", "HDRIP", "UHDRIP", "DVD", "TVRIP", "SATRIP",
    )
    private val CODEC_ANCHORS = setOf(
        "X264", "X265", "H264", "H265", "HEVC", "AVC", "AV1", "XVID", "DIVX", "10BIT", "HDR", "HDR10",
        "DV", "DOVI",
    )
    private val RES_DIMENSION_REGEX = Regex("^(\\d{3,4})X(\\d{3,4})$")
    private val EPISODE_TOKEN_REGEX = Regex("^S(\\d{1,2})(?:E(\\d{1,3}))?(?:E(\\d{1,3}))?$")
    private val CROSS_EPISODE_REGEX = Regex("^(\\d{1,2})X(\\d{2,3})$")

    private fun isAnchorToken(token: Tok): Boolean {
        val upper = token.upper
        if (upper.length == 4 && upper.all { it.isDigit() }) {
            val year = upper.toInt()
            if (year in 1900..2099) return true
        }
        if (upper in RESOLUTION_TOKENS || upper in SOURCE_ANCHORS || upper in CODEC_ANCHORS) return true
        if (RES_DIMENSION_REGEX.matches(upper)) return true
        if (EPISODE_TOKEN_REGEX.matches(upper) || CROSS_EPISODE_REGEX.matches(upper)) return true
        if (upper == "COMPLETE" || upper == "INTEGRALE" || upper == "INTEGRAL") return true
        val spec = LANGUAGE_SPECS[token.folded]
        if (spec != null && spec.tierA) return true
        return token.folded in SUBTITLE_COMBINED
    }

    // endregion

    // region Languages

    private enum class SpecKind { LANGUAGE, MULTI, DUAL, ORIGINAL }

    private class LanguageSpec(
        val targets: List<Pair<String, StreamLanguageVariant>>,
        val confidence: StreamConfidence,
        /** Counts anywhere (unambiguous release tag); otherwise only after an anchor / on a language line. */
        val tierA: Boolean,
        /** Only an all-caps token counts ("FR", not "Fr"). */
        val upperOnly: Boolean = false,
        /** An explicit dub tag (VFF, VFQ, TRUEFRENCH…) — survives a VOSTFR in the same title. */
        val explicitDub: Boolean = false,
        val original: StreamConfidence? = null,
        val kind: SpecKind = SpecKind.LANGUAGE,
    )

    private val U = StreamLanguageVariant.UNSPECIFIED
    private val HIGH = StreamConfidence.HIGH
    private val MEDIUM = StreamConfidence.MEDIUM
    private val LOW = StreamConfidence.LOW

    private fun lang(
        code: String,
        variant: StreamLanguageVariant = StreamLanguageVariant.UNSPECIFIED,
        confidence: StreamConfidence = StreamConfidence.HIGH,
        tierA: Boolean = false,
        upperOnly: Boolean = false,
        explicitDub: Boolean = false,
        original: StreamConfidence? = null,
    ) = LanguageSpec(listOf(code to variant), confidence, tierA, upperOnly, explicitDub, original)

    private val LANGUAGE_SPECS: Map<String, LanguageSpec> = buildMap {
        // French release tags (critical: the variant is only ever what the tag says).
        put("vff", lang("fr", StreamLanguageVariant.FRANCE, tierA = true, explicitDub = true))
        put("truefrench", lang("fr", StreamLanguageVariant.FRANCE, tierA = true, explicitDub = true))
        put("vfq", lang("fr", StreamLanguageVariant.QUEBEC, tierA = true, explicitDub = true))
        put("vfi", lang("fr", StreamLanguageVariant.INTERNATIONAL, tierA = true, explicitDub = true))
        put(
            "vf2",
            LanguageSpec(
                listOf("fr" to StreamLanguageVariant.FRANCE, "fr" to StreamLanguageVariant.QUEBEC),
                HIGH, tierA = true, explicitDub = true,
            ),
        )
        put("vf", lang("fr", tierA = true, explicitDub = true))
        put("vof", lang("fr", tierA = true, explicitDub = true, original = HIGH))
        put("french", lang("fr"))
        put("francais", lang("fr"))
        put("fr", lang("fr", confidence = MEDIUM, upperOnly = true))
        put("fra", lang("fr", confidence = MEDIUM, upperOnly = true))
        put("fre", lang("fr", confidence = MEDIUM, upperOnly = true))
        put("quebec", lang("fr", StreamLanguageVariant.QUEBEC, MEDIUM))
        put("quebecois", lang("fr", StreamLanguageVariant.QUEBEC, MEDIUM))
        put("quebecoise", lang("fr", StreamLanguageVariant.QUEBEC, MEDIUM))
        // Spanish
        put("castellano", lang("es", StreamLanguageVariant.SPAIN, tierA = true))
        put("spanish", lang("es", StreamLanguageVariant.SPAIN, MEDIUM))
        put("espanol", lang("es", StreamLanguageVariant.SPAIN, MEDIUM))
        put("esp", lang("es", StreamLanguageVariant.SPAIN, MEDIUM))
        put("spa", lang("es", StreamLanguageVariant.SPAIN, LOW, upperOnly = true))
        put("latino", lang("es", StreamLanguageVariant.LATIN_AMERICA))
        put("latam", lang("es", StreamLanguageVariant.LATIN_AMERICA))
        put("lat", lang("es", StreamLanguageVariant.LATIN_AMERICA, MEDIUM, upperOnly = true))
        // Portuguese
        put("ptbr", lang("pt", StreamLanguageVariant.BRAZIL, tierA = true))
        put("dublado", lang("pt", StreamLanguageVariant.BRAZIL, MEDIUM, tierA = true))
        put("brazilian", lang("pt", StreamLanguageVariant.BRAZIL))
        put("brasileiro", lang("pt", StreamLanguageVariant.BRAZIL))
        put("ptpt", lang("pt", StreamLanguageVariant.PORTUGAL, tierA = true))
        put("portuguese", lang("pt"))
        put("portugues", lang("pt"))
        put("por", lang("pt", confidence = MEDIUM, upperOnly = true))
        // Other languages
        listOf("english", "anglais", "eng").forEach { put(it, lang("en")) }
        listOf("italian", "italiano", "ita").forEach { put(it, lang("it")) }
        listOf("german", "deutsch", "ger", "deu").forEach { put(it, lang("de")) }
        listOf("japanese", "jap", "jpn").forEach { put(it, lang("ja")) }
        listOf("korean", "kor").forEach { put(it, lang("ko")) }
        listOf("russian", "rus").forEach { put(it, lang("ru")) }
        put("polish", lang("pl"))
        put("pol", lang("pl", confidence = MEDIUM, upperOnly = true))
        put("pl", lang("pl", confidence = MEDIUM, upperOnly = true))
        put("lektor", lang("pl", confidence = MEDIUM))
        listOf("dutch", "flemish").forEach { put(it, lang("nl")) }
        put("nl", lang("nl", confidence = MEDIUM, upperOnly = true))
        put("nld", lang("nl", confidence = MEDIUM, upperOnly = true))
        put(
            "nordic",
            LanguageSpec(
                listOf("sv" to U, "no" to U, "da" to U, "fi" to U),
                LOW, tierA = false,
            ),
        )
        put("hindi", lang("hi"))
        put("hin", lang("hi", confidence = MEDIUM, upperOnly = true))
        put("tamil", lang("ta"))
        put("telugu", lang("te"))
        put("malayalam", lang("ml"))
        put("kannada", lang("kn"))
        put("bengali", lang("bn"))
        put("marathi", lang("mr"))
        listOf("chinese", "mandarin", "cantonese").forEach { put(it, lang("zh")) }
        put("chi", lang("zh", confidence = MEDIUM, upperOnly = true))
        put("arabic", lang("ar"))
        put("ara", lang("ar", confidence = MEDIUM, upperOnly = true))
        put("turkish", lang("tr"))
        put("tur", lang("tr", confidence = MEDIUM, upperOnly = true))
        put("ukrainian", lang("uk"))
        put("ukr", lang("uk", confidence = MEDIUM, upperOnly = true))
        put("czech", lang("cs"))
        put("cze", lang("cs", confidence = MEDIUM, upperOnly = true))
        put("hungarian", lang("hu"))
        put("hun", lang("hu", confidence = MEDIUM, upperOnly = true))
        put("greek", lang("el"))
        put("hebrew", lang("he"))
        put("heb", lang("he", confidence = MEDIUM, upperOnly = true))
        put("thai", lang("th"))
        put("vietnamese", lang("vi"))
        put("vie", lang("vi", confidence = MEDIUM, upperOnly = true))
        put("swedish", lang("sv"))
        put("swe", lang("sv", confidence = MEDIUM))
        put("norwegian", lang("no"))
        put("nor", lang("no", confidence = MEDIUM, upperOnly = true))
        put("danish", lang("da"))
        put("dan", lang("da", confidence = MEDIUM, upperOnly = true))
        put("finnish", lang("fi"))
        put("fin", lang("fi", confidence = MEDIUM, upperOnly = true))
        put("romanian", lang("ro"))
        put("rum", lang("ro", confidence = MEDIUM, upperOnly = true))
        put("ron", lang("ro", confidence = MEDIUM, upperOnly = true))
        listOf("persian", "farsi").forEach { put(it, lang("fa")) }
        put("indonesian", lang("id"))
        put("croatian", lang("hr"))
        put("serbian", lang("sr"))
        put("bulgarian", lang("bg"))
        put("slovak", lang("sk"))
        put("slovenian", lang("sl"))
        // Track-count tags
        listOf("multi", "multiaudio", "multilang", "multilanguage").forEach {
            put(it, LanguageSpec(emptyList(), MEDIUM, tierA = true, original = MEDIUM, kind = SpecKind.MULTI))
        }
        put("dualaudio", LanguageSpec(emptyList(), MEDIUM, tierA = true, original = MEDIUM, kind = SpecKind.DUAL))
        put("dual", LanguageSpec(emptyList(), MEDIUM, tierA = false, original = MEDIUM, kind = SpecKind.DUAL))
        put("vo", LanguageSpec(emptyList(), HIGH, tierA = false, upperOnly = true, original = HIGH, kind = SpecKind.ORIGINAL))
    }

    /** ISO codes accepted as subtitle languages in "Subs: fr, en" lists (any case). */
    private val SUBTITLE_SHORT_CODES = setOf(
        "fr", "en", "es", "it", "de", "pt", "nl", "pl", "ru", "ja", "ko", "zh", "ar", "sv", "no", "da",
        "fi", "tr", "el", "he", "hu", "cs", "ro", "uk", "hi", "th", "vi",
    )

    private class SubtitleCombined(
        val subtitle: Pair<String, StreamLanguageVariant>?,
        val original: StreamConfidence? = null,
        val frenchSubtitledRelease: Boolean = false,
        val multiSubs: Boolean = false,
        val hardSubs: Boolean = false,
        val subtitleConfidence: StreamConfidence = StreamConfidence.HIGH,
    )

    private val SUBTITLE_COMBINED: Map<String, SubtitleCombined> = buildMap {
        put("vostfr", SubtitleCombined("fr" to U, original = HIGH, frenchSubtitledRelease = true))
        put("vost", SubtitleCombined("fr" to U, original = HIGH, frenchSubtitledRelease = true, subtitleConfidence = LOW))
        put("vosta", SubtitleCombined("en" to U, original = HIGH))
        listOf("subfrench", "subfr", "subfre", "stfr").forEach {
            put(it, SubtitleCombined("fr" to U, original = MEDIUM, frenchSubtitledRelease = true))
        }
        listOf("engsub", "engsubs", "esub", "esubs", "subeng", "engsubbed").forEach {
            put(it, SubtitleCombined("en" to U))
        }
        listOf("subita", "itasub", "itasubs", "subsita").forEach { put(it, SubtitleCombined("it" to U)) }
        listOf("nlsub", "nlsubs", "nlsubbed").forEach { put(it, SubtitleCombined("nl" to U)) }
        listOf("multisub", "multisubs").forEach { put(it, SubtitleCombined(null, multiSubs = true)) }
        listOf("hardsub", "hardsubs", "hardcoded").forEach { put(it, SubtitleCombined(null, hardSubs = true)) }
        put("legendado", SubtitleCombined("pt" to StreamLanguageVariant.BRAZIL, original = MEDIUM))
    }

    private val VOST_SUFFIXES = setOf("fr", "a", "en", "eng")

    private val SUBTITLE_WORDS = setOf(
        "sub", "subs", "subbed", "subtitle", "subtitles", "subtitled", "subtitulado", "subtitulada",
        "subtitulos", "soustitre", "soustitres", "soustitrage",
    )
    private val LANGUAGE_LINE_WORDS = setOf(
        "audio", "audios", "language", "languages", "lang", "langs", "langue", "langues", "and", "et",
        "track", "tracks", "piste", "pistes", "dub", "dubbed", "original",
    )
    private val MULTI_COMPANIONS = setOf("audio", "audios", "lang", "langs", "language", "languages", "track", "tracks")

    private class LangHit(
        val language: String,
        val variant: StreamLanguageVariant,
        val confidence: StreamConfidence,
        val evidence: String,
        val explicitDub: Boolean = false,
        /** From a flag emoji or a structured list: weaker, overridden by tags. */
        val indirect: Boolean = false,
    )

    private class Accumulator {
        val audio = mutableListOf<LangHit>()
        val subtitles = mutableListOf<LangHit>()
        val externalSubtitles = mutableListOf<LangHit>()
        var multi = false
        var dual = false
        var multiSubs = false
        var hardSubs = false
        var original: StreamConfidence? = null
        var frenchSubtitledRelease = false
        var canadaFlag = false
        var franceFlag = false

        val resolutions = mutableListOf<StreamResolution>()
        val sources = mutableListOf<StreamSourceKind>()
        val videoCodecs = mutableListOf<StreamVideoCodec>()
        val hdr = LinkedHashSet<StreamHdrFormat>()
        var dvProfile: String? = null
        var dvLayer: String? = null
        var sdr = false
        var threeD = false
        var bitDepth: Int? = null
        val audioCodecs = LinkedHashSet<StreamAudioCodec>()
        var atmos = false
        val channels = mutableListOf<String>()

        val seasons = LinkedHashSet<Int>()
        val episodes = LinkedHashSet<Int>()
        var complete = false

        var seeders: Int? = null
        var peers: Int? = null
        var provider: String? = null
        var markedSize: Long? = null
        var textSize: Long? = null

        fun addOriginal(confidence: StreamConfidence) {
            val current = original
            if (current == null || confidence.weight > current.weight) original = confidence
        }
    }

    private fun readLanguages(line: Line, acc: Accumulator) {
        val tokens = line.tokens
        val consumed = BooleanArray(tokens.size)
        val isContext = line.role == LineRole.ADDON_NAME || line.role == LineRole.STRUCTURED ||
            line.languageMarker || line.audioMarker || line.subtitleMarker || line.flags.isNotEmpty() ||
            isLanguageListLine(tokens)

        // Ambiguous words count after the first anchor, or right before one ("Film.FRENCH.720p",
        // "Film.FRENCH.ENGLISH.2019") — never in the bare title part ("The.French.Dispatch.2021").
        fun tierBAllowed(index: Int): Boolean {
            if (isContext || line.anchorIndex in 0 until index) return true
            var next = index + 1
            while (next < tokens.size &&
                (LANGUAGE_SPECS[tokens[next].folded] != null || tokens[next].folded in SUBTITLE_COMBINED) &&
                !isAnchorToken(tokens[next])
            ) {
                next++
            }
            return next < tokens.size && isAnchorToken(tokens[next])
        }

        fun specFor(index: Int): LanguageSpec? {
            val token = tokens[index]
            val spec = LANGUAGE_SPECS[token.folded] ?: return null
            if (spec.upperOnly && !token.isUpperCase) return null
            return spec
        }

        fun subtitleLanguageAt(index: Int): Pair<String, StreamLanguageVariant>? {
            val token = tokens[index]
            val spec = specFor(index)
            if (spec != null && spec.explicitDub) return null
            if (spec != null && spec.kind == SpecKind.LANGUAGE && spec.targets.size == 1) return spec.targets.first()
            if (token.folded.length == 2 && token.folded in SUBTITLE_SHORT_CODES) return token.folded to U
            return null
        }

        fun isSubtitleWord(index: Int): Boolean {
            val token = tokens[index]
            return token.folded in SUBTITLE_WORDS || (token.folded == "st" && token.isUpperCase)
        }

        fun addSubtitle(language: Pair<String, StreamLanguageVariant>, evidence: String, confidence: StreamConfidence = HIGH) {
            acc.subtitles += LangHit(language.first, language.second, confidence, evidence)
        }

        // Pass 1: multi-token tags, subtitle tags and "<lang> subs" / "subs: <lang>, <lang>".
        var i = 0
        while (i < tokens.size) {
            if (consumed[i]) { i++; continue }
            val token = tokens[i]
            val folded = token.folded
            val next = tokens.getOrNull(i + 1)
            val nextFolded = next?.folded
            val separator = line.separatorAfter(i)

            if (folded == "vost" && next != null && nextFolded in VOST_SUFFIXES && separator.length <= 1) {
                val combined = if (nextFolded == "fr") SUBTITLE_COMBINED.getValue("vostfr") else SUBTITLE_COMBINED.getValue("vosta")
                applySubtitleCombined(combined, token.raw + next.raw, acc)
                consumed[i] = true
                consumed[i + 1] = true
                i += 2
                continue
            }
            val combinedSubtitle = SUBTITLE_COMBINED[folded]
            if (combinedSubtitle != null && (folded != "hardcoded" || line.anchorIndex in 0 until i)) {
                consumed[i] = true
                applySubtitleCombined(combinedSubtitle, token.raw, acc)
                i++
                continue
            }
            if (folded == "true" && nextFolded == "french") {
                acc.audio += LangHit("fr", StreamLanguageVariant.FRANCE, HIGH, "TRUEFRENCH", explicitDub = true)
                consumed[i] = true
                consumed[i + 1] = true
                i += 2
                continue
            }
            if (folded == "pt" && (nextFolded == "br" || nextFolded == "pt") && separator.length <= 1) {
                val variant = if (nextFolded == "br") StreamLanguageVariant.BRAZIL else StreamLanguageVariant.PORTUGAL
                acc.audio += LangHit("pt", variant, HIGH, "${token.raw}-${next.raw}")
                consumed[i] = true
                consumed[i + 1] = true
                i += 2
                continue
            }
            if (folded == "es" && nextFolded == "419" && separator.length <= 1) {
                acc.audio += LangHit("es", StreamLanguageVariant.LATIN_AMERICA, HIGH, "es-419")
                consumed[i] = true
                consumed[i + 1] = true
                i += 2
                continue
            }
            if (folded == "fr" && (nextFolded == "ca" || nextFolded == "fr") && (separator == "-" || separator == "_")) {
                val variant = if (nextFolded == "ca") StreamLanguageVariant.QUEBEC else StreamLanguageVariant.FRANCE
                acc.audio += LangHit("fr", variant, if (variant == StreamLanguageVariant.QUEBEC) HIGH else MEDIUM, "${token.raw}-${next.raw}")
                consumed[i] = true
                consumed[i + 1] = true
                i += 2
                continue
            }
            val frenchWord = folded == "french" || folded == "francais" || (folded == "fr" && token.isUpperCase)
            val canadaWord = setOf("canadian", "canada", "canadien", "canadienne", "quebec", "quebecois", "quebecoise")
            if (next != null && ((frenchWord && nextFolded in canadaWord) ||
                    (folded in canadaWord && (nextFolded == "french" || nextFolded == "francais")))
            ) {
                if (tierBAllowed(i)) {
                    acc.audio += LangHit("fr", StreamLanguageVariant.QUEBEC, HIGH, "${token.raw} ${next.raw}")
                }
                consumed[i] = true
                consumed[i + 1] = true
                i += 2
                continue
            }
            if (folded == "multi" && nextFolded != null && nextFolded in MULTI_COMPANIONS) {
                acc.multi = true
                acc.addOriginal(MEDIUM)
                consumed[i] = true
                consumed[i + 1] = true
                i += 2
                continue
            }
            if (folded == "dual" && nextFolded == "audio") {
                acc.dual = true
                acc.addOriginal(MEDIUM)
                consumed[i] = true
                consumed[i + 1] = true
                i += 2
                continue
            }
            if (folded == "multi" && next != null && (nextFolded in SUBTITLE_WORDS)) {
                acc.multiSubs = true
                consumed[i] = true
                consumed[i + 1] = true
                i += 2
                continue
            }
            val sousTitres = folded == "sous" && (nextFolded == "titre" || nextFolded == "titres")
            if (sousTitres || isSubtitleWord(i)) {
                consumed[i] = true
                if (sousTitres) consumed[i + 1] = true
                val subtitledRelease = folded == "subbed"
                // "<lang> SUBS" / "FRENCH.SUBBED": the one token right before.
                val previous = i - 1
                if (previous >= 0 && !consumed[previous]) {
                    if (tokens[previous].folded == "multi") {
                        acc.multiSubs = true
                        consumed[previous] = true
                    } else {
                        subtitleLanguageAt(previous)?.let { language ->
                            addSubtitle(language, "${tokens[previous].raw} ${token.raw}")
                            if (language.first == "fr" && subtitledRelease) acc.frenchSubtitledRelease = true
                            consumed[previous] = true
                        }
                    }
                }
                // "SUBS: English, French" / "SUB ITA": consecutive languages right after.
                var j = i + (if (sousTitres) 2 else 1)
                while (j < tokens.size && !consumed[j]) {
                    val language = subtitleLanguageAt(j)
                    if (language == null) {
                        if (tokens[j].folded == "and" || tokens[j].folded == "et") { j++; continue }
                        break
                    }
                    addSubtitle(language, "${token.raw} ${tokens[j].raw}")
                    if (language.first == "fr" && subtitledRelease) acc.frenchSubtitledRelease = true
                    consumed[j] = true
                    j++
                }
                i++
                continue
            }
            if (folded == "hc" && token.isUpperCase && line.anchorIndex in 0 until i) {
                acc.hardSubs = true
                consumed[i] = true
            }
            i++
        }

        // Pass 2: single language / track tags.
        for (index in tokens.indices) {
            if (consumed[index]) continue
            val spec = specFor(index) ?: continue
            if (!spec.tierA && !tierBAllowed(index)) continue
            val raw = tokens[index].raw
            when (spec.kind) {
                SpecKind.MULTI -> acc.multi = true
                SpecKind.DUAL -> acc.dual = true
                SpecKind.ORIGINAL, SpecKind.LANGUAGE -> Unit
            }
            spec.original?.let(acc::addOriginal)
            spec.targets.forEach { (language, variant) ->
                acc.audio += LangHit(language, variant, spec.confidence, raw, explicitDub = spec.explicitDub)
            }
        }

        // Flags: audio, unless the line is about subtitles.
        if (line.flags.isNotEmpty()) {
            val subtitleLine = line.subtitleMarker || tokens.indices.any(::isSubtitleWord)
            line.flags.forEach { country ->
                if (country == "CA") {
                    if (!subtitleLine) acc.canadaFlag = true
                    return@forEach
                }
                if (country == "FR" && !subtitleLine) acc.franceFlag = true
                val language = FLAG_LANGUAGES[country] ?: return@forEach
                val evidence = flagEmoji(country)
                if (subtitleLine) {
                    acc.subtitles += LangHit(language.first, language.second, MEDIUM, evidence, indirect = true)
                } else {
                    acc.audio += LangHit(language.first, language.second, MEDIUM, evidence, indirect = true)
                }
            }
        }
    }

    private fun applySubtitleCombined(combined: SubtitleCombined, evidence: String, acc: Accumulator) {
        combined.subtitle?.let { (language, variant) ->
            acc.subtitles += LangHit(language, variant, combined.subtitleConfidence, evidence)
        }
        combined.original?.let(acc::addOriginal)
        if (combined.frenchSubtitledRelease) acc.frenchSubtitledRelease = true
        if (combined.multiSubs) acc.multiSubs = true
        if (combined.hardSubs) acc.hardSubs = true
    }

    /** "Audio: French / English", "Multi Audio", "English + French": nothing but language words. */
    private fun isLanguageListLine(tokens: List<Tok>): Boolean {
        if (tokens.isEmpty()) return false
        var languageWords = 0
        for (token in tokens) {
            val spec = LANGUAGE_SPECS[token.folded]
            val isLanguage = (spec != null && (!spec.upperOnly || token.isUpperCase)) ||
                token.folded in SUBTITLE_COMBINED
            when {
                isLanguage -> languageWords++
                token.folded in LANGUAGE_LINE_WORDS || token.folded in SUBTITLE_WORDS -> Unit
                else -> return false
            }
        }
        return languageWords > 0
    }

    private val FLAG_LANGUAGES: Map<String, Pair<String, StreamLanguageVariant>> = buildMap {
        put("FR", "fr" to U)
        listOf("GB", "US", "AU", "NZ", "IE").forEach { put(it, "en" to U) }
        put("ES", "es" to StreamLanguageVariant.SPAIN)
        listOf("MX", "AR", "CO", "CL", "PE", "VE").forEach { put(it, "es" to StreamLanguageVariant.LATIN_AMERICA) }
        put("BR", "pt" to StreamLanguageVariant.BRAZIL)
        put("PT", "pt" to StreamLanguageVariant.PORTUGAL)
        put("IT", "it" to U)
        put("DE", "de" to U)
        put("AT", "de" to U)
        put("JP", "ja" to U)
        put("KR", "ko" to U)
        put("RU", "ru" to U)
        listOf("CN", "TW", "HK").forEach { put(it, "zh" to U) }
        put("IN", "hi" to U)
        put("PL", "pl" to U)
        put("NL", "nl" to U)
        put("SE", "sv" to U)
        put("NO", "no" to U)
        put("DK", "da" to U)
        put("FI", "fi" to U)
        put("TR", "tr" to U)
        put("GR", "el" to U)
        put("UA", "uk" to U)
        put("CZ", "cs" to U)
        put("HU", "hu" to U)
        put("RO", "ro" to U)
        put("IL", "he" to U)
        listOf("SA", "AE", "EG").forEach { put(it, "ar" to U) }
        put("TH", "th" to U)
        put("VN", "vi" to U)
        put("ID", "id" to U)
        put("IR", "fa" to U)
        put("HR", "hr" to U)
        put("RS", "sr" to U)
        put("BG", "bg" to U)
        put("SK", "sk" to U)
        put("SI", "sl" to U)
        put("LT", "lt" to U)
        put("LV", "lv" to U)
        put("EE", "et" to U)
        put("MY", "ms" to U)
        put("PH", "tl" to U)
    }

    private fun flagEmoji(country: String): String = buildString {
        country.forEach { letter ->
            val codePoint = 0x1F1E6 + (letter - 'A')
            val offset = codePoint - 0x10000
            append((0xD800 + (offset shr 10)).toChar())
            append((0xDC00 + (offset and 0x3FF)).toChar())
        }
    }

    private fun readStructuredLanguages(input: StreamInsightInput, acc: Accumulator) {
        input.parsed?.languages?.forEach { rawLanguage ->
            val folded = rawLanguage.trim().lowercase()
            when {
                folded.isEmpty() -> Unit
                folded.startsWith("multi") -> {
                    acc.multi = true
                    acc.addOriginal(MEDIUM)
                }
                folded.startsWith("dual") -> {
                    acc.dual = true
                    acc.addOriginal(MEDIUM)
                }
                else -> languageFromCode(rawLanguage)?.let { (language, variant) ->
                    acc.audio += LangHit(language, variant, MEDIUM, rawLanguage, indirect = true)
                }
            }
        }
        input.subtitleLanguages.forEach { code ->
            languageFromCode(code)?.let { (language, variant) ->
                acc.externalSubtitles += LangHit(language, variant, HIGH, code)
            }
        }
    }

    /** A language code / name from structured data ("fr", "fr-CA", "VFQ", "pt-BR", "Spanish (Latin)"). */
    private fun languageFromCode(raw: String): Pair<String, StreamLanguageVariant>? {
        val normalized = normalizeLanguageCode(raw) ?: return null
        return when (normalized) {
            "fr-ca" -> "fr" to StreamLanguageVariant.QUEBEC
            "fr-fr" -> "fr" to StreamLanguageVariant.FRANCE
            "es-419" -> "es" to StreamLanguageVariant.LATIN_AMERICA
            "es-es" -> "es" to StreamLanguageVariant.SPAIN
            "pt-br" -> "pt" to StreamLanguageVariant.BRAZIL
            "pt-pt" -> "pt" to StreamLanguageVariant.PORTUGAL
            else -> {
                val primary = normalized.substringBefore('-')
                if (primary.length == 2 && primary.all { it in 'a'..'z' }) primary to U else null
            }
        }
    }

    private fun finalizeLanguages(acc: Accumulator): Pair<List<StreamLanguage>, List<StreamLanguage>> {
        val audio = acc.audio.toMutableList()

        // VOSTFR / SUBFRENCH / FRENCH.SUBBED: French is the subtitle, not a dub — unless an
        // explicit dub tag (VFF, VFQ, TRUEFRENCH…) says otherwise.
        if (acc.frenchSubtitledRelease) {
            audio.removeAll { it.language == "fr" && !it.explicitDub }
        }
        // A flag/structured language that the title states as a subtitle is a subtitle.
        val subtitleLanguages = acc.subtitles.map { it.language }.toSet()
        audio.removeAll { it.indirect && it.language in subtitleLanguages }

        // 🇨🇦: French (Québec) or English (Canada) — a low-confidence hint, combined with the rest.
        if (acc.canadaFlag) {
            val french = audio.filter { it.language == "fr" }
            val hasSpecificFrench = french.any { it.variant != StreamLanguageVariant.UNSPECIFIED }
            when {
                hasSpecificFrench -> Unit
                french.isNotEmpty() -> {
                    val evidence = flagEmoji("CA")
                    if (acc.franceFlag) {
                        // 🇫🇷 + 🇨🇦: two French tracks, most likely VFF + VFQ.
                        audio.removeAll { it.language == "fr" && it.variant == StreamLanguageVariant.UNSPECIFIED && it.indirect }
                        audio += LangHit("fr", StreamLanguageVariant.FRANCE, LOW, flagEmoji("FR"), indirect = true)
                        audio += LangHit("fr", StreamLanguageVariant.QUEBEC, LOW, evidence, indirect = true)
                    } else {
                        audio.removeAll { it.language == "fr" && it.variant == StreamLanguageVariant.UNSPECIFIED }
                        audio += LangHit("fr", StreamLanguageVariant.QUEBEC, LOW, evidence, indirect = true)
                    }
                }
                audio.any { it.language == "en" } -> Unit
                !acc.frenchSubtitledRelease ->
                    audio += LangHit("fr", StreamLanguageVariant.QUEBEC, LOW, flagEmoji("CA"), indirect = true)
            }
        }

        // MULTi: several audio tracks, in practice the original + French. Only assumed when the
        // title names no other non-English dub and is not a subtitled release.
        if (acc.multi && audio.none { it.language == "fr" } && !acc.frenchSubtitledRelease &&
            audio.none { it.language != "en" }
        ) {
            audio += LangHit("fr", StreamLanguageVariant.UNSPECIFIED, LOW, "MULTi")
        }

        // A specific variant explains the generic mention ("FRENCH … VFQ" is VFQ, not VF + VFQ).
        val specificLanguages = audio.filter { it.variant != StreamLanguageVariant.UNSPECIFIED }.map { it.language }.toSet()
        audio.removeAll { it.variant == StreamLanguageVariant.UNSPECIFIED && it.language in specificLanguages }

        val subtitles = (acc.subtitles + acc.externalSubtitles).toMutableList()
        val specificSubtitles = subtitles.filter { it.variant != StreamLanguageVariant.UNSPECIFIED }.map { it.language }.toSet()
        subtitles.removeAll { it.variant == StreamLanguageVariant.UNSPECIFIED && it.language in specificSubtitles }

        return merge(audio) to merge(subtitles)
    }

    private fun merge(hits: List<LangHit>): List<StreamLanguage> {
        val order = mutableListOf<Pair<String, StreamLanguageVariant>>()
        val grouped = mutableMapOf<Pair<String, StreamLanguageVariant>, MutableList<LangHit>>()
        hits.forEach { hit ->
            val key = hit.language to hit.variant
            if (key !in grouped) order += key
            grouped.getOrPut(key) { mutableListOf() } += hit
        }
        return order.map { key ->
            val group = grouped.getValue(key)
            StreamLanguage(
                language = key.first,
                variant = key.second,
                confidence = group.maxByOrNull { it.confidence.weight }!!.confidence,
                evidence = group.map { it.evidence }.distinct(),
            )
        }.sortedByDescending { it.confidence.weight }
    }

    // endregion

    // region Technical

    private val EPISODE_ONLY_REGEX = Regex("^E(\\d{1,3})$")
    private val DTS_TOKEN_REGEX = Regex("^DTS\\d*$")
    private val MA_TOKEN_REGEX = Regex("^MA\\d*$")
    private val DDP_TOKEN_REGEX = Regex("^(DDP|EAC3)\\d*(ATMOS)?$")
    private val DD_TOKEN_REGEX = Regex("^DD\\d*$")
    private val AC3_TOKEN_REGEX = Regex("^AC3\\d*$")
    private val AAC_TOKEN_REGEX = Regex("^(HE)?AAC\\d*(LC)?$")
    private val DV_PROFILE_REGEX = Regex("^P([578])(\\d)?$")
    private val CHANNEL_TOKEN_REGEX = Regex("^([2678])CH$")
    private val AUDIO_CONTEXT_TOKENS = setOf("ATMOS", "MA", "HD", "AUDIO", "TRUEHD", "DTS", "DDP", "DD", "AAC", "AC3", "EAC3", "FLAC", "OPUS", "LPCM", "PCM", "X", "CH")

    private val LOW_QUALITY_STRONG = mapOf(
        "CAMRIP" to StreamSourceKind.CAM,
        "HDCAM" to StreamSourceKind.CAM,
        "TELESYNC" to StreamSourceKind.TELESYNC,
        "HDTS" to StreamSourceKind.TELESYNC,
        "TSRIP" to StreamSourceKind.TELESYNC,
        "PDVD" to StreamSourceKind.TELESYNC,
        "TELECINE" to StreamSourceKind.TELECINE,
        "HDTC" to StreamSourceKind.TELECINE,
        "DVDSCR" to StreamSourceKind.SCREENER,
        "BDSCR" to StreamSourceKind.SCREENER,
        "WEBSCR" to StreamSourceKind.SCREENER,
        "SCREENER" to StreamSourceKind.SCREENER,
    )

    private fun readTechnical(line: Line, acc: Accumulator) {
        val tokens = line.tokens
        val text = line.text
        val hasDvOnLine = tokens.any { it.upper == "DV" || it.upper == "DOVI" || it.upper == "DOLBYVISION" } ||
            tokens.indices.any { it + 1 < tokens.size && tokens[it].upper == "DOLBY" && tokens[it + 1].upper == "VISION" }

        fun afterAnchor(index: Int): Boolean =
            line.role != LineRole.RELEASE || line.anchorIndex in 0 until index

        for (index in tokens.indices) {
            val token = tokens[index]
            val u = token.upper
            val next = tokens.getOrNull(index + 1)?.upper
            val next2 = tokens.getOrNull(index + 2)?.upper
            val prev = tokens.getOrNull(index - 1)?.upper
            val charAfter = text.getOrNull(token.end)

            // Resolution
            when (u) {
                "2160P", "2160I", "4K", "UHD", "4KUHD" -> acc.resolutions += StreamResolution.P2160
                "1440P", "QHD" -> acc.resolutions += StreamResolution.P1440
                "1080P", "1080I", "FHD", "FULLHD" -> acc.resolutions += StreamResolution.P1080
                "720P", "720I" -> acc.resolutions += StreamResolution.P720
                "576P", "576I", "480P", "480I" -> acc.resolutions += StreamResolution.P480
                "360P", "240P" -> acc.resolutions += StreamResolution.SD
                "SD" -> if (token.isUpperCase) acc.resolutions += StreamResolution.SD
                "FULL" -> if (next == "HD") acc.resolutions += StreamResolution.P1080
            }
            RES_DIMENSION_REGEX.matchEntire(u)?.let { match ->
                val height = match.groupValues[2].toIntOrNull() ?: 0
                resolutionForHeight(height)?.let { acc.resolutions += it }
            }

            // Source
            when (u) {
                "REMUX", "BDREMUX", "UHDREMUX" -> acc.sources += StreamSourceKind.REMUX
                "BLURAY", "BDRIP", "BRRIP", "BDMV", "BD25", "BD50", "BD66", "BD100", "BDISO" -> acc.sources += StreamSourceKind.BLURAY
                "BD" -> if (token.isUpperCase) acc.sources += StreamSourceKind.BLURAY
                "BLU" -> if (next == "RAY") acc.sources += StreamSourceKind.BLURAY
                "WEBDL" -> acc.sources += StreamSourceKind.WEB_DL
                "WEBRIP", "HDRIP", "UHDRIP" -> acc.sources += StreamSourceKind.WEBRIP
                "WEB" -> acc.sources += when (next) {
                    "RIP" -> StreamSourceKind.WEBRIP
                    else -> StreamSourceKind.WEB_DL
                }
                "HDTV", "PDTV", "TVRIP", "SATRIP", "DSR", "DVBRIP", "HDTVRIP" -> acc.sources += StreamSourceKind.HDTV
                "DVDRIP", "DVD", "DVD5", "DVD9", "DVDR" -> acc.sources += StreamSourceKind.DVDRIP
            }
            LOW_QUALITY_STRONG[u]?.let { acc.sources += it }
            if (afterAnchor(index)) {
                when (u) {
                    "CAM" -> acc.sources += StreamSourceKind.CAM
                    "TS" -> if (token.isUpperCase && prev != "M2") acc.sources += StreamSourceKind.TELESYNC
                    "TC" -> if (token.isUpperCase) acc.sources += StreamSourceKind.TELECINE
                    "SCR" -> if (token.isUpperCase) acc.sources += StreamSourceKind.SCREENER
                }
            }

            // Video codec
            when (u) {
                "HEVC", "X265", "H265", "HEVC10" -> acc.videoCodecs += StreamVideoCodec.HEVC
                "AVC", "X264", "H264" -> acc.videoCodecs += StreamVideoCodec.AVC
                "AV1" -> acc.videoCodecs += StreamVideoCodec.AV1
                "VP9" -> acc.videoCodecs += StreamVideoCodec.VP9
                "XVID", "DIVX" -> acc.videoCodecs += StreamVideoCodec.XVID
                "MPEG2" -> acc.videoCodecs += StreamVideoCodec.MPEG2
                "H" -> when (next) {
                    "265" -> acc.videoCodecs += StreamVideoCodec.HEVC
                    "264" -> acc.videoCodecs += StreamVideoCodec.AVC
                }
                "MPEG" -> if (next == "2") acc.videoCodecs += StreamVideoCodec.MPEG2
            }

            // HDR
            when (u) {
                "DV", "DOVI", "DOLBYVISION" -> acc.hdr += StreamHdrFormat.DOLBY_VISION
                "DOLBY" -> if (next == "VISION") acc.hdr += StreamHdrFormat.DOLBY_VISION
                "HDR10PLUS", "HDR10P" -> acc.hdr += StreamHdrFormat.HDR10_PLUS
                "HDR10" -> acc.hdr += if (charAfter == '+' || next == "PLUS") StreamHdrFormat.HDR10_PLUS else StreamHdrFormat.HDR10
                "HDR" -> acc.hdr += StreamHdrFormat.HDR
                "HLG" -> acc.hdr += StreamHdrFormat.HLG
                "SDR" -> acc.sdr = true
                "FEL", "MEL" -> if (hasDvOnLine) acc.dvLayer = u
            }
            if (hasDvOnLine) {
                DV_PROFILE_REGEX.matchEntire(u)?.let { match ->
                    val major = match.groupValues[1]
                    val glued = match.groupValues[2]
                    val minor = when {
                        glued.isNotEmpty() -> glued
                        next != null && next.length == 1 && next[0].isDigit() && line.separatorAfter(index) == "." -> next
                        else -> null
                    }
                    acc.dvProfile = if (minor != null) "$major.$minor" else major
                }
                if (u == "PROFILE" && next != null && next.length == 1 && next[0] in "578") acc.dvProfile = next
            }

            // 3D and bit depth
            when (u) {
                "3D" -> if (afterAnchor(index)) acc.threeD = true
                "SBS", "HSBS", "HOU", "MVC", "HALFSBS", "HALFOU" -> acc.threeD = true
                "10BIT", "10BITS", "HI10P", "HI10" -> acc.bitDepth = 10
                "12BIT", "12BITS" -> acc.bitDepth = 12
                "10", "12" -> if (next == "BIT" || next == "BITS") acc.bitDepth = u.toInt()
            }

            // Audio
            when {
                u.startsWith("TRUEHD") -> acc.audioCodecs += StreamAudioCodec.TRUEHD
                u == "TRUE" && next == "HD" -> acc.audioCodecs += StreamAudioCodec.TRUEHD
                u == "DTSX" -> acc.audioCodecs += StreamAudioCodec.DTS_X
                u == "DTSHDMA" || u == "DTSMA" -> acc.audioCodecs += StreamAudioCodec.DTS_HD_MA
                u == "DTSHD" -> acc.audioCodecs += if (next == "MA" || next?.startsWith("MA") == true) StreamAudioCodec.DTS_HD_MA else StreamAudioCodec.DTS_HD
                DTS_TOKEN_REGEX.matches(u) -> acc.audioCodecs += when {
                    next == "X" -> StreamAudioCodec.DTS_X
                    next == "HDMA" -> StreamAudioCodec.DTS_HD_MA
                    next == "HD" && next2 != null && MA_TOKEN_REGEX.matches(next2) -> StreamAudioCodec.DTS_HD_MA
                    next == "HD" -> StreamAudioCodec.DTS_HD
                    next == "MA" -> StreamAudioCodec.DTS_HD_MA
                    else -> StreamAudioCodec.DTS
                }
                DDP_TOKEN_REGEX.matches(u) -> acc.audioCodecs += StreamAudioCodec.EAC3
                DD_TOKEN_REGEX.matches(u) -> acc.audioCodecs += if (charAfter == '+') StreamAudioCodec.EAC3 else StreamAudioCodec.AC3
                u == "E" && next == "AC" && next2 == "3" -> acc.audioCodecs += StreamAudioCodec.EAC3
                u == "E" && next == "AC3" -> acc.audioCodecs += StreamAudioCodec.EAC3
                u == "EAC" && next == "3" -> acc.audioCodecs += StreamAudioCodec.EAC3
                AC3_TOKEN_REGEX.matches(u) && prev != "E" -> acc.audioCodecs += StreamAudioCodec.AC3
                u == "AC" && next == "3" && prev != "E" -> acc.audioCodecs += StreamAudioCodec.AC3
                u == "DOLBY" && next == "DIGITAL" ->
                    acc.audioCodecs += if (next2 == "PLUS") StreamAudioCodec.EAC3 else StreamAudioCodec.AC3
                AAC_TOKEN_REGEX.matches(u) -> acc.audioCodecs += StreamAudioCodec.AAC
                u.startsWith("OPUS") -> acc.audioCodecs += StreamAudioCodec.OPUS
                u.startsWith("FLAC") -> acc.audioCodecs += StreamAudioCodec.FLAC
                u == "MP3" -> acc.audioCodecs += StreamAudioCodec.MP3
                u == "LPCM" || u == "PCM" -> acc.audioCodecs += StreamAudioCodec.LPCM
            }
            if (u.endsWith("ATMOS")) acc.atmos = true
            CHANNEL_TOKEN_REGEX.matchEntire(u)?.let { match ->
                acc.channels += when (match.groupValues[1]) {
                    "2" -> "2.0"
                    "6" -> "5.1"
                    "7" -> "6.1"
                    else -> "7.1"
                }
            }
        }
        readChannels(line, acc)
    }

    private val CHANNEL_LAYOUTS = setOf("1.0", "2.0", "2.1", "5.0", "5.1", "6.1", "7.1")
    private val SIZE_UNIT_PREFIXES = listOf("GB", "GO", "MB", "MO", "TB", "TO", "GIB", "MIB", "KB", "G ", "M ")

    /** "DDP5.1", "AAC2.0", "Atmos 7.1", "DTS-HD.MA.5.1" — never "7.1 GB" or a "⭐ 7.1" rating. */
    private fun readChannels(line: Line, acc: Accumulator) {
        val text = line.text
        for (dot in 1 until text.length - 1) {
            if (text[dot] != '.') continue
            val candidate = "${text[dot - 1]}.${text[dot + 1]}"
            if (candidate !in CHANNEL_LAYOUTS) continue
            if (text.getOrNull(dot - 2)?.isDigit() == true) continue
            if (text.getOrNull(dot + 2)?.isDigit() == true) continue
            val rest = text.substring(dot + 2).trimStart().uppercase()
            if (SIZE_UNIT_PREFIXES.any { rest.startsWith(it) } || rest == "G" || rest == "M") continue
            val before = text.substring(0, dot - 1).trimEnd()
            if (before.endsWith(RATING_MARK)) continue
            val letterGlued = text.getOrNull(dot - 2)?.isLetter() == true
            // The token before the "5" of "5.1" (the "5" is its own token unless glued to letters).
            val previousToken = line.tokens.lastOrNull { it.end <= dot - 1 }
            val audioContext = letterGlued ||
                line.role == LineRole.STRUCTURED ||
                line.audioMarker ||
                (previousToken != null && (previousToken.upper in AUDIO_CONTEXT_TOKENS ||
                    DTS_TOKEN_REGEX.matches(previousToken.upper) || DDP_TOKEN_REGEX.matches(previousToken.upper) ||
                    DD_TOKEN_REGEX.matches(previousToken.upper) || AAC_TOKEN_REGEX.matches(previousToken.upper) ||
                    previousToken.upper.endsWith("ATMOS") || previousToken.upper.startsWith("TRUEHD")))
            if (audioContext) acc.channels += candidate
        }
    }

    private fun channelRank(layout: String): Int = when (layout) {
        "7.1" -> 7
        "6.1" -> 6
        "5.1" -> 5
        "5.0" -> 4
        "2.1" -> 3
        "2.0" -> 2
        else -> 1
    }

    private fun resolutionForHeight(height: Int): StreamResolution? = when {
        height >= 2000 -> StreamResolution.P2160
        height >= 1400 -> StreamResolution.P1440
        height >= 1000 -> StreamResolution.P1080
        height >= 700 -> StreamResolution.P720
        height >= 470 -> StreamResolution.P480
        height > 0 -> StreamResolution.SD
        else -> null
    }

    /** Any low-quality tag wins (pessimistic); otherwise the best source named. */
    private fun pickSource(sources: List<StreamSourceKind>): StreamSourceKind {
        sources.filter { it.isLowQuality }.minByOrNull { it.rank }?.let { return it }
        return sources.maxByOrNull { it.rank } ?: StreamSourceKind.UNKNOWN
    }

    private fun finalizeHdr(formats: Set<StreamHdrFormat>): List<StreamHdrFormat> {
        val result = formats.toMutableList()
        if (result.size > 1) result.remove(StreamHdrFormat.HDR)
        if (StreamHdrFormat.HDR10_PLUS in result) result.remove(StreamHdrFormat.HDR10)
        val order = StreamHdrFormat.entries
        return result.sortedBy { order.indexOf(it) }
    }

    private fun finalizeAudioCodecs(codecs: Set<StreamAudioCodec>): List<StreamAudioCodec> {
        val result = codecs.toMutableList()
        if (StreamAudioCodec.DTS_HD_MA in result || StreamAudioCodec.DTS_X in result) {
            result.remove(StreamAudioCodec.DTS_HD)
            result.remove(StreamAudioCodec.DTS)
        } else if (StreamAudioCodec.DTS_HD in result) {
            result.remove(StreamAudioCodec.DTS)
        }
        if (StreamAudioCodec.EAC3 in result && codecs.size > 1) {
            // "DD+" also produced a bare "DD" token on some layouts — keep AC3 only if stated apart.
        }
        return result.sortedByDescending { it.rank }
    }

    // endregion

    // region Episodes

    private val SEASON_WORDS = setOf("SEASON", "SAISON", "TEMPORADA", "STAGIONE", "STAFFEL", "SEIZOEN")

    private fun readEpisodes(line: Line, acc: Accumulator) {
        val tokens = line.tokens
        for (index in tokens.indices) {
            val u = tokens[index].upper
            val next = tokens.getOrNull(index + 1)?.upper
            val separator = line.separatorAfter(index)
            EPISODE_TOKEN_REGEX.matchEntire(u)?.let { match ->
                val season = match.groupValues[1].toInt()
                acc.seasons += season
                val first = match.groupValues[2].toIntOrNull()
                val second = match.groupValues[3].toIntOrNull()
                if (first != null) {
                    acc.episodes += first
                    second?.let { addEpisodeRange(acc, first, it) }
                    // "S01E01-E05", "S01E01-05"
                    if (next != null && (separator == "-" || separator == "+")) {
                        val rangeEnd = EPISODE_ONLY_REGEX.matchEntire(next)?.groupValues?.get(1)?.toIntOrNull()
                            ?: next.takeIf { it.length <= 3 && it.all(Char::isDigit) }?.toIntOrNull()
                        rangeEnd?.let { addEpisodeRange(acc, first, it) }
                    }
                } else if (next != null) {
                    // "S01 E05", "S01-S03"
                    EPISODE_ONLY_REGEX.matchEntire(next)?.groupValues?.get(1)?.toIntOrNull()?.let { acc.episodes += it }
                    if (separator.trim() == "-") {
                        EPISODE_TOKEN_REGEX.matchEntire(next)?.let { end ->
                            val last = end.groupValues[1].toInt()
                            if (last > season && last - season <= 30) (season..last).forEach { acc.seasons += it }
                        }
                    }
                }
            }
            CROSS_EPISODE_REGEX.matchEntire(u)?.let { match ->
                acc.seasons += match.groupValues[1].toInt()
                acc.episodes += match.groupValues[2].toInt()
            }
            if (u in SEASON_WORDS && next != null && next.length <= 2 && next.all(Char::isDigit)) {
                acc.seasons += next.toInt()
            }
            if ((u == "COMPLETE" || u == "INTEGRALE" || u == "INTEGRAL") &&
                (line.role != LineRole.RELEASE || line.anchorIndex in 0 until index || acc.seasons.isNotEmpty())
            ) {
                acc.complete = true
            }
        }
    }

    private fun addEpisodeRange(acc: Accumulator, first: Int, last: Int) {
        if (last > first && last - first <= 60) (first..last).forEach { acc.episodes += it }
    }

    // endregion

    // region Metadata (size, seeders, provider)

    private val MARKED_SEEDERS_REGEX = Regex("$SEEDERS_MARK\\s*(\\d{1,6})(?:\\s*/\\s*(\\d{1,6}))?")
    private val SEEDERS_TEXT_REGEX = Regex("(?i)\\bseed(?:er)?s?\\s*[:=]?\\s*(\\d{1,6})")
    private val SEEDERS_SUFFIX_REGEX = Regex("(?i)\\b(\\d{1,6})\\s*seed(?:er)?s\\b")
    private val PEERS_TEXT_REGEX = Regex("(?i)\\b(?:peers?|leechers?)\\s*[:=]?\\s*(\\d{1,6})")
    private val SL_TEXT_REGEX = Regex("\\bS\\s*:\\s*(\\d{1,6})\\s*[/|,]?\\s*L\\s*:\\s*(\\d{1,6})")
    private val PROVIDER_MARK_REGEX = Regex("$PROVIDER_MARK\\s*([^$PROVIDER_MARK$SEEDERS_MARK$SIZE_MARK$RATING_MARK|\\n]{2,80})")
    private val PROVIDER_TEXT_REGEX = Regex("(?i)\\b(?:tracker|indexer|provider|site)\\s*[:=]\\s*([A-Za-z0-9][A-Za-z0-9 ._-]{1,40})")
    private val SIZE_REGEX = Regex("(?i)(\\d{1,4}(?:[.,]\\d{1,3})?)\\s?(TIB|TB|GIB|GB|MIB|MB)")
    private val SIZE_FRENCH_REGEX = Regex("(\\d{1,4}(?:[.,]\\d{1,3})?)\\s?(To|Go|Mo)")

    private fun readMetadata(line: Line, acc: Accumulator) {
        val text = line.text
        if (acc.seeders == null) {
            MARKED_SEEDERS_REGEX.find(text)?.let { match ->
                acc.seeders = match.groupValues[1].toIntOrNull()
                match.groupValues[2].toIntOrNull()?.let { acc.peers = it }
            }
        }
        if (acc.seeders == null) {
            SL_TEXT_REGEX.find(text)?.let { match ->
                acc.seeders = match.groupValues[1].toIntOrNull()
                acc.peers = match.groupValues[2].toIntOrNull()
            }
        }
        if (acc.seeders == null) {
            (SEEDERS_TEXT_REGEX.find(text) ?: SEEDERS_SUFFIX_REGEX.find(text))?.let { match ->
                acc.seeders = match.groupValues[1].toIntOrNull()
            }
        }
        if (acc.peers == null) {
            PEERS_TEXT_REGEX.find(text)?.let { acc.peers = it.groupValues[1].toIntOrNull() }
        }
        if (acc.provider == null) {
            val raw = PROVIDER_MARK_REGEX.find(text)?.groupValues?.get(1)
                ?: PROVIDER_TEXT_REGEX.find(text)?.groupValues?.get(1)
            acc.provider = raw?.let(::cleanProvider)
        }
        if (line.role != LineRole.TECH_ONLY) {
            val markIndex = text.indexOf(SIZE_MARK)
            val sizes = (SIZE_REGEX.findAll(text) + SIZE_FRENCH_REGEX.findAll(text))
                .mapNotNull { match -> sizeMatch(text, match)?.let { match.range.first to it } }
                .sortedBy { it.first }
                .toList()
            if (sizes.isNotEmpty()) {
                if (markIndex >= 0 && acc.markedSize == null) {
                    sizes.firstOrNull { it.first > markIndex }?.let { acc.markedSize = it.second }
                }
                if (acc.textSize == null) acc.textSize = sizes.first().second
            }
        }
    }

    private fun sizeMatch(text: String, match: MatchResult): Long? {
        val before = text.getOrNull(match.range.first - 1)
        if (before != null && (before.isLetterOrDigit() || before == '.')) return null
        val after = text.getOrNull(match.range.last + 1)
        if (after != null && after.isLetter()) return null
        val number = match.groupValues[1].replace(',', '.').toDoubleOrNull() ?: return null
        val multiplier = when (match.groupValues[2].uppercase()) {
            "TB", "TIB", "TO" -> 1024.0 * 1024 * 1024 * 1024
            "GB", "GIB", "GO" -> 1024.0 * 1024 * 1024
            "MB", "MIB", "MO" -> 1024.0 * 1024
            else -> return null
        }
        val bytes = number * multiplier
        return bytes.toLong().takeIf { it > 0 }
    }

    private fun cleanProvider(raw: String): String? {
        var value = raw.substringBefore("  ").trim()
        value = value.trim('-', ':', '|', '/', '.', ',', ' ')
        if (value.length > 32) value = value.take(32).trimEnd()
        if (value.isEmpty() || value.all { it.isDigit() || it == '.' || it == ' ' }) return null
        return value
    }

    // endregion

    // region Structured fields

    private fun readStructured(input: StreamInsightInput, acc: Accumulator) {
        readStructuredLanguages(input, acc)
        input.parsed?.let { parsed ->
            parsed.seasons.forEach { acc.seasons += it }
            parsed.episodes.forEach { acc.episodes += it }
        }
    }

    // endregion

    // region Debrid cache

    private val DEBRID_CODES = setOf("RD", "AD", "PM", "TB", "DL", "ED", "OC", "PP", "PKP", "DLS")
    private val BRACKET_REGEX = Regex("\\[([A-Za-z]{2,3})([^\\]]{0,20})\\]")
    private val LOOSE_DEBRID_REGEX = Regex("(?:^|[^A-Za-z])(RD|AD|PM|TB|DL|ED|OC)\\s*(\\+|⚡|⏳|⬇)")

    private fun readCache(input: StreamInsightInput): Pair<StreamCacheState, String?> {
        var state = StreamCacheState.UNKNOWN
        var service: String? = null
        val texts = listOfNotNull(input.name, input.title?.substringBefore('\n'))
        for (text in texts) {
            for (match in BRACKET_REGEX.findAll(text)) {
                val code = match.groupValues[1].uppercase()
                if (code !in DEBRID_CODES) continue
                val rest = match.groupValues[2].uppercase()
                service = service ?: code
                val found = when {
                    rest.contains('+') || rest.contains('⚡') || rest.contains('✓') ||
                        rest.contains('✔') || rest.contains("INSTANT") || rest.contains("CACHED") &&
                        !rest.contains("UNCACHED") -> StreamCacheState.CACHED
                    rest.contains("DOWNLOAD") || rest.contains('⬇') || rest.contains('⏳') ||
                        rest.contains("UNCACHED") || rest.trim() == "DL" -> StreamCacheState.NOT_CACHED
                    else -> StreamCacheState.UNKNOWN
                }
                if (found != StreamCacheState.UNKNOWN && state == StreamCacheState.UNKNOWN) state = found
            }
            if (state == StreamCacheState.UNKNOWN) {
                LOOSE_DEBRID_REGEX.find(text)?.let { match ->
                    service = service ?: match.groupValues[1]
                    state = when (match.groupValues[2]) {
                        "+", "⚡" -> StreamCacheState.CACHED
                        else -> StreamCacheState.NOT_CACHED
                    }
                }
            }
            if (state == StreamCacheState.UNKNOWN) {
                if (text.contains('⚡')) state = StreamCacheState.CACHED
                else if (text.contains('⏳')) state = StreamCacheState.NOT_CACHED
            }
        }
        when (input.debridCacheState) {
            StreamDebridCacheState.CACHED -> state = StreamCacheState.CACHED
            StreamDebridCacheState.NOT_CACHED -> state = StreamCacheState.NOT_CACHED
            else -> Unit
        }
        if (input.clientResolveCached == true) state = StreamCacheState.CACHED
        return state to service
    }

    // endregion

    // region Release name and group

    private fun pickReleaseName(input: StreamInsightInput): String? {
        val candidates = buildList {
            input.filename?.let(::add)
            addAll(input.extraReleaseNames)
            input.description?.lineSequence()?.firstOrNull()?.let(::add)
            input.title?.lineSequence()?.firstOrNull()?.let(::add)
            urlFileName(input.url)?.let(::add)
        }.map { StreamInsightText.stripEmojiSingleLine(it).trim() }.filter { it.isNotEmpty() }
        return candidates.firstOrNull { candidate ->
            val tokens = tokenize(candidate)
            tokens.size >= 3 && tokens.count(::isAnchorToken) >= 1
        } ?: candidates.firstOrNull()
    }

    private val EXTENSION_REGEX = Regex("(?i)\\.(mkv|mp4|avi|m4v|ts|m2ts|webm|mov|wmv|iso|mpg)$")
    private val TRAILING_BRACKET_REGEX = Regex("\\s*[\\[\\(][^\\]\\)]*[\\]\\)]\\s*$")
    private val GROUP_REGEX = Regex("-\\s?([A-Za-z0-9][A-Za-z0-9_]{1,23})$")
    private val ANIME_GROUP_REGEX = Regex("^\\[([^\\]]{2,30})\\]")
    private val GROUP_STOP_WORDS = setOf(
        "DL", "RIP", "HD", "MA", "X", "AUDIO", "SUB", "SUBS", "DUAL", "AAC", "AC3", "DTS", "ATMOS", "PROPER",
        "REPACK", "FINAL", "LIMITED", "INTERNAL", "MULTI", "EXTENDED", "UNRATED", "REMASTERED", "SDR",
    )

    private fun extractReleaseGroup(releaseName: String): String? {
        var value = EXTENSION_REGEX.replace(releaseName.trim(), "").trim()
        repeat(3) { value = TRAILING_BRACKET_REGEX.replace(value, "") }
        value = EXTENSION_REGEX.replace(value, "").trim()
        GROUP_REGEX.find(value)?.let { match ->
            val group = match.groupValues[1]
            val token = Tok(group, 0, group.length)
            val upper = group.uppercase()
            val isTag = upper in GROUP_STOP_WORDS || isAnchorToken(token) ||
                (LANGUAGE_SPECS[token.folded] != null) || group.all { it.isDigit() }
            if (!isTag) return group
        }
        return ANIME_GROUP_REGEX.find(releaseName.trim())?.groupValues?.get(1)?.trim()?.takeIf { group ->
            tokenize(group).none(::isAnchorToken)
        }
    }

    // endregion
}
