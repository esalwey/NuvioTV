package com.nuvio.app.features.player

object AudioLanguageOption {
    const val DEFAULT = "default"
    const val DEVICE = "device"
    const val ORIGINAL = "original"
}

object SubtitleLanguageOption {
    const val NONE = "none"
    const val DEVICE = "device"
    const val FORCED = "forced"
}

private val LanguageCodeAliases = mapOf(
    "pt-pt" to "pt",
    "pt_br" to "pt-BR",
    "pt-br" to "pt-BR",
    "br" to "pt-BR",
    "pob" to "pt-BR",
    "eng" to "en",
    "spa" to "es",
    "es-419" to "es-419",
    "es_419" to "es-419",
    "es-la" to "es-419",
    "es-lat" to "es-419",
    "fra" to "fr",
    "fre" to "fr",
    "deu" to "de",
    "ger" to "de",
    "ita" to "it",
    "por" to "pt",
    "rus" to "ru",
    "jpn" to "ja",
    "kor" to "ko",
    "zho" to "zh",
    "chi" to "zh",
    "zht" to "zh-TW",
    "zhs" to "zh-CN",
    "chi-tw" to "zh-TW",
    "chi-cn" to "zh-CN",
    "zh-tw" to "zh-TW",
    "zh_tw" to "zh-TW",
    "zh-cn" to "zh-CN",
    "zh_cn" to "zh-CN",
    "ara" to "ar",
    "hin" to "hi",
    "nld" to "nl",
    "dut" to "nl",
    "pol" to "pl",
    "swe" to "sv",
    "nor" to "no",
    "dan" to "da",
    "fin" to "fi",
    "tur" to "tr",
    "ell" to "el",
    "gre" to "el",
    "heb" to "he",
    "tha" to "th",
    "vie" to "vi",
    "ind" to "id",
    "msa" to "ms",
    "may" to "ms",
    "ces" to "cs",
    "cze" to "cs",
    "hun" to "hu",
    "ron" to "ro",
    "rum" to "ro",
    "ukr" to "uk",
    "bul" to "bg",
    "hrv" to "hr",
    "srp" to "sr",
    "slk" to "sk",
    "slo" to "sk",
    "slv" to "sl",
    "cat" to "ca",
    "alb" to "sq",
    "sqi" to "sq",
    "bos" to "bs",
    "mac" to "mk",
    "mkd" to "mk",
    "lav" to "lv",
    "lit" to "lt",
    "est" to "et",
    "isl" to "is",
    "ice" to "is",
    "glg" to "gl",
    "baq" to "eu",
    "eus" to "eu",
    "wel" to "cy",
    "cym" to "cy",
    "gle" to "ga",
    "ben" to "bn",
    "tam" to "ta",
    "tel" to "te",
    "mal" to "ml",
    "kan" to "kn",
    "mar" to "mr",
    "pan" to "pa",
    "guj" to "gu",
    "urd" to "ur",
    "fas" to "fa",
    "per" to "fa",
    "amh" to "am",
    "swa" to "sw",
    "zul" to "zu",
    "afr" to "af",
    "mlt" to "mt",
    "bel" to "be",
    "geo" to "ka",
    "kat" to "ka",
    "arm" to "hy",
    "hye" to "hy",
    "aze" to "az",
    "kaz" to "kk",
    "uzb" to "uz",
    "mon" to "mn",
    "khm" to "km",
    "lao" to "lo",
    "mya" to "my",
    "bur" to "my",
    "sin" to "si",
    "nep" to "ne",
    "tgl" to "tl",
    "fil" to "tl",
)

private val LanguageNameAliases = mapOf(
    "afrikaans" to "af",
    "albanian" to "sq",
    "amharic" to "am",
    "arabic" to "ar",
    "armenian" to "hy",
    "azerbaijani" to "az",
    "basque" to "eu",
    "belarusian" to "be",
    "bengali" to "bn",
    "bosnian" to "bs",
    "bulgarian" to "bg",
    "burmese" to "my",
    "catalan" to "ca",
    "chinese" to "zh",
    "mandarin" to "zh",
    "croatian" to "hr",
    "czech" to "cs",
    "danish" to "da",
    "dutch" to "nl",
    "english" to "en",
    "estonian" to "et",
    "filipino" to "tl",
    "finnish" to "fi",
    "french" to "fr",
    "galician" to "gl",
    "georgian" to "ka",
    "german" to "de",
    "greek" to "el",
    "gujarati" to "gu",
    "hebrew" to "he",
    "hindi" to "hi",
    "hungarian" to "hu",
    "icelandic" to "is",
    "indonesian" to "id",
    "irish" to "ga",
    "italian" to "it",
    "japanese" to "ja",
    "kannada" to "kn",
    "kazakh" to "kk",
    "khmer" to "km",
    "korean" to "ko",
    "lao" to "lo",
    "latvian" to "lv",
    "lithuanian" to "lt",
    "macedonian" to "mk",
    "malay" to "ms",
    "malayalam" to "ml",
    "maltese" to "mt",
    "marathi" to "mr",
    "mongolian" to "mn",
    "nepali" to "ne",
    "norwegian" to "no",
    "persian" to "fa",
    "polish" to "pl",
    "punjabi" to "pa",
    "romanian" to "ro",
    "russian" to "ru",
    "serbian" to "sr",
    "sinhala" to "si",
    "slovak" to "sk",
    "slovenian" to "sl",
    "swahili" to "sw",
    "swedish" to "sv",
    "tamil" to "ta",
    "telugu" to "te",
    "thai" to "th",
    "turkish" to "tr",
    "ukrainian" to "uk",
    "urdu" to "ur",
    "uzbek" to "uz",
    "vietnamese" to "vi",
    "welsh" to "cy",
    "zulu" to "zu",
)

// Fork (LANG-10): French release tags, matched as whole words only ("VF" never matches inside
// "VFX"). An explicit France tag (VFF, VFI, TrueFrench…) wins over a Québec one, since a title
// carrying both is a multi-dub label whose first dub is the France one; the bare "VF" (version
// française) yields to a Québec word ("VF canadienne").
private val QuebecFrenchReleaseTags = setOf(
    "vfq", "quebec", "quebecois", "quebecoise", "canadien", "canadienne",
)
private val FranceFrenchReleaseTags = setOf(
    "vff", "vfi", "vf2", "vof", "truefrench",
)
private const val GenericFrenchReleaseTag = "vf"

// Fork (LANG-10): languages as they name themselves, diacritics already folded
// (see [stripLanguageDiacritics]). Matched as whole words.
private val NativeLanguageNames = mapOf(
    "francais" to "fr",
    "deutsch" to "de",
    "espanol" to "es",
    "castellano" to "es",
    "latino" to "es-419",
    "italiano" to "it",
    "portugues" to "pt",
    "brasileiro" to "pt-br",
    "nederlands" to "nl",
    "vlaams" to "nl",
    "polski" to "pl",
    "russkiy" to "ru",
    "русский" to "ru",
    "svenska" to "sv",
    "norsk" to "no",
    "bokmal" to "no",
    "dansk" to "da",
    "suomi" to "fi",
    "turkce" to "tr",
    "magyar" to "hu",
    "cestina" to "cs",
    "cesky" to "cs",
    "slovencina" to "sk",
    "slovenscina" to "sl",
    "hrvatski" to "hr",
    "srpski" to "sr",
    "romana" to "ro",
    "ellinika" to "el",
    "ελληνικά" to "el",
    "ελληνικα" to "el",
    "українська" to "uk",
    "български" to "bg",
    "العربية" to "ar",
    "עברית" to "he",
    "हिन्दी" to "hi",
    "ไทย" to "th",
    "tieng viet" to "vi",
    "bahasa indonesia" to "id",
    "bahasa melayu" to "ms",
    "bahasa malaysia" to "ms",
    "日本語" to "ja",
    "nihongo" to "ja",
    "한국어" to "ko",
    "中文" to "zh",
    "普通话" to "zh",
    "國語" to "zh",
    "国语" to "zh",
    "catala" to "ca",
    "euskara" to "eu",
    "galego" to "gl",
    "eesti" to "et",
    "latviesu" to "lv",
    "lietuviu" to "lt",
    "islenska" to "is",
    "tagalog" to "tl",
    "farsi" to "fa",
    "فارسی" to "fa",
)

private val NativeLanguageNamesByLength = NativeLanguageNames.entries.sortedByDescending { it.key.length }

private val DiacriticFolding = mapOf(
    'à' to "a", 'á' to "a", 'â' to "a", 'ã' to "a", 'ä' to "a", 'å' to "a", 'ā' to "a", 'ă' to "a", 'ą' to "a",
    'ç' to "c", 'ć' to "c", 'č' to "c",
    'ď' to "d", 'đ' to "d",
    'è' to "e", 'é' to "e", 'ê' to "e", 'ë' to "e", 'ē' to "e", 'ę' to "e", 'ě' to "e",
    'ğ' to "g",
    'ì' to "i", 'í' to "i", 'î' to "i", 'ï' to "i", 'ī' to "i", 'ı' to "i",
    'ł' to "l", 'ľ' to "l",
    'ñ' to "n", 'ń' to "n", 'ň' to "n",
    'ò' to "o", 'ó' to "o", 'ô' to "o", 'õ' to "o", 'ö' to "o", 'ø' to "o", 'ō' to "o", 'ő' to "o",
    'ř' to "r",
    'ś' to "s", 'š' to "s", 'ş' to "s", 'ș' to "s",
    'ť' to "t", 'ţ' to "t", 'ț' to "t",
    'ù' to "u", 'ú' to "u", 'û' to "u", 'ü' to "u", 'ū' to "u", 'ů' to "u", 'ű' to "u",
    'ý' to "y", 'ÿ' to "y",
    'ź' to "z", 'ż' to "z", 'ž' to "z",
    'æ' to "ae", 'œ' to "oe", 'ß' to "ss",
)

/** Fork (LANG-10): folds the Latin diacritics track titles use ("Français" → "francais"). Lowercase input. */
fun stripLanguageDiacritics(value: String): String {
    if (value.all { it.code < 128 }) return value
    val builder = StringBuilder(value.length)
    for (char in value) {
        val folded = DiacriticFolding[char]
        if (folded != null) builder.append(folded) else builder.append(char)
    }
    return builder.toString()
}

private fun languageWords(value: String): List<String> {
    val words = mutableListOf<String>()
    val current = StringBuilder()
    for (char in value) {
        if (char.isLetterOrDigit()) {
            current.append(char)
        } else if (current.isNotEmpty()) {
            words += current.toString()
            current.clear()
        }
    }
    if (current.isNotEmpty()) words += current.toString()
    return words
}

/**
 * Fork (LANG-10): the language a track title states in words a code table can't read — French
 * release tags (VFF/VF/VFI/TrueFrench → "fr", VFQ/Québec → "fr-ca") and native language names
 * ("Español", "Português", "Français", "日本語"…), all matched as whole words with diacritics
 * folded. Null when the text names no language this way. Lowercase results, like
 * [normalizeLanguageCode].
 */
fun languageFromTrackText(text: String?): String? {
    val folded = text?.trim()?.lowercase()?.let(::stripLanguageDiacritics)
        ?.takeIf { it.isNotBlank() }
        ?: return null
    val words = languageWords(folded)
    if (words.isEmpty()) return null
    if (words.any { it in FranceFrenchReleaseTags }) return "fr"
    if (words.any { it in QuebecFrenchReleaseTags }) return "fr-ca"
    // "French (Canada)", "Français canadian": the English words only count next to French.
    if ((words.contains("french") || words.contains("francais")) &&
        (words.contains("canada") || words.contains("canadian"))
    ) {
        return "fr-ca"
    }
    if (GenericFrenchReleaseTag in words) return "fr"
    val padded = words.joinToString(separator = " ", prefix = " ", postfix = " ")
    return NativeLanguageNamesByLength
        .firstOrNull { (name, _) -> padded.contains(" $name ") }
        ?.value
}

fun normalizeLanguageCode(language: String?): String? {
    val raw = language
        ?.trim()
        ?.replace('_', '-')
        ?.lowercase()
        ?.let(::stripLanguageDiacritics)
        ?.takeIf { it.isNotBlank() }
        ?: return null

    val tokenized = raw
        .replace('-', ' ')
        .replace('.', ' ')
        .replace('/', ' ')
        .replace(Regex("\\s+"), " ")
        .trim()

    fun containsAny(vararg values: String): Boolean =
        values.any { value -> tokenized.contains(value) }

    if (containsAny("portuguese", "portugues")) {
        return when {
            containsAny("brazil", "brasil", "brazilian", "brasileiro", "pt br", "ptbr", "pob", "(br)") ->
                "pt-br"
            containsAny("portugal", "european", "europeu", "iberian", "pt pt", "ptpt") ->
                "pt"
            else -> "pt"
        }
    }

    if (containsAny("spanish", "espanol", "castellano")) {
        return if (containsAny("latin", "latino", "latinoamerica", "latinoamericano", "lat am", "latam", "es 419", "es419", "(419)")) {
            "es-419"
        } else {
            "es"
        }
    }

    LanguageCodeAliases[raw]?.let { return it.replace('_', '-').lowercase() }
    // Fork (LANG-10): release tags and native names ("VFQ", "Français", "日本語").
    languageFromTrackText(raw)?.let { return it }
    LanguageNameAliases[tokenized]?.let { return it }
    LanguageNameAliases.entries
        .sortedByDescending { it.key.length }
        .firstOrNull { (name, _) ->
            tokenized == name ||
                tokenized.startsWith("$name ") ||
                tokenized.endsWith(" $name") ||
                tokenized.contains(" $name ")
        }
        ?.let { return it.value }

    val primary = raw.substringBefore('-')
    val primaryAlias = LanguageCodeAliases[primary]?.replace('_', '-')?.lowercase()
    val suffix = raw.substringAfter('-', "")
    return if (suffix.isBlank()) {
        primaryAlias ?: primary
    } else if (primaryAlias != null && !primaryAlias.contains('-')) {
        "$primaryAlias-$suffix"
    } else {
        primaryAlias ?: "$primary-$suffix"
    }
}

fun languageMatchesPreference(trackLanguage: String?, targetLanguage: String): Boolean {
    val normalizedTrack = normalizeLanguageCode(trackLanguage) ?: return false
    val normalizedTarget = normalizeLanguageCode(targetLanguage) ?: return false
    if (normalizedTrack == normalizedTarget) return true

    val trackPrimary = normalizedTrack.substringBefore('-')
    val targetPrimary = normalizedTarget.substringBefore('-')
    return trackPrimary == targetPrimary
}

fun resolvePreferredAudioLanguageTargets(
    preferredAudioLanguage: String,
    secondaryPreferredAudioLanguage: String?,
    deviceLanguages: List<String>,
    contentOriginalLanguage: String? = null,
): List<String> {
    fun normalize(language: String?): String? {
        val normalized = normalizeLanguageCode(language)
        return when (normalized) {
            null,
            AudioLanguageOption.DEFAULT,
            AudioLanguageOption.DEVICE,
            SubtitleLanguageOption.NONE,
            SubtitleLanguageOption.FORCED,
            -> null
            AudioLanguageOption.ORIGINAL -> contentOriginalLanguage?.trim()?.lowercase()?.takeIf { it.isNotBlank() }
            else -> normalized
        }
    }

    val primary = normalizeLanguageCode(preferredAudioLanguage) ?: AudioLanguageOption.DEVICE

    return when (primary) {
        AudioLanguageOption.DEFAULT -> listOfNotNull(
            normalize(secondaryPreferredAudioLanguage),
        ).distinct()

        AudioLanguageOption.DEVICE -> (
            deviceLanguages.mapNotNull(::normalize)
                + listOfNotNull(normalize(secondaryPreferredAudioLanguage))
            ).distinct()

        AudioLanguageOption.ORIGINAL -> {
            val originalLang = contentOriginalLanguage?.trim()?.lowercase()?.takeIf { it.isNotBlank() }
            if (originalLang != null) {
                listOfNotNull(
                    originalLang,
                    normalize(secondaryPreferredAudioLanguage),
                ).distinct()
            } else {
                // Fallback to device languages when original language is unknown
                (deviceLanguages.mapNotNull(::normalize)
                    + listOfNotNull(normalize(secondaryPreferredAudioLanguage))
                ).distinct()
            }
        }

        else -> listOfNotNull(
            normalize(preferredAudioLanguage),
            normalize(secondaryPreferredAudioLanguage),
        ).distinct()
    }
}

fun resolvePreferredSubtitleLanguageTargets(
    preferredSubtitleLanguage: String,
    secondaryPreferredSubtitleLanguage: String?,
    deviceLanguages: List<String>,
): List<String> {
    fun normalize(language: String?): String? {
        val normalized = normalizeLanguageCode(language)
        return when (normalized) {
            null,
            SubtitleLanguageOption.NONE,
            -> null
            AudioLanguageOption.DEFAULT -> null
            else -> normalized
        }
    }

    val primary = normalizeLanguageCode(preferredSubtitleLanguage) ?: SubtitleLanguageOption.NONE

    return when (primary) {
        SubtitleLanguageOption.NONE -> listOfNotNull(
            normalize(secondaryPreferredSubtitleLanguage),
        ).distinct()

        SubtitleLanguageOption.DEVICE -> (
            deviceLanguages.mapNotNull(::normalize)
                + listOfNotNull(normalize(secondaryPreferredSubtitleLanguage))
            ).distinct()

        else -> listOfNotNull(
            normalize(preferredSubtitleLanguage),
            normalize(secondaryPreferredSubtitleLanguage),
        ).distinct()
    }
}

expect object DeviceLanguagePreferences {
    fun preferredLanguageCodes(): List<String>
}

fun inferForcedSubtitleTrack(
    label: String?,
    language: String?,
    trackId: String?,
    hasForcedSelectionFlag: Boolean = false,
): Boolean {
    if (hasForcedSelectionFlag) return true

    val normalizedLanguage = normalizeLanguageCode(language)
    if (normalizedLanguage == SubtitleLanguageOption.FORCED) return true

    val text = listOfNotNull(label, language, trackId)
        .joinToString(" ")
        .lowercase()

    if ("forced" in text) return true
    return text.contains("songs") && text.contains("sign")
}

/**
 * Best-effort mapping from country name/code to ISO 639-1 primary language.
 * Used as a fallback when [resolveContentLanguage] has no explicit language field.
 */
fun countryToLanguageCode(country: String?): String? {
    val normalized = country?.trim()?.lowercase()?.takeIf { it.isNotBlank() } ?: return null
    return COUNTRY_TO_LANGUAGE_MAP[normalized]
}

/**
 * Resolves the original content language as an ISO 639-1 code.
 * Falls back to country-based inference when the explicit language field is absent.
 */
fun resolveContentLanguage(language: String?, country: String?): String? {
    normalizeLanguageCode(language)?.let { return it }
    countryToLanguageCode(country)?.let { return it }
    return null
}

private val COUNTRY_TO_LANGUAGE_MAP = mapOf(
    // ISO 3166-1 alpha-2
    "jp" to "ja", "kr" to "ko", "cn" to "zh", "tw" to "zh",
    "fr" to "fr", "de" to "de", "it" to "it", "es" to "es",
    "pt" to "pt", "br" to "pt", "ru" to "ru", "in" to "hi",
    "tr" to "tr", "pl" to "pl", "nl" to "nl", "se" to "sv",
    "no" to "no", "dk" to "da", "fi" to "fi", "th" to "th",
    "il" to "he", "cz" to "cs", "ro" to "ro", "hu" to "hu",
    "ua" to "uk", "gr" to "el",
    // ISO 3166-1 alpha-3
    "jpn" to "ja", "kor" to "ko", "chn" to "zh", "twn" to "zh",
    "fra" to "fr", "deu" to "de", "ita" to "it", "esp" to "es",
    "prt" to "pt", "bra" to "pt", "rus" to "ru", "ind" to "hi",
    "tur" to "tr", "pol" to "pl", "nld" to "nl", "swe" to "sv",
    "nor" to "no", "dnk" to "da", "fin" to "fi", "tha" to "th",
    "isr" to "he", "cze" to "cs", "rou" to "ro", "hun" to "hu",
    "ukr" to "uk", "grc" to "el",
    // Common full names
    "japan" to "ja", "south korea" to "ko", "korea" to "ko",
    "china" to "zh", "taiwan" to "zh", "france" to "fr",
    "germany" to "de", "italy" to "it", "spain" to "es",
    "portugal" to "pt", "brazil" to "pt", "russia" to "ru",
    "india" to "hi", "turkey" to "tr", "poland" to "pl",
    "netherlands" to "nl", "sweden" to "sv", "norway" to "no",
    "denmark" to "da", "finland" to "fi", "thailand" to "th",
    "israel" to "he", "romania" to "ro", "hungary" to "hu",
    "ukraine" to "uk", "greece" to "el",
)
