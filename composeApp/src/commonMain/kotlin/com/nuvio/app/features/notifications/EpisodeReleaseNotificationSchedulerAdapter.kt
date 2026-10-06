package com.nuvio.app.features.notifications

/**
 * Installs the composeApp [EpisodeReleaseNotificationPlatform] (its actuals use
 * NotificationManager/WorkManager + app resources on Android and UserNotifications on iOS)
 * behind the shared [EpisodeReleaseNotificationScheduler] seam. Call [install] once at app startup.
 */
object EpisodeReleaseNotificationSchedulerAdapter {
    fun install() {
        EpisodeReleaseNotificationSchedulerProvider.scheduler = object : EpisodeReleaseNotificationScheduler {
            override suspend fun notificationsAuthorized(): Boolean =
                EpisodeReleaseNotificationPlatform.notificationsAuthorized()

            override suspend fun requestAuthorization(): Boolean =
                EpisodeReleaseNotificationPlatform.requestAuthorization()

            override suspend fun scheduleEpisodeReleaseNotifications(requests: List<EpisodeReleaseNotificationRequest>) =
                EpisodeReleaseNotificationPlatform.scheduleEpisodeReleaseNotifications(requests)

            override suspend fun clearScheduledEpisodeReleaseNotifications() =
                EpisodeReleaseNotificationPlatform.clearScheduledEpisodeReleaseNotifications()

            override suspend fun showTestNotification(request: EpisodeReleaseNotificationRequest) =
                EpisodeReleaseNotificationPlatform.showTestNotification(request)
        }
    }
}
