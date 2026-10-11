package com.nuvio.app.core.auth

import co.touchlab.kermit.Logger
import com.nuvio.app.core.network.SupabaseProvider
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

const val SYNC_PIN_MIN_LENGTH = 4
const val SYNC_PIN_MAX_LENGTH = 8

/** Why a sync-code call produced no result; the UI maps each to its own localised sentence. */
enum class SyncCodeError {
    /** Sync codes belong to a Nuvio account; guests and signed-out sessions cannot use them. */
    NOT_SIGNED_IN,

    /** The PIN is not 4-8 characters (checked before any request). */
    INVALID_PIN,

    /** The backend answered with an error or an empty result (offline, wrong PIN, expired code). */
    FAILED,
}

@Serializable
internal data class SyncCodeRow(val code: String = "")

@Serializable
internal data class ClaimSyncRow(
    @SerialName("result_owner_id") val ownerId: String? = null,
    val success: Boolean = false,
    val message: String = "",
)

@Serializable
internal data class LinkedDeviceRow(
    @SerialName("owner_id") val ownerId: String = "",
    @SerialName("device_user_id") val deviceUserId: String = "",
    @SerialName("device_name") val deviceName: String? = null,
    @SerialName("linked_at") val linkedAt: String? = null,
)

/** `code` is set on success, `error` otherwise. */
data class SyncCodeResponse(val code: String?, val error: SyncCodeError?)

/** `message` is the backend's own explanation of a refused claim (it may be empty). */
data class SyncClaimResponse(val success: Boolean, val message: String, val error: SyncCodeError?)

data class LinkedDevice(val deviceUserId: String, val deviceName: String?, val linkedAt: String?)

data class LinkedDevicesResponse(val devices: List<LinkedDevice>, val error: SyncCodeError?)

data class SyncCodeActionResponse(val success: Boolean, val error: SyncCodeError?)

internal fun isValidSyncPin(pin: String): Boolean = pin.trim().length in SYNC_PIN_MIN_LENGTH..SYNC_PIN_MAX_LENGTH

/** Sync codes are shown as `XXXX-XXXX-...` groups; the backend compares them upper-cased. */
internal fun normalizeSyncCode(raw: String): String = raw.trim().uppercase()

internal fun buildSyncPinParams(pin: String): JsonObject = buildJsonObject { put("p_pin", pin.trim()) }

internal fun buildClaimSyncCodeParams(code: String, pin: String, deviceName: String?): JsonObject = buildJsonObject {
    put("p_code", normalizeSyncCode(code))
    put("p_pin", pin.trim())
    if (!deviceName.isNullOrBlank()) put("p_device_name", deviceName)
}

internal fun buildUnlinkDeviceParams(deviceUserId: String): JsonObject =
    buildJsonObject { put("p_device_user_id", deviceUserId) }

/**
 * Account-less linking ("sync code"), the protocol the Android TV app uses against the Nuvio
 * backend: a signed-in account generates a code protected by a 4-8 character PIN, another device
 * claims it with code + PIN, and the owner lists / unlinks its linked devices.
 *
 * Only a real (non-anonymous) account may generate, read or manage codes. The claim side is
 * implemented for completeness but the tvOS UI does not offer it: linking this Apple TV to another
 * owner would need every sync read to follow `get_sync_owner`, which this client does not do.
 *
 * Every call returns a plain data object instead of throwing so it crosses to Swift cleanly.
 */
object SyncCodeRepository {
    private val log = Logger.withTag("SyncCodeRepository")

    private fun signedInUserId(): String? {
        val state = AuthRepository.state.value as? AuthState.Authenticated ?: return null
        return state.userId.takeUnless { state.isAnonymous }
    }

    suspend fun generateCode(pin: String): SyncCodeResponse {
        if (signedInUserId() == null) return SyncCodeResponse(null, SyncCodeError.NOT_SIGNED_IN)
        if (!isValidSyncPin(pin)) return SyncCodeResponse(null, SyncCodeError.INVALID_PIN)
        return fetchCode("generate_sync_code", pin)
    }

    suspend fun existingCode(pin: String): SyncCodeResponse {
        if (signedInUserId() == null) return SyncCodeResponse(null, SyncCodeError.NOT_SIGNED_IN)
        if (!isValidSyncPin(pin)) return SyncCodeResponse(null, SyncCodeError.INVALID_PIN)
        return fetchCode("get_sync_code", pin)
    }

    suspend fun claimCode(code: String, pin: String, deviceName: String?): SyncClaimResponse {
        if (signedInUserId() == null) return SyncClaimResponse(false, "", SyncCodeError.NOT_SIGNED_IN)
        if (code.isBlank() || !isValidSyncPin(pin)) return SyncClaimResponse(false, "", SyncCodeError.INVALID_PIN)
        return try {
            val row = SupabaseProvider.client.postgrest
                .rpc("claim_sync_code", buildClaimSyncCodeParams(code, pin, deviceName))
                .decodeList<ClaimSyncRow>()
                .firstOrNull()
                ?: return SyncClaimResponse(false, "", SyncCodeError.FAILED)
            SyncClaimResponse(row.success, row.message, null)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w(error) { "claim_sync_code failed" }
            SyncClaimResponse(false, "", SyncCodeError.FAILED)
        }
    }

    suspend fun linkedDevices(): LinkedDevicesResponse {
        val userId = signedInUserId() ?: return LinkedDevicesResponse(emptyList(), SyncCodeError.NOT_SIGNED_IN)
        return try {
            val rows = SupabaseProvider.client.postgrest.from("linked_devices")
                .select { filter { eq("owner_id", userId) } }
                .decodeList<LinkedDeviceRow>()
            LinkedDevicesResponse(
                devices = rows.filter { it.deviceUserId.isNotBlank() }
                    .map { LinkedDevice(it.deviceUserId, it.deviceName?.takeIf(String::isNotBlank), it.linkedAt) },
                error = null,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w(error) { "Reading linked_devices failed" }
            LinkedDevicesResponse(emptyList(), SyncCodeError.FAILED)
        }
    }

    suspend fun unlinkDevice(deviceUserId: String): SyncCodeActionResponse {
        if (signedInUserId() == null) return SyncCodeActionResponse(false, SyncCodeError.NOT_SIGNED_IN)
        return try {
            SupabaseProvider.client.postgrest.rpc("unlink_device", buildUnlinkDeviceParams(deviceUserId))
            SyncCodeActionResponse(true, null)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            log.w(error) { "unlink_device failed" }
            SyncCodeActionResponse(false, SyncCodeError.FAILED)
        }
    }

    private suspend fun fetchCode(rpc: String, pin: String): SyncCodeResponse = try {
        val code = SupabaseProvider.client.postgrest
            .rpc(rpc, buildSyncPinParams(pin))
            .decodeList<SyncCodeRow>()
            .firstOrNull()
            ?.code
            ?.takeIf(String::isNotBlank)
        if (code != null) SyncCodeResponse(code, null) else SyncCodeResponse(null, SyncCodeError.FAILED)
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        log.w(error) { "$rpc failed" }
        SyncCodeResponse(null, SyncCodeError.FAILED)
    }
}
