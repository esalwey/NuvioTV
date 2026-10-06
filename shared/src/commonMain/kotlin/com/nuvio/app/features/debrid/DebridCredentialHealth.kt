package com.nuvio.app.features.debrid

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Session-scoped health of connected debrid credentials (BUG-21 follow-up).
 *
 * "Connected" in Settings only ever meant "a key string is stored" — nothing re-validated it,
 * so an expired/revoked token failed every API call while the UI kept claiming Connected and
 * the stream list kept labeling rows as cached. This object is the missing signal: call sites
 * that see a definitive HTTP status from a provider record it here, and the UI (stream picker
 * banner, Settings pane) observes [authFailedProviderIds] to tell the user to reconnect.
 *
 * Only 401/403 mark a credential unhealthy; any 2xx clears it. Everything else (5xx, network
 * errors, decode failures) is deliberately ignored — a flaky server must not flip the UI into
 * "session expired". State is in-memory only: it resets on relaunch and clears the moment the
 * key changes ([DebridSettingsRepository.setProviderApiKey] calls [clear]).
 */
object DebridCredentialHealth {
    private val _authFailedProviderIds = MutableStateFlow<Set<String>>(emptySet())
    val authFailedProviderIds: StateFlow<Set<String>> = _authFailedProviderIds

    /** Records a definitive HTTP status from a provider call. Non-auth statuses are ignored. */
    fun recordHttpStatus(providerId: String?, status: Int) {
        val id = DebridProviders.byId(providerId)?.id ?: return
        when {
            status in 200..299 -> _authFailedProviderIds.value -= id
            status == 401 || status == 403 -> _authFailedProviderIds.value += id
        }
    }

    fun isAuthFailed(providerId: String?): Boolean {
        val id = DebridProviders.byId(providerId)?.id ?: return false
        return id in _authFailedProviderIds.value
    }

    /** Forgets any recorded failure — used when the stored key changes (reconnect/disconnect). */
    fun clear(providerId: String?) {
        val id = DebridProviders.byId(providerId)?.id ?: return
        _authFailedProviderIds.value -= id
    }

    /**
     * Probes the stored key for [providerId] against the provider's whoami endpoint and records
     * the outcome. Returns true/false for a definitive answer, or null when nothing could be
     * learned (no key stored, provider unknown, or the probe failed in transit) — callers must
     * not treat null as invalid.
     *
     * Note [DebridProviderApi.validateApiKey] collapses every non-2xx to false, so a provider
     * 5xx during the probe records as an auth failure until the next successful call clears it —
     * acceptable for a "reconnect needed" hint, since any later 2xx self-heals.
     */
    suspend fun revalidateStoredCredential(providerId: String): Boolean? {
        val provider = DebridProviders.byId(providerId) ?: return null
        val api = DebridProviderApis.apiFor(provider.id) ?: return null
        val apiKey = DebridSettingsRepository.snapshot()
            .apiKeyFor(provider.id)
            .trim()
            .takeIf { it.isNotBlank() }
            ?: return null
        return try {
            val valid = api.validateApiKey(apiKey)
            recordHttpStatus(provider.id, if (valid) 200 else 401)
            valid
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            null
        }
    }
}
