package com.nuvio.app.features.details

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object SeasonViewModeStorage {
    private const val preferencesName = "nuvio_season_view_mode"
    private const val key = "season_view_mode"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun load(): SeasonViewMode? =
        preferences?.getString(ProfileScopedKey.of(key), null)?.let(SeasonViewMode::parse)

    actual fun save(mode: SeasonViewMode) {
        preferences
            ?.edit()
            ?.putString(ProfileScopedKey.of(key), SeasonViewMode.persist(mode))
            ?.apply()
    }
}
