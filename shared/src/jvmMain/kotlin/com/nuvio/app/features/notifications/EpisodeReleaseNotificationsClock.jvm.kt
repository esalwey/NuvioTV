package com.nuvio.app.features.notifications

import java.time.Instant
import java.time.ZoneId

// Ported from androidMain's actual verbatim — plain java.time, no Context needed.
internal actual object EpisodeReleaseNotificationsClock {
    actual fun isoDateFromEpochMs(epochMs: Long): String =
        Instant.ofEpochMilli(epochMs)
            .atZone(ZoneId.systemDefault())
            .toLocalDate()
            .toString()
}
