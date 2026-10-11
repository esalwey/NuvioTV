package com.nuvio.app.features.mdblist

import com.nuvio.app.features.details.MetaExternalRating
import com.nuvio.app.features.mdblist.MdbListMetadataService.PROVIDER_AUDIENCE
import com.nuvio.app.features.mdblist.MdbListMetadataService.PROVIDER_TOMATOES

/** Which Rotten Tomatoes badge a Tomatometer or Popcornmeter score earns. */
enum class RottenTomatoesStatus {
    FRESH,
    ROTTEN,
    CERTIFIED_FRESH,
    HOT,
    STALE,
    VERIFIED_HOT,
}

val MetaExternalRating.rottenTomatoesStatus: RottenTomatoesStatus?
    get() = when (source) {
        PROVIDER_TOMATOES -> when {
            isCertified && value >= 70 -> RottenTomatoesStatus.CERTIFIED_FRESH
            value >= 60 -> RottenTomatoesStatus.FRESH
            else -> RottenTomatoesStatus.ROTTEN
        }
        PROVIDER_AUDIENCE -> when {
            isCertified && value >= 80 -> RottenTomatoesStatus.VERIFIED_HOT
            value >= 60 -> RottenTomatoesStatus.HOT
            else -> RottenTomatoesStatus.STALE
        }
        else -> null
    }

/**
 * Swift entry point for [rottenTomatoesStatus] (an extension property has no stable name in the
 * generated framework): the badge for [rating], or null for a provider that has none.
 */
fun rottenTomatoesStatusOf(rating: MetaExternalRating): RottenTomatoesStatus? = rating.rottenTomatoesStatus
