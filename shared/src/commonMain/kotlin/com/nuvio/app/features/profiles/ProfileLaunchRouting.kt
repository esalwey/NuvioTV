package com.nuvio.app.features.profiles

/**
 * "Remember last profile": the profile the launch gate may enter without showing "Who's
 * watching?", or null when the picker has to be shown.
 *
 * The picker is skipped only when the user turned the setting on, has selected a profile before,
 * the profile they last used still exists, and it has no PIN (a locked profile always asks).
 * Mirrors the mobile app's launch routing (`App.kt`).
 */
internal fun resolveLaunchProfile(state: ProfileState, lastActiveProfileIndex: Int): NuvioProfile? {
    if (!state.rememberLastProfileEnabled || !state.hasEverSelectedProfile) return null
    val profile = state.profiles.firstOrNull { it.profileIndex == lastActiveProfileIndex } ?: return null
    return profile.takeUnless { it.pinEnabled }
}
