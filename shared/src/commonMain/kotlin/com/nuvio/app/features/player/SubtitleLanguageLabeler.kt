package com.nuvio.app.features.player

/**
 * Seam producing a human-readable label for a language code (e.g. "en" -> "English").
 * The phone app installs an adapter backed by getLanguageLabelForCode (which maps 81
 * lang_* Compose-resource strings); tvOS installs a Foundation-backed one at launch (LANG-03,
 * `NuvioTVApp.init`), falling back to this default (uppercased raw code, e.g. "EN") otherwise.
 * Keeps the 81-string PlayerLanguageLabels.kt out of :shared.
 */
fun interface SubtitleLanguageLabeler {
    suspend fun label(code: String?): String
}

/**
 * Fork (LANG-03): a non-suspending labeler for platforms that implement it outside Kotlin (the
 * tvOS app, in Swift), where a plain callback is simpler and safer to bridge than a suspend one.
 * Called from a background dispatcher.
 */
fun interface BlockingSubtitleLanguageLabeler {
    fun label(code: String?): String
}

object SubtitleLanguageLabelProvider {
    var labeler: SubtitleLanguageLabeler = SubtitleLanguageLabeler { code ->
        code?.trim()?.takeIf { it.isNotBlank() }?.uppercase() ?: ""
    }

    /** Fork (LANG-03): installs [blocking] as the [labeler]. */
    fun installBlocking(blocking: BlockingSubtitleLanguageLabeler) {
        labeler = SubtitleLanguageLabeler { code -> blocking.label(code) }
    }
}
