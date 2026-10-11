package com.nuvio.app.features.mdblist

data class MdbListSettings(
    val enabled: Boolean = false,
    val apiKey: String = "",
    val useImdb: Boolean = true,
    val useTmdb: Boolean = true,
    val useTomatoes: Boolean = true,
    val useMetacritic: Boolean = true,
    val useTrakt: Boolean = true,
    val useLetterboxd: Boolean = true,
    val useAudience: Boolean = true,
    val useMal: Boolean = true,
    /** Display / fetch order of the providers. Always a permutation of all known provider ids. */
    val providerOrder: List<String> = MdbListMetadataService.PROVIDER_PRIORITY_ORDER,
) {
    val hasApiKey: Boolean
        get() = apiKey.isNotBlank()

    fun isProviderEnabled(providerId: String): Boolean =
        when (providerId) {
            MdbListMetadataService.PROVIDER_IMDB -> useImdb
            MdbListMetadataService.PROVIDER_TMDB -> useTmdb
            MdbListMetadataService.PROVIDER_TOMATOES -> useTomatoes
            MdbListMetadataService.PROVIDER_METACRITIC -> useMetacritic
            MdbListMetadataService.PROVIDER_TRAKT -> useTrakt
            MdbListMetadataService.PROVIDER_LETTERBOXD -> useLetterboxd
            MdbListMetadataService.PROVIDER_AUDIENCE -> useAudience
            MdbListMetadataService.PROVIDER_MAL -> useMal
            else -> false
        }

    fun enabledProvidersInPriorityOrder(): List<String> =
        normalizeMdbListProviderOrder(providerOrder).filter(::isProviderEnabled)
}

/**
 * A stored order may be partial or hold unknown ids (an older build, another platform). Keeps the
 * known ids in the given order without duplicates, then appends any missing provider in the
 * default order, so the result is always a full permutation of the known providers.
 */
fun normalizeMdbListProviderOrder(order: List<String>?): List<String> {
    val known = MdbListMetadataService.PROVIDER_PRIORITY_ORDER
    val kept = order.orEmpty().filter { it in known }.distinct()
    return kept + known.filter { it !in kept }
}

private const val PROVIDER_ORDER_SEPARATOR = ","

internal fun encodeMdbListProviderOrder(order: List<String>): String =
    normalizeMdbListProviderOrder(order).joinToString(PROVIDER_ORDER_SEPARATOR)

internal fun decodeMdbListProviderOrder(value: String?): List<String> =
    normalizeMdbListProviderOrder(
        value?.split(PROVIDER_ORDER_SEPARATOR)?.map(String::trim)?.filter(String::isNotEmpty),
    )

