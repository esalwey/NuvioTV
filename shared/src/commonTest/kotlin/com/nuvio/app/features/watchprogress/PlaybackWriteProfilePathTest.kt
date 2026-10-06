package com.nuvio.app.features.watchprogress

import com.nuvio.app.core.profile.ActiveProfileIdProvider
import com.nuvio.app.core.profile.ActiveProfileProvider
import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.trakt.TRAKT_DEFAULT_CONTINUE_WATCHING_DAYS_CAP
import com.nuvio.app.features.trakt.TraktSettingsRepository
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * CW legacy diagnosis (REMAINING_FIX #4): a playback write for the active profile while another
 * profile is loaded here used to reach the disk only, where Home never looks.
 */
class PlaybackWriteProfilePathTest {
    @Test
    fun `the loaded active profile writes in memory`() {
        assertEquals(PlaybackWriteProfilePath.LOADED, playbackWriteProfilePath(targetProfileId = 1, loadedProfileId = 1, activeProfileId = 1))
    }

    @Test
    fun `the active profile loaded nowhere is loaded first`() {
        assertEquals(
            PlaybackWriteProfilePath.RELOAD_ACTIVE,
            playbackWriteProfilePath(targetProfileId = 2, loadedProfileId = 1, activeProfileId = 2),
        )
    }

    @Test
    fun `a profile that is not the active one only goes to disk`() {
        assertEquals(
            PlaybackWriteProfilePath.OTHER_PROFILE,
            playbackWriteProfilePath(targetProfileId = 2, loadedProfileId = 2, activeProfileId = 1),
        )
        assertEquals(
            PlaybackWriteProfilePath.OTHER_PROFILE,
            playbackWriteProfilePath(targetProfileId = 3, loadedProfileId = 1, activeProfileId = 2),
        )
    }

    private fun session(profileId: Int, showId: String) = WatchProgressPlaybackSession(
        profileId = profileId,
        contentType = "series",
        parentMetaId = showId,
        parentMetaType = "series",
        videoId = "$showId:1:2",
        title = "Profile Test Show",
        poster = "poster.jpg",
        background = "backdrop.jpg",
        seasonNumber = 1,
        episodeNumber = 2,
    )

    private val playing = PlayerPlaybackSnapshot(
        isLoading = false,
        isPlaying = true,
        durationMs = 2_800_000L,
        positionMs = 600_000L,
    )

    @Test
    fun `a write for the active profile loaded nowhere reaches the published state`() {
        val activeProfileId = ProfileRepository.activeProfileId
        val otherProfileId = activeProfileId + 6
        val showId = "tt0000042"
        try {
            WatchProgressRepository.ensureLoaded()
            // The repository is left on another profile than the active one.
            WatchProgressRepository.onProfileChanged(otherProfileId)

            WatchProgressRepository.upsertPlaybackProgress(
                session = session(profileId = activeProfileId, showId = showId),
                snapshot = playing,
                syncRemote = false,
            )

            assertTrue(WatchProgressRepository.uiState.value.entries.any { it.parentMetaId == showId })
            assertTrue(
                WatchProgressRepository.continueWatchingRow().any { it.parentMetaId == showId },
                "the Home row reads the published state",
            )
            val report = WatchProgressRepository.continueWatchingDiagnosticLines()
            assertTrue(report.first().startsWith("cur=$activeProfileId act=$activeProfileId "), report.toString())
            assertTrue(report.any { line -> line.startsWith("n=") && " xprof=1 " in line }, report.toString())
            assertTrue(
                "xprof last reload target=$activeProfileId current=$otherProfileId active=$activeProfileId" in report,
                report.toString(),
            )
        } finally {
            WatchProgressRepository.clearLocalState()
        }
    }

    @Test
    fun `the reload switches the active profile's tracking settings too`() {
        val originalProfileId = ProfileRepository.activeProfileId
        val activeProfileId = originalProfileId + 9
        val showId = "tt0000043"
        // Profile-scoped settings keys follow the profile repository, as tvOS installs them.
        val originalProvider = ActiveProfileProvider.provider
        ActiveProfileProvider.provider = ActiveProfileIdProvider { ProfileRepository.activeProfileId }
        try {
            // The active profile's own tracking settings: another Continue Watching window.
            ProfileRepository.selectProfile(activeProfileId)
            TraktSettingsRepository.onProfileChanged()
            TraktSettingsRepository.setContinueWatchingDaysCap(7)
            ProfileRepository.selectProfile(originalProfileId)
            TraktSettingsRepository.onProfileChanged()
            WatchProgressRepository.ensureLoaded()
            WatchProgressRepository.onProfileChanged(originalProfileId)
            assertNotEquals(7, TraktSettingsRepository.uiState.value.continueWatchingDaysCap)

            // The active profile changes without its fan-out reaching this repository yet.
            ProfileRepository.selectProfile(activeProfileId)
            WatchProgressRepository.upsertPlaybackProgress(
                session = session(profileId = activeProfileId, showId = showId),
                snapshot = playing,
                syncRemote = false,
            )

            assertTrue(WatchProgressRepository.uiState.value.entries.any { it.parentMetaId == showId })
            assertEquals(
                7,
                TraktSettingsRepository.uiState.value.continueWatchingDaysCap,
                "a bare load would leave the other profile's tracking settings, and the selection's own " +
                    "fan-out would then find the profile loaded and switch nothing",
            )
            // That fan-out, arriving afterwards, changes nothing.
            WatchProgressRepository.onProfileChanged(activeProfileId)
            assertEquals(7, TraktSettingsRepository.uiState.value.continueWatchingDaysCap)
            assertTrue(WatchProgressRepository.uiState.value.entries.any { it.parentMetaId == showId })
        } finally {
            ProfileRepository.selectProfile(activeProfileId)
            TraktSettingsRepository.onProfileChanged()
            TraktSettingsRepository.setContinueWatchingDaysCap(TRAKT_DEFAULT_CONTINUE_WATCHING_DAYS_CAP)
            ProfileRepository.selectProfile(originalProfileId)
            TraktSettingsRepository.onProfileChanged()
            WatchProgressRepository.clearLocalState()
            ActiveProfileProvider.provider = originalProvider
        }
    }
}
