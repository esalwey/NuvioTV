package com.nuvio.app.features.player

/**
 * Installs the shared [SubtitleLanguageLabelProvider] seam, backed by this app's
 * getLanguageLabelForCode (81 localized lang_* strings). Keeps PlayerLanguageLabels.kt
 * (Compose-resource-backed) out of :shared.
 */
object PlayerLanguageLabelSubtitleLabeler : SubtitleLanguageLabeler {
    override suspend fun label(code: String?): String = getLanguageLabelForCode(code)

    fun install() {
        SubtitleLanguageLabelProvider.labeler = this
    }
}
