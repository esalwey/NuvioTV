package com.nuvio.app.features.watchprogress

import java.time.LocalDate
import java.time.ZoneId

// Ported from androidMain's actual verbatim — plain java.time, no Context needed.
actual object CurrentDateProvider {
    actual fun todayIsoDate(): String = LocalDate.now().toString()

    actual fun localStartOfDayEpochMs(isoDate: String): Long? =
        runCatching {
            LocalDate.parse(isoDate)
                .atStartOfDay(ZoneId.systemDefault())
                .toInstant()
                .toEpochMilli()
        }.getOrNull()
}
