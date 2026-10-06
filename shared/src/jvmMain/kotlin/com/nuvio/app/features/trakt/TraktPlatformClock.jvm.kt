package com.nuvio.app.features.trakt

import java.time.Instant

// Ported from androidMain's actual verbatim — plain java.time / java.lang, no Context needed.
actual object TraktPlatformClock {
    actual fun nowEpochMs(): Long = System.currentTimeMillis()

    actual fun parseIsoDateTimeToEpochMs(value: String): Long? =
        runCatching { Instant.parse(value).toEpochMilli() }.getOrNull()
            ?: parseTraktIsoDateTimeToEpochMs(value)

    actual fun availableProcessors(): Int = Runtime.getRuntime().availableProcessors()
}
