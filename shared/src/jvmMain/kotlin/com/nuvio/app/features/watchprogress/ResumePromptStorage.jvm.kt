package com.nuvio.app.features.watchprogress

// JVM actual for shared/src/jvmMain (beta.14 Wave 4 / :shared jvm test target, see
// docs/issue-triage-plan-2026-08-21.md §6.1). Ported from the androidMain actual in this
// same relative path: same key layout, JvmSharedPreferences swapped in for
// android.content.SharedPreferences (no Context needed on the JVM).

import com.nuvio.app.core.storage.JvmSharedPreferences
import com.nuvio.app.core.storage.jvmSharedPreferences
import com.nuvio.app.core.storage.ProfileScopedKey

actual object ResumePromptStorage {
    private const val preferencesName = "nuvio_resume_prompt"
    private const val wasInPlayerKey = "was_in_player"
    private const val lastPlayerVideoIdKey = "last_player_video_id"

    private val preferences: JvmSharedPreferences? = jvmSharedPreferences(preferencesName)

    actual fun loadWasInPlayer(): Boolean =
        preferences?.getBoolean(ProfileScopedKey.of(wasInPlayerKey), false) ?: false

    actual fun saveWasInPlayer(value: Boolean) {
        preferences?.edit()?.putBoolean(ProfileScopedKey.of(wasInPlayerKey), value)?.apply()
    }

    actual fun loadLastPlayerVideoId(): String? =
        preferences?.getString(ProfileScopedKey.of(lastPlayerVideoIdKey), null)

    actual fun saveLastPlayerVideoId(videoId: String?) {
        preferences?.edit()?.apply {
            if (videoId != null) {
                putString(ProfileScopedKey.of(lastPlayerVideoIdKey), videoId)
            } else {
                remove(ProfileScopedKey.of(lastPlayerVideoIdKey))
            }
            apply()
        }
    }
}
