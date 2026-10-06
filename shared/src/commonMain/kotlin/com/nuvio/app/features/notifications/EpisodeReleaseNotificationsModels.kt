package com.nuvio.app.features.notifications

import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import com.nuvio.app.core.time.parseEpisodeReleaseLocalDate
import kotlinx.serialization.Serializable
import kotlin.math.abs

data class EpisodeReleaseNotificationsUiState(
    val isEnabled: Boolean = false,
    val isLoading: Boolean = false,
    val permissionGranted: Boolean = false,
    val scheduledCount: Int = 0,
    val testTargetTitle: String? = null,
    val isSendingTest: Boolean = false,
    val statusMessage: String? = null,
    val errorMessage: String? = null,
)

@Serializable
internal data class StoredEpisodeReleaseNotificationsPayload(
    val enabled: Boolean = false,
    val followedShows: List<TrackedFollowedShow> = emptyList(),
)

@Serializable
internal data class TrackedFollowedShow(
    val contentId: String,
    val contentType: String,
    val followedOnIsoDate: String,
)

data class EpisodeReleaseNotificationRequest(
    val requestId: String,
    val notificationTitle: String,
    val notificationBody: String,
    val releaseDateIso: String,
    val deepLinkUrl: String,
    val backdropUrl: String? = null,
)

const val EpisodeReleaseNotificationHour = 9
const val EpisodeReleaseNotificationMinute = 0
internal const val MinReasonableSavedAtEpochMs = 946684800000L

internal fun buildTrackedShowKey(
    type: String,
    id: String,
): String = "${normalizeSeriesType(type)}:${id.trim()}"

internal fun normalizeSeriesType(type: String): String = when (type.trim().lowercase()) {
    "tv", "show", "series", "tvshow" -> "series"
    else -> type.trim().lowercase()
}

internal fun isSeriesLibraryType(type: String): Boolean = normalizeSeriesType(type) == "series"

internal fun releaseDateIso(rawValue: String?): String? {
    return parseEpisodeReleaseLocalDate(rawValue)
}

internal fun buildEpisodeReleaseNotificationId(
    profileId: Int,
    contentType: String,
    contentId: String,
    episodeId: String,
    releaseDateIso: String,
): String {
    val contentHash = abs(buildTrackedShowKey(contentType, contentId).hashCode())
    val episodeHash = abs(episodeId.trim().ifBlank { releaseDateIso }.hashCode())
    return "episode-release-$profileId-$contentHash-$episodeHash-$releaseDateIso"
}

internal fun buildEpisodeReleaseNotificationBody(
    seasonNumber: Int?,
    episodeNumber: Int?,
    episodeTitle: String?,
): String {
    val code = when {
        seasonNumber != null && episodeNumber != null ->
            resourceString("S%1\$d:E%2\$d", StringKey.compose_player_episode_code_full, seasonNumber, episodeNumber)
        episodeNumber != null ->
            resourceString("E%1\$d", StringKey.compose_player_episode_code_episode_only, episodeNumber)
        else -> ""
    }
    val title = episodeTitle?.trim().takeUnless { it.isNullOrBlank() }

    return when {
        code.isNotBlank() && title != null ->
            resourceString("%1\$s • %2\$s is out now", StringKey.notifications_episode_release_body_code_title, code, title)
        code.isNotBlank() ->
            resourceString("%1\$s is out now", StringKey.notifications_episode_release_body_code, code)
        title != null ->
            resourceString("%1\$s is out now", StringKey.notifications_episode_release_body_title, title)
        else ->
            resourceString("A new episode is out now", StringKey.notifications_episode_release_body_generic)
    }
}
