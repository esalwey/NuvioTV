package com.nuvio.app.features.trakt

import com.nuvio.app.core.time.parseZonedIsoDateTimeToEpochMs

// Fork: public (upstream: internal) — composeApp tests consume cross-module.
fun parseTraktIsoDateTimeToEpochMs(value: String): Long? =
    parseZonedIsoDateTimeToEpochMs(value)
