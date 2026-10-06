package com.nuvio.app.features.profiles

import com.nuvio.app.core.coroutines.uncaughtCoroutineLogger
import co.touchlab.kermit.Logger
import com.nuvio.app.core.auth.AuthRepository
import com.nuvio.app.core.auth.AuthState
import com.nuvio.app.core.auth.isAnonymous
import com.nuvio.app.core.network.SupabaseProvider
import com.nuvio.app.core.i18n.StringKey
import com.nuvio.app.core.i18n.resourceString
import com.nuvio.app.core.sync.putSyncOriginClientId
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put

@Serializable
private data class StoredProfilePayload(
    val userId: String,
    val activeProfileIndex: Int = 1,
    val hasEverSelectedProfile: Boolean = false,
    val rememberLastProfileEnabled: Boolean = false,
    val profiles: List<NuvioProfile> = emptyList(),
)

object ProfileRepository {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + uncaughtCoroutineLogger("ProfileRepository"))
    private val log = Logger.withTag("ProfileRepository")
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val _state = MutableStateFlow(ProfileState())
    val state: StateFlow<ProfileState> = _state.asStateFlow()

    private var activeProfileIndex: Int = 1
    private var loadedCacheForUserId: String? = null

    val activeProfileId: Int get() = activeProfileIndex

    fun setRememberLastProfileEnabled(enabled: Boolean) {
        if (_state.value.rememberLastProfileEnabled == enabled) return

        _state.value = _state.value.copy(rememberLastProfileEnabled = enabled)
        persist()
    }

    fun loadCachedProfiles(): Boolean {
        val stored = decodeStoredPayload() ?: return false
        loadedCacheForUserId = stored.userId
        applyStoredPayload(stored)
        ProfileLifecycleProvider.coordinator.onProfilesCached()
        return _state.value.profiles.isNotEmpty()
    }

    fun ensureLoaded(userId: String) {
        if (loadedCacheForUserId == userId && _state.value.isLoaded) return

        val stored = decodeStoredPayload()
        loadedCacheForUserId = userId
        if (stored == null) {
            _state.value = ProfileState()
            activeProfileIndex = 1
            return
        }

        if (stored.userId != userId) {
            _state.value = ProfileState()
            activeProfileIndex = 1
            return
        }

        applyStoredPayload(stored)
    }

    fun clearInMemory() {
        loadedCacheForUserId = null
        activeProfileIndex = 1
        _state.value = ProfileState()
    }

    suspend fun pullProfiles() {
        if (AuthRepository.state.value.isAnonymous) {
            if (!_state.value.isLoaded) {
                _state.value = _state.value.copy(isLoaded = true)
            }
            return
        }
        try {
            val result = SupabaseProvider.client.postgrest.rpc("sync_pull_profiles")
            val profiles = result.decodeList<NuvioProfile>()
            _state.value = _state.value.copy(
                profiles = profiles.sortedBy { it.profileIndex },
                isLoaded = true,
                activeProfile = profiles.find { it.profileIndex == activeProfileIndex }
                    ?: profiles.firstOrNull(),
            )
            if (_state.value.activeProfile != null) {
                activeProfileIndex = _state.value.activeProfile!!.profileIndex
            }
            persist()
        } catch (e: Throwable) {
            if (AuthRepository.signOutIfSessionInvalid(e, "Profile pull")) return
            log.e(e) { "Failed to pull profiles" }
            if (!_state.value.isLoaded) {
                _state.value = _state.value.copy(isLoaded = true)
            }
        }
    }

    fun selectProfile(profileIndex: Int) {
        activeProfileIndex = profileIndex
        val selectedProfile = _state.value.profiles.find { it.profileIndex == profileIndex }
        _state.value = _state.value.copy(
            activeProfile = selectedProfile,
            hasEverSelectedProfile = selectedProfile != null || _state.value.hasEverSelectedProfile,
        )
        // Persistence and the repository fan-out are best-effort side effects of a selection that
        // has already happened. Both run on the caller's thread — on tvOS that is the Swift main
        // thread, where an escaped Kotlin exception aborts the process instead of surfacing as a
        // catchable Swift error, so a single failing repository would make every profile tap a
        // force-close. Degrade to a log and let the user into the app.
        runCatching { persist() }
            .onFailure { log.e(it) { "Failed to persist profile selection $profileIndex" } }
        runCatching { ProfileLifecycleProvider.coordinator.onProfileSelected(profileIndex) }
            .onFailure { log.e(it) { "Profile-select fan-out failed for profile $profileIndex" } }
    }

    /**
     * Returns true once the profiles are saved (locally in guest mode, on the server otherwise).
     * STAB-09: callers used to get no signal at all when the push failed, so an edit that never
     * reached the server looked saved until the next pull reverted it.
     */
    suspend fun pushProfiles(profiles: List<ProfilePushPayload>): Boolean {
        if (AuthRepository.state.value.isAnonymous) {
            applyPayloadsLocally(profiles)
            return true
        }
        return try {
            val params = buildJsonObject {
                put("p_client_max_profiles", MAX_PROFILES)
                put("p_profiles", json.encodeToJsonElement(profiles))
                putSyncOriginClientId()
            }
            SupabaseProvider.client.postgrest.rpc("sync_push_profiles", params)
            pullProfiles()
            true
        } catch (e: Throwable) {
            if (e is CancellationException) throw e
            if (!AuthRepository.signOutIfSessionInvalid(e, "Profile push")) {
                log.e(e) { "Failed to push profiles" }
            }
            false
        }
    }

    suspend fun createProfile(
        name: String,
        avatarColorHex: String,
        avatarId: String? = null,
        avatarUrl: String? = null,
        usesPrimaryAddons: Boolean = false,
    ): Boolean {
        val existing = _state.value.profiles
        val nextIndex = ((1..MAX_PROFILES).toSet() - existing.map { it.profileIndex }.toSet()).minOrNull() ?: return false

        val allPayloads = existing.map { profile ->
            ProfilePushPayload(
                profileIndex = profile.profileIndex,
                name = profile.name,
                avatarColorHex = profile.avatarColorHex,
                usesPrimaryAddons = profile.usesPrimaryAddons,
                usesPrimaryPlugins = profile.usesPrimaryPlugins,
                avatarId = profile.avatarId,
                avatarUrl = profile.avatarUrl,
            )
        } + ProfilePushPayload(
            profileIndex = nextIndex,
            name = name,
            avatarColorHex = avatarColorHex,
            usesPrimaryAddons = usesPrimaryAddons,
            avatarId = avatarId,
            avatarUrl = avatarUrl,
        )

        return pushProfiles(allPayloads)
    }

    suspend fun updateProfile(
        profileIndex: Int,
        name: String,
        avatarColorHex: String,
        avatarId: String? = null,
        avatarUrl: String? = null,
        usesPrimaryAddons: Boolean = false,
    ): Boolean {
        val allPayloads = _state.value.profiles.map { profile ->
            if (profile.profileIndex == profileIndex) {
                ProfilePushPayload(
                    profileIndex = profileIndex,
                    name = name,
                    avatarColorHex = avatarColorHex,
                    usesPrimaryAddons = usesPrimaryAddons,
                    // STAB-09: the edit form has no plugins toggle, so keep the stored value
                    // instead of resetting it to false on every save.
                    usesPrimaryPlugins = profile.usesPrimaryPlugins,
                    avatarId = avatarId,
                    avatarUrl = avatarUrl,
                )
            } else {
                ProfilePushPayload(
                    profileIndex = profile.profileIndex,
                    name = profile.name,
                    avatarColorHex = profile.avatarColorHex,
                    usesPrimaryAddons = profile.usesPrimaryAddons,
                    usesPrimaryPlugins = profile.usesPrimaryPlugins,
                    avatarId = profile.avatarId,
                    avatarUrl = profile.avatarUrl,
                )
            }
        }

        return pushProfiles(allPayloads)
    }

    suspend fun deleteProfile(profileIndex: Int) {
        // PRF-1: the primary profile (index 1) owns the account's shared add-ons and can't be
        // deleted — upstream's UI only offers deletion above index 1; guard the call too.
        if (profileIndex <= 1) {
            log.w { "deleteProfile($profileIndex) ignored: the primary profile can't be deleted" }
            return
        }
        if (AuthRepository.state.value.isAnonymous) {
            val remaining = _state.value.profiles.filter { it.profileIndex != profileIndex }
            ProfilePinCacheStorage.removePayload(profileIndex)
            _state.value = _state.value.copy(
                profiles = remaining,
                activeProfile = if (_state.value.activeProfile?.profileIndex == profileIndex) remaining.firstOrNull() else _state.value.activeProfile,
            )
            if (_state.value.activeProfile != null) {
                activeProfileIndex = _state.value.activeProfile!!.profileIndex
            }
            persist()
            return
        }
        try {
            val params = buildJsonObject {
                put("p_profile_id", profileIndex)
                putSyncOriginClientId()
            }
            SupabaseProvider.client.postgrest.rpc("sync_delete_profile_data", params)
            pullProfiles()
        } catch (e: Throwable) {
            if (AuthRepository.signOutIfSessionInvalid(e, "Profile delete")) return
            log.e(e) { "Failed to delete profile $profileIndex" }
        }
    }

    suspend fun verifyPin(profileIndex: Int, pin: String): PinVerifyResult {
        if (AuthRepository.state.value !is AuthState.Authenticated) {
            return verifyPinLocally(profileIndex, pin)
        }

        return runCatching {
            val params = buildJsonObject {
                put("p_profile_id", profileIndex)
                put("p_pin", pin)
            }
            val result = SupabaseProvider.client.postgrest.rpc("verify_profile_pin", params)
            result.decodeSingle<PinVerifyResult>().also { verifyResult ->
                if (verifyResult.unlocked) {
                    // Upstream 5327166f: refresh the cached profile before remembering the PIN so
                    // a server-side profile change since the last pull isn't cached against.
                    pullProfiles()
                    rememberVerifiedPin(profileIndex = profileIndex, pin = pin)
                }
            }
        }.getOrElse { e ->
            log.e(e) { "Failed to verify pin" }
            verifyPinLocally(profileIndex, pin)
        }
    }

    suspend fun setPin(profileIndex: Int, pin: String, currentPin: String? = null): PinVerifyResult {
        if (AuthRepository.state.value !is AuthState.Authenticated) {
            return PinVerifyResult(unlocked = false, message = resourceString("Connect to the internet to set a PIN.", StringKey.profile_pin_set_requires_internet))
        }

        return runCatching {
            val params = buildJsonObject {
                put("p_profile_id", profileIndex)
                put("p_pin", pin)
                currentPin?.let { put("p_current_pin", it) }
            }
            SupabaseProvider.client.postgrest.rpc("set_profile_pin", params)
            pullProfiles()
            rememberVerifiedPin(profileIndex = profileIndex, pin = pin)
            PinVerifyResult(unlocked = true)
        }.onFailure { e ->
            log.e(e) { "Failed to set pin" }
        }.getOrElse {
            PinVerifyResult(unlocked = false, message = resourceString("Couldn't set PIN. Try again.", StringKey.profile_pin_set_failed))
        }
    }

    suspend fun clearPin(profileIndex: Int, currentPin: String? = null): PinVerifyResult {
        if (AuthRepository.state.value !is AuthState.Authenticated) {
            return PinVerifyResult(unlocked = false, message = resourceString("Connect to the internet to remove the PIN lock.", StringKey.profile_pin_clear_requires_internet))
        }

        return runCatching {
            val params = buildJsonObject {
                put("p_profile_id", profileIndex)
                currentPin?.let { put("p_current_pin", it) }
            }
            SupabaseProvider.client.postgrest.rpc("clear_profile_pin", params)
            pullProfiles()
            ProfilePinCacheStorage.removePayload(profileIndex)
            PinVerifyResult(unlocked = true)
        }.onFailure { e ->
            log.e(e) { "Failed to clear pin" }
        }.getOrElse {
            PinVerifyResult(unlocked = false, message = resourceString("Couldn't remove PIN lock. Try again.", StringKey.profile_pin_clear_failed))
        }
    }

    suspend fun clearPinWithPassword(profileIndex: Int, accountPassword: String) {
        runCatching {
            val params = buildJsonObject {
                put("p_account_password", accountPassword)
                put("p_profile_id", profileIndex)
            }
            SupabaseProvider.client.postgrest.rpc("clear_profile_pin_with_account_password", params)
            pullProfiles()
            ProfilePinCacheStorage.removePayload(profileIndex)
        }.onFailure { e ->
            log.e(e) { "Failed to clear pin with password" }
        }
    }

    suspend fun pullProfileLocks(): List<ProfileLockState> {
        return runCatching {
            val result = SupabaseProvider.client.postgrest.rpc("sync_pull_profile_locks")
            result.decodeList<ProfileLockState>()
        }.getOrElse { e ->
            log.e(e) { "Failed to pull profile locks" }
            emptyList()
        }
    }

    private fun applyPayloadsLocally(payloads: List<ProfilePushPayload>) {
        val authState = AuthRepository.state.value as? AuthState.Authenticated ?: return
        val profiles = payloads.map { p ->
            NuvioProfile(
                id = "",
                userId = authState.userId,
                profileIndex = p.profileIndex,
                name = p.name,
                avatarColorHex = p.avatarColorHex,
                avatarId = p.avatarId,
                avatarUrl = p.avatarUrl,
                usesPrimaryAddons = p.usesPrimaryAddons,
                usesPrimaryPlugins = p.usesPrimaryPlugins,
            )
        }.sortedBy { it.profileIndex }
        _state.value = _state.value.copy(
            profiles = profiles,
            isLoaded = true,
            activeProfile = profiles.find { it.profileIndex == activeProfileIndex } ?: profiles.firstOrNull(),
        )
        if (_state.value.activeProfile != null) {
            activeProfileIndex = _state.value.activeProfile!!.profileIndex
        }
        syncPinCache(profiles)
        persist()
    }

    private fun decodeStoredPayload(): StoredProfilePayload? {
        val payload = ProfileStorage.loadPayload().orEmpty().trim()
        if (payload.isEmpty()) return null

        return runCatching {
            json.decodeFromString<StoredProfilePayload>(payload)
        }.getOrNull()
    }

    private fun applyStoredPayload(stored: StoredProfilePayload) {
        val profiles = stored.profiles.sortedBy { it.profileIndex }
        activeProfileIndex = stored.activeProfileIndex
        _state.value = ProfileState(
            profiles = profiles,
            activeProfile = profiles.find { it.profileIndex == activeProfileIndex } ?: profiles.firstOrNull(),
            isLoaded = profiles.isNotEmpty(),
            hasEverSelectedProfile = stored.hasEverSelectedProfile,
            rememberLastProfileEnabled = stored.rememberLastProfileEnabled,
        )
        _state.value.activeProfile?.let { activeProfileIndex = it.profileIndex }
        syncPinCache(profiles)
    }

    private fun rememberVerifiedPin(profileIndex: Int, pin: String) {
        val profile = _state.value.profiles.find { it.profileIndex == profileIndex }
        val salt = generateProfilePinSalt()
        val payload = CachedProfilePinPayload(
            salt = salt,
            digest = hashProfilePin(profileIndex = profileIndex, salt = salt, pin = pin),
            profileUpdatedAt = profile?.updatedAt.orEmpty(),
        )
        ProfilePinCacheStorage.savePayload(profileIndex, json.encodeToString(payload))
    }

    private fun verifyPinLocally(profileIndex: Int, pin: String): PinVerifyResult {
        val profile = _state.value.profiles.find { it.profileIndex == profileIndex }
        if (profile?.pinEnabled != true) {
            return PinVerifyResult(unlocked = true)
        }

        val payload = ProfilePinCacheStorage.loadPayload(profileIndex).orEmpty().trim()
        if (payload.isEmpty()) {
            return PinVerifyResult(
                unlocked = false,
                message = resourceString("This PIN can't be verified offline on this device yet. Connect once and unlock it online first.", StringKey.profile_pin_offline_verification_requires_online),
            )
        }

        val cached = runCatching {
            json.decodeFromString<CachedProfilePinPayload>(payload)
        }.getOrNull() ?: return PinVerifyResult(
            unlocked = false,
            message = resourceString("This PIN can't be verified offline on this device yet. Connect once and unlock it online first.", StringKey.profile_pin_offline_verification_requires_online),
        )

        if (
            cached.profileUpdatedAt.isNotBlank() &&
            profile.updatedAt.isNotBlank() &&
            cached.profileUpdatedAt != profile.updatedAt
        ) {
            ProfilePinCacheStorage.removePayload(profileIndex)
            return PinVerifyResult(
                unlocked = false,
                message = resourceString("This profile PIN changed. Connect once to refresh the lock on this device.", StringKey.profile_pin_changed_requires_refresh),
            )
        }

        val digest = hashProfilePin(profileIndex = profileIndex, salt = cached.salt, pin = pin)
        return if (digest == cached.digest) {
            PinVerifyResult(unlocked = true)
        } else {
            PinVerifyResult(unlocked = false, message = resourceString("Incorrect PIN", StringKey.pin_incorrect))
        }
    }

    private fun syncPinCache(profiles: List<NuvioProfile>) {
        val profilesByIndex = profiles.associateBy { it.profileIndex }
        for (profileIndex in 1..MAX_PROFILES) {
            val profile = profilesByIndex[profileIndex]
            if (profile == null || !profile.pinEnabled) {
                ProfilePinCacheStorage.removePayload(profileIndex)
                continue
            }

            val raw = ProfilePinCacheStorage.loadPayload(profileIndex).orEmpty().trim()
            if (raw.isEmpty()) continue

            val cached = runCatching {
                json.decodeFromString<CachedProfilePinPayload>(raw)
            }.getOrNull() ?: run {
                ProfilePinCacheStorage.removePayload(profileIndex)
                continue
            }

            if (
                cached.profileUpdatedAt.isNotBlank() &&
                profile.updatedAt.isNotBlank() &&
                cached.profileUpdatedAt != profile.updatedAt
            ) {
                ProfilePinCacheStorage.removePayload(profileIndex)
            }
        }
    }

    private fun persist() {
        val authState = AuthRepository.state.value as? AuthState.Authenticated ?: return
        val state = _state.value
        ProfileStorage.savePayload(
            json.encodeToString(
                StoredProfilePayload(
                    userId = authState.userId,
                    activeProfileIndex = activeProfileIndex,
                    hasEverSelectedProfile = state.hasEverSelectedProfile,
                    rememberLastProfileEnabled = state.rememberLastProfileEnabled,
                    profiles = state.profiles,
                ),
            ),
        )
    }
}

@kotlinx.serialization.Serializable
data class ProfileLockState(
    @kotlinx.serialization.SerialName("profile_index") val profileIndex: Int,
    @kotlinx.serialization.SerialName("pin_enabled") val pinEnabled: Boolean = false,
    @kotlinx.serialization.SerialName("pin_locked_until") val pinLockedUntil: String? = null,
)
