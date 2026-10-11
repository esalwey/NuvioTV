package com.nuvio.app.features.mdblist

/**
 * What authorizes an MDBList ratings request: an API key typed by the user (which overrides the
 * account) or the connected MDBList account.
 */
internal sealed interface MdbListRatingsCredential {
    /** Stable text for cache keys. It never contains the key itself. */
    val cacheId: String

    data class ApiKey(val value: String) : MdbListRatingsCredential {
        override val cacheId: String get() = "key:${value.hashCode()}"
        override fun toString(): String = "ApiKey()"
    }

    data class Account(val scope: MdbListAuthScope) : MdbListRatingsCredential {
        override val cacheId: String get() = "account:${scope.profileId}:${scope.generation}"
    }
}
