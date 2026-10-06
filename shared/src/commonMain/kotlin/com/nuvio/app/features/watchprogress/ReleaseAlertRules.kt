package com.nuvio.app.features.watchprogress

import com.nuvio.app.core.time.parseEpisodeReleaseEpochMs
import co.touchlab.kermit.Logger

// Fork placement: upstream keeps this in composeApp AirDateUtils; body matches upstream v0.3.0
// (core.time epoch parser — date-only values are UTC midnight, zoned values exact instants).
fun parseReleaseDateToEpochMs(raw: String?): Long? {
    return parseEpisodeReleaseEpochMs(raw)
}

class ReleaseAlertState(
    val isReleaseAlert: Boolean,
    val isNewSeasonRelease: Boolean,
)

fun calculateReleaseAlertState(
    seedLastUpdatedEpochMs: Long,
    seedSeasonNumber: Int?,
    nextSeasonNumber: Int?,
    releasedIso: String?,
): ReleaseAlertState {
    val releaseEpoch = parseReleaseDateToEpochMs(releasedIso)
    val nowMs = WatchProgressClock.nowEpochMs()

    val log = Logger.withTag("ReleaseAlert")
    log.d {
        "calculateReleaseAlertState inputs: releasedIso=$releasedIso, " +
        "releaseEpoch=$releaseEpoch, seedLastUpdatedEpochMs=$seedLastUpdatedEpochMs, " +
        "seedSeasonNumber=$seedSeasonNumber, nextSeasonNumber=$nextSeasonNumber, nowMs=$nowMs"
    }

    if (releaseEpoch == null) {
        log.d { "calculateReleaseAlertState failed: releaseEpoch is null" }
        return ReleaseAlertState(false, false)
    }

    val hasAired = nowMs >= releaseEpoch
    val sixtyDaysMs = 60L * 24 * 60 * 60 * 1000
    val isReleaseAlert = hasAired &&
        releaseEpoch > seedLastUpdatedEpochMs &&
        (nowMs - releaseEpoch) < sixtyDaysMs

    val isNewSeasonRelease = isReleaseAlert &&
        seedSeasonNumber != null &&
        nextSeasonNumber != null &&
        nextSeasonNumber != seedSeasonNumber

    log.d {
        "calculateReleaseAlertState result: isReleaseAlert=$isReleaseAlert (hasAired=$hasAired, " +
        "epoch>seed=${releaseEpoch > seedLastUpdatedEpochMs}, ageMs=${nowMs - releaseEpoch}), " +
        "isNewSeasonRelease=$isNewSeasonRelease"
    }

    return ReleaseAlertState(
        isReleaseAlert = isReleaseAlert,
        isNewSeasonRelease = isNewSeasonRelease
    )
}
