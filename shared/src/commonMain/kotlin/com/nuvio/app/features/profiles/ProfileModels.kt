package com.nuvio.app.features.profiles

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

const val MAX_PROFILES = 6

@Serializable
data class NuvioProfile(
    val id: String = "",
    @SerialName("user_id") val userId: String = "",
    @SerialName("profile_index") val profileIndex: Int = 1,
    val name: String = "",
    @SerialName("avatar_color_hex") val avatarColorHex: String = "#1E88E5",
    @SerialName("avatar_id") val avatarId: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    @SerialName("uses_primary_addons") val usesPrimaryAddons: Boolean = false,
    @SerialName("uses_primary_plugins") val usesPrimaryPlugins: Boolean = false,
    @SerialName("pin_enabled") val pinEnabled: Boolean = false,
    @SerialName("pin_locked_until") val pinLockedUntil: String? = null,
    @SerialName("created_at") val createdAt: String = "",
    @SerialName("updated_at") val updatedAt: String = "",
)

@Serializable
data class ProfilePushPayload(
    @SerialName("profile_index") val profileIndex: Int,
    val name: String,
    @SerialName("avatar_color_hex") val avatarColorHex: String,
    @SerialName("uses_primary_addons") val usesPrimaryAddons: Boolean = false,
    @SerialName("uses_primary_plugins") val usesPrimaryPlugins: Boolean = false,
    @SerialName("avatar_id") val avatarId: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
)

@Serializable
data class PinVerifyResult(
    val unlocked: Boolean = false,
    @SerialName("retry_after_seconds") val retryAfterSeconds: Int = 0,
    val message: String? = null,
)

data class ProfileState(
    val profiles: List<NuvioProfile> = emptyList(),
    val activeProfile: NuvioProfile? = null,
    val isLoaded: Boolean = false,
    val hasEverSelectedProfile: Boolean = false,
    val rememberLastProfileEnabled: Boolean = false,
)

@Serializable
data class AvatarCatalogItem(
    val id: String,
    @SerialName("display_name") val displayName: String = "",
    @SerialName("storage_path") val storagePath: String = "",
    val category: String = "character",
    @SerialName("sort_order") val sortOrder: Int = 0,
    @SerialName("is_active") val isActive: Boolean = true,
    @SerialName("bg_color") val bgColor: String? = null,
)

fun avatarStorageUrl(storagePath: String): String =
    "${com.nuvio.app.core.network.ServerConfigurationRepository.active.value.backendUrl}/storage/v1/object/public/avatars/$storagePath"

fun normalizedAvatarUrl(url: String?): String? =
    url?.trim()?.takeIf { it.isValidAvatarUrl() }

/// Sanity bound for inline `data:image/...;base64,...` avatars (e.g. custom pictures imported
/// from other Nuvio clients such as the mobile "Xperence" app, which write the encoded image
/// straight into `avatar_url` rather than a Supabase storage URL). Generous enough for a decent
/// profile-photo-sized JPEG/PNG once base64-inflated, but bounded so a malformed/huge value can't
/// bloat sync payloads or the on-device cache indefinitely.
private const val MAX_DATA_URI_AVATAR_LENGTH = 2 * 1024 * 1024

fun String.isValidAvatarUrl(): Boolean {
    val value = trim()
    if (value.any { it.isWhitespace() }) return false
    return when {
        value.startsWith("https://") || value.startsWith("http://") -> value.length <= 2048
        value.startsWith("data:image/") -> value.length <= MAX_DATA_URI_AVATAR_LENGTH
        else -> false
    }
}

fun profileAvatarImageUrl(profile: NuvioProfile, avatar: AvatarCatalogItem?): String? =
    normalizedAvatarUrl(profile.avatarUrl)
        ?: avatar
            ?.storagePath
            ?.takeIf { it.isNotBlank() }
            ?.let(::avatarStorageUrl)
