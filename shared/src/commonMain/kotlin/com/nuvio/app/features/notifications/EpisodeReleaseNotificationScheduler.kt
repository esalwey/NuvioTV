package com.nuvio.app.features.notifications

import kotlin.concurrent.Volatile

/**
 * Compose-free seam for platform-specific episode-release notification scheduling. The real
 * implementation ([EpisodeReleaseNotificationPlatform]) lives in composeApp because its Android
 * actual uses NotificationManager/WorkManager + app resources and its iOS actual uses
 * UserNotifications. The shared module talks to it only through this interface.
 *
 * Default is a no-op (notifications unsupported / not authorized), so a target with no adapter
 * installed — e.g. tvOS today, which has no local-notification scheduling — still works.
 */
interface EpisodeReleaseNotificationScheduler {
    suspend fun notificationsAuthorized(): Boolean
    suspend fun requestAuthorization(): Boolean
    suspend fun scheduleEpisodeReleaseNotifications(requests: List<EpisodeReleaseNotificationRequest>)
    suspend fun clearScheduledEpisodeReleaseNotifications()
    suspend fun showTestNotification(request: EpisodeReleaseNotificationRequest)
}

/** Process-wide holder for the active scheduler. composeApp installs the real one at startup. */
object EpisodeReleaseNotificationSchedulerProvider {
    @Volatile
    var scheduler: EpisodeReleaseNotificationScheduler = NoOpEpisodeReleaseNotificationScheduler
}

private object NoOpEpisodeReleaseNotificationScheduler : EpisodeReleaseNotificationScheduler {
    override suspend fun notificationsAuthorized(): Boolean = false
    override suspend fun requestAuthorization(): Boolean = false
    override suspend fun scheduleEpisodeReleaseNotifications(requests: List<EpisodeReleaseNotificationRequest>) {}
    override suspend fun clearScheduledEpisodeReleaseNotifications() {}
    override suspend fun showTestNotification(request: EpisodeReleaseNotificationRequest) {}
}
