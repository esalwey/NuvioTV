package com.nuvio.app.features.player

import java.util.Locale

/**
 * JVM actual (beta.14 Wave 4, docs/issue-triage-plan-2026-08-21.md §6.1). Android reads
 * `LocaleList`/`Locale.getDefault()`; the JVM has no locale list API, so this uses the JVM's
 * single default locale — good enough for tests, which don't exercise this expect (see the
 * task's exclusion notes) but need it to compile and not throw.
 */
actual object DeviceLanguagePreferences {
    actual fun preferredLanguageCodes(): List<String> {
        val languages = mutableListOf<String>()
        appendLocaleCodes(languages, Locale.getDefault())
        if (languages.isEmpty()) {
            appendLocaleCodes(languages, Locale.ENGLISH)
        }
        return languages
            .mapNotNull(::normalizeLanguageCode)
            .distinct()
    }

    private fun appendLocaleCodes(bucket: MutableList<String>, locale: Locale) {
        bucket += locale.toLanguageTag()
        bucket += locale.language
    }
}
