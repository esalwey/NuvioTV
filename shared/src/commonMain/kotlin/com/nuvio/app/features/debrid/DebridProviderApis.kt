package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamClientResolve
import com.nuvio.app.features.streams.StreamItem
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.Serializable

interface DebridProviderApi {
    val provider: DebridProvider

    suspend fun validateApiKey(apiKey: String): Boolean

    suspend fun startDeviceAuthorization(appName: String): DebridDeviceAuthorization? = null

    suspend fun redeemDeviceAuthorization(deviceCode: String): DebridDeviceAuthorizationTokenResult =
        DebridDeviceAuthorizationTokenResult.Unsupported

    suspend fun resolveClientStream(
        stream: StreamItem,
        apiKey: String,
        season: Int?,
        episode: Int?,
    ): DirectDebridResolveResult
}

object DebridProviderApis {
    private val registered = listOf(
        TorboxDebridProviderApi(),
        PremiumizeDebridProviderApi(),
        RealDebridProviderApi(),
        AllDebridDebridProviderApi(),
    )

    fun apiFor(providerId: String?): DebridProviderApi? {
        val normalized = DebridProviders.byId(providerId)?.id ?: return null
        return registered.firstOrNull { it.provider.id == normalized }
    }

    // Swift-facing twins for the tvOS debrid pane (same treatment as TmdbMetadataService's
    // `*Checked` functions). A suspend function exported to Swift without `@Throws` treats every
    // non-cancellation exception as unhandled and ABORTS the process, and every provider call
    // below throws on a transport failure (offline, DNS, TLS, timeout — httpRequestRaw does not
    // catch them), or, for Premiumize device sign-in, on a missing client id. `@Throws(Throwable)`
    // hands those to the Swift completion as an NSError instead. Kotlin callers keep using the
    // [DebridProviderApi] methods directly.

    /** True/false from the provider; throws (→ NSError in Swift) when it could not be asked. */
    @Throws(Throwable::class)
    suspend fun validateApiKeyChecked(providerId: String, apiKey: String): Boolean {
        val normalized = apiKey.trim()
        if (normalized.isBlank()) return false
        return apiFor(providerId)?.validateApiKey(normalized) == true
    }

    @Throws(Throwable::class)
    suspend fun startDeviceAuthorizationChecked(providerId: String, appName: String): DebridDeviceAuthorization? =
        apiFor(providerId)?.startDeviceAuthorization(appName)

    @Throws(Throwable::class)
    suspend fun redeemDeviceAuthorizationChecked(providerId: String, deviceCode: String): DebridDeviceAuthorizationTokenResult =
        apiFor(providerId)?.redeemDeviceAuthorization(deviceCode) ?: DebridDeviceAuthorizationTokenResult.Unsupported
}

@Serializable
data class DebridDeviceAuthorization(
    val providerId: String,
    val deviceCode: String,
    val userCode: String,
    val verificationUrl: String,
    val friendlyVerificationUrl: String,
    val intervalSeconds: Int,
    val expiresAt: String?,
)

sealed interface DebridDeviceAuthorizationTokenResult {
    data class Authorized(val accessToken: String) : DebridDeviceAuthorizationTokenResult
    data object Pending : DebridDeviceAuthorizationTokenResult
    data object Expired : DebridDeviceAuthorizationTokenResult
    data object Unsupported : DebridDeviceAuthorizationTokenResult
    data class Failed(val message: String?) : DebridDeviceAuthorizationTokenResult
}

private class TorboxDebridProviderApi(
    private val fileSelector: TorboxFileSelector = TorboxFileSelector(),
) : DebridProviderApi {
    override val provider: DebridProvider = DebridProviders.Torbox

    override suspend fun validateApiKey(apiKey: String): Boolean =
        TorboxApiClient.validateApiKey(apiKey)

    override suspend fun startDeviceAuthorization(appName: String): DebridDeviceAuthorization? {
        val response = TorboxApiClient.startDeviceAuthorization(appName = appName)
        val data = response.body?.takeIf { response.isSuccessful && it.success != false }?.data
            ?: return null
        val deviceCode = data.deviceCode?.takeIf { it.isNotBlank() } ?: return null
        val userCode = data.code?.takeIf { it.isNotBlank() } ?: return null
        val verificationUrl = data.verificationUrl?.takeIf { it.isNotBlank() } ?: return null
        return DebridDeviceAuthorization(
            providerId = provider.id,
            deviceCode = deviceCode,
            userCode = userCode,
            verificationUrl = verificationUrl,
            friendlyVerificationUrl = data.friendlyVerificationUrl?.takeIf { it.isNotBlank() }
                ?: verificationUrl,
            intervalSeconds = data.interval?.coerceAtLeast(1) ?: 5,
            expiresAt = data.expiresAt?.takeIf { it.isNotBlank() },
        )
    }

    override suspend fun redeemDeviceAuthorization(deviceCode: String): DebridDeviceAuthorizationTokenResult {
        val normalized = deviceCode.trim()
        if (normalized.isBlank()) return DebridDeviceAuthorizationTokenResult.Failed(null)
        val response = TorboxApiClient.redeemDeviceAuthorization(deviceCode = normalized)
        return torboxDeviceAuthorizationTokenResult(response)
    }

    override suspend fun resolveClientStream(
        stream: StreamItem,
        apiKey: String,
        season: Int?,
        episode: Int?,
    ): DirectDebridResolveResult {
        val resolve = stream.clientResolve ?: return DirectDebridResolveResult.Error()
        val magnet = resolve.magnetUri?.takeIf { it.isNotBlank() }
            ?: buildMagnetUri(resolve)
            ?: return DirectDebridResolveResult.Stale

        return try {
            val create = TorboxApiClient.createTorrent(apiKey = apiKey, magnet = magnet)
            DebridCredentialHealth.recordHttpStatus(provider.id, create.status)
            val torrentId = create.body?.takeIf { it.success != false }?.data?.resolvedTorrentId()
                ?: return create.toFailureForCreate()

            val torrent = TorboxApiClient.getTorrent(apiKey = apiKey, id = torrentId)
            if (!torrent.isSuccessful) {
                return torboxStepFailure("fetching the file list", torrent.status, torrent.body)
            }
            val files = torrent.body?.data?.files.orEmpty()
            val file = fileSelector.selectFile(files, resolve, season, episode)
                ?: return torboxStepFailure("finding a matching video file (of ${files.size})")
            val fileId = file.id
                ?: return torboxStepFailure("finding the selected file's id")

            val link = TorboxApiClient.requestDownloadLink(
                apiKey = apiKey,
                torrentId = torrentId,
                fileId = fileId,
            )
            if (!link.isSuccessful) {
                return torboxStepFailure("requesting the download link", link.status, link.body)
            }
            val url = link.body?.data?.takeIf { it.isNotBlank() }
                ?: return torboxStepFailure("reading the download link (empty response)")

            DirectDebridResolveResult.Success(
                url = url,
                filename = file.displayName().takeIf { it.isNotBlank() },
                videoSize = file.size,
            )
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            torboxStepFailure("network request", exception = error.message ?: error::class.simpleName)
        }
    }
}

class PremiumizeDebridProviderApi(
    private val fileSelector: PremiumizeDirectDownloadFileSelector = PremiumizeDirectDownloadFileSelector(),
    private val clientIdProvider: () -> String = { PremiumizeConfig.CLIENT_ID },
) : DebridProviderApi {
    override val provider: DebridProvider = DebridProviders.Premiumize

    override suspend fun validateApiKey(apiKey: String): Boolean =
        PremiumizeApiClient.validateApiKey(apiKey)

    override suspend fun startDeviceAuthorization(appName: String): DebridDeviceAuthorization? {
        val clientId = premiumizeClientIdOrThrow()
        val response = PremiumizeApiClient.startDeviceAuthorization(clientId = clientId)
        return premiumizeDeviceAuthorizationFromResponse(response, provider.id)
    }

    override suspend fun redeemDeviceAuthorization(deviceCode: String): DebridDeviceAuthorizationTokenResult {
        val clientId = premiumizeClientIdOrThrow()
        val normalized = deviceCode.trim()
        if (normalized.isBlank()) return DebridDeviceAuthorizationTokenResult.Failed(null)
        val response = PremiumizeApiClient.redeemDeviceAuthorization(
            clientId = clientId,
            deviceCode = normalized,
        )
        return premiumizeDeviceAuthorizationTokenResult(response)
    }

    override suspend fun resolveClientStream(
        stream: StreamItem,
        apiKey: String,
        season: Int?,
        episode: Int?,
    ): DirectDebridResolveResult {
        val resolve = stream.clientResolve ?: return DirectDebridResolveResult.Error()
        val source = resolve.magnetUri?.takeIf { it.isNotBlank() }
            ?: buildMagnetUri(resolve)
            ?: stream.playableDirectUrl?.takeIf { it.isNotBlank() }
            ?: return DirectDebridResolveResult.Stale
        return resolvePremiumizeDirectDownload(
            apiKey = apiKey,
            source = source,
            resolve = resolve,
            season = season,
            episode = episode,
            fallbackFilename = stream.behaviorHints.filename,
            fallbackSize = stream.behaviorHints.videoSize,
            fileSelector = fileSelector,
        )
    }

    private fun premiumizeClientIdOrThrow(): String =
        clientIdProvider().trim().takeIf { it.isNotBlank() }
            ?: throw IllegalStateException("Premiumize sign-in is missing PREMIUMIZE_CLIENT_ID.")
}

private class RealDebridProviderApi(
    private val fileSelector: RealDebridFileSelector = RealDebridFileSelector(),
) : DebridProviderApi {
    override val provider: DebridProvider = DebridProviders.RealDebrid

    override suspend fun validateApiKey(apiKey: String): Boolean =
        RealDebridApiClient.validateApiKey(apiKey)

    override suspend fun resolveClientStream(
        stream: StreamItem,
        apiKey: String,
        season: Int?,
        episode: Int?,
    ): DirectDebridResolveResult {
        val resolve = stream.clientResolve ?: return DirectDebridResolveResult.Error()
        val magnet = resolve.magnetUri?.takeIf { it.isNotBlank() }
            ?: buildMagnetUri(resolve)
            ?: return DirectDebridResolveResult.Stale

        return try {
            val add = RealDebridApiClient.addMagnet(apiKey, magnet)
            val torrentId = add.body?.id?.takeIf { add.isSuccessful && it.isNotBlank() }
                ?: return add.toFailureForAdd()
            var resolved = false
            try {
                val infoBefore = RealDebridApiClient.getTorrentInfo(apiKey, torrentId)
                if (!infoBefore.isSuccessful) {
                    return DirectDebridResolveResult.Stale
                }
                val filesBefore = infoBefore.body?.files.orEmpty()
                val file = fileSelector.selectFile(
                    files = filesBefore,
                    resolve = resolve,
                    season = season,
                    episode = episode,
                ) ?: return DirectDebridResolveResult.Stale
                val fileId = file.id ?: return DirectDebridResolveResult.Stale
                val select = RealDebridApiClient.selectFiles(apiKey, torrentId, fileId.toString())
                if (!select.isSuccessful && select.status != 202) {
                    return DirectDebridResolveResult.Stale
                }

                val infoAfter = RealDebridApiClient.getTorrentInfo(apiKey, torrentId)
                if (!infoAfter.isSuccessful) {
                    return DirectDebridResolveResult.Stale
                }
                val link = infoAfter.body?.firstDownloadLink()
                    ?: return DirectDebridResolveResult.Stale
                val unrestrict = RealDebridApiClient.unrestrictLink(apiKey, link)
                if (!unrestrict.isSuccessful) {
                    return DirectDebridResolveResult.Stale
                }
                val url = unrestrict.body?.download?.takeIf { it.isNotBlank() }
                    ?: return DirectDebridResolveResult.Stale
                resolved = true
                DirectDebridResolveResult.Success(
                    url = url,
                    filename = unrestrict.body.filename?.takeIf { it.isNotBlank() }
                        ?: file.displayName().takeIf { it.isNotBlank() },
                    videoSize = unrestrict.body.filesize ?: file.bytes,
                )
            } finally {
                if (!resolved) {
                    runCatching { RealDebridApiClient.deleteTorrent(apiKey, torrentId) }
                }
            }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            DirectDebridResolveResult.Error()
        }
    }
}

private class AllDebridDebridProviderApi(
    private val fileSelector: AllDebridFileSelector = AllDebridFileSelector(),
) : DebridProviderApi {
    override val provider: DebridProvider = DebridProviders.AllDebrid

    override suspend fun validateApiKey(apiKey: String): Boolean =
        AllDebridApiClient.validateApiKey(apiKey)

    override suspend fun startDeviceAuthorization(appName: String): DebridDeviceAuthorization? {
        val response = AllDebridApiClient.getPin()
        val data = response.body
            ?.takeIf { response.isSuccessful && it.isSuccess }
            ?.data
            ?: return null
        val pin = data.pin?.takeIf { it.isNotBlank() } ?: return null
        val check = data.check?.takeIf { it.isNotBlank() } ?: return null
        val verificationUrl = data.userUrl?.takeIf { it.isNotBlank() }
            ?: data.baseUrl?.takeIf { it.isNotBlank() }
            ?: return null
        return DebridDeviceAuthorization(
            providerId = provider.id,
            // The deviceCode passed back to redeemDeviceAuthorization is opaque to callers — it
            // encodes both the pin and its check token, since AllDebrid's pin/check needs both.
            deviceCode = encodeAllDebridDeviceCode(pin = pin, check = check),
            userCode = pin,
            verificationUrl = verificationUrl,
            friendlyVerificationUrl = verificationUrl,
            intervalSeconds = 5,
            expiresAt = data.expiresIn?.takeIf { it > 0 }?.let { "${it}s" },
        )
    }

    override suspend fun redeemDeviceAuthorization(deviceCode: String): DebridDeviceAuthorizationTokenResult {
        val (pin, check) = decodeAllDebridDeviceCode(deviceCode)
            ?: return DebridDeviceAuthorizationTokenResult.Failed(null)
        val response = AllDebridApiClient.checkPin(pin = pin, check = check)
        return allDebridDeviceAuthorizationTokenResult(response)
    }

    override suspend fun resolveClientStream(
        stream: StreamItem,
        apiKey: String,
        season: Int?,
        episode: Int?,
    ): DirectDebridResolveResult {
        val resolve = stream.clientResolve ?: return DirectDebridResolveResult.Error()
        val magnet = resolve.magnetUri?.takeIf { it.isNotBlank() }
            ?: buildMagnetUri(resolve)
            ?: return DirectDebridResolveResult.Stale
        return resolveAllDebridMagnet(
            apiKey = apiKey,
            magnet = magnet,
            resolve = resolve,
            season = season,
            episode = episode,
            fallbackFilename = stream.behaviorHints.filename,
            fallbackSize = stream.behaviorHints.videoSize,
            fileSelector = fileSelector,
        )
    }
}

private const val ALLDEBRID_DEVICE_CODE_DELIMITER = "|"

private fun encodeAllDebridDeviceCode(pin: String, check: String): String =
    "$pin$ALLDEBRID_DEVICE_CODE_DELIMITER$check"

private fun decodeAllDebridDeviceCode(deviceCode: String): Pair<String, String>? {
    val parts = deviceCode.trim().split(ALLDEBRID_DEVICE_CODE_DELIMITER, limit = 2)
    if (parts.size != 2) return null
    val pin = parts[0].trim().takeIf { it.isNotBlank() } ?: return null
    val check = parts[1].trim().takeIf { it.isNotBlank() } ?: return null
    return pin to check
}

private fun buildMagnetUri(resolve: StreamClientResolve): String? {
    val hash = resolve.infoHash?.takeIf { it.isNotBlank() } ?: return null
    return buildString {
        append("magnet:?xt=urn:btih:")
        append(hash)
        resolve.sources
            .mapNotNull { it.toTrackerUrlOrNull() }
            .distinct()
            .forEach { source ->
                append("&tr=")
                append(encodePathSegment(source))
            }
    }
}

internal fun premiumizeDeviceAuthorizationFromResponse(
    response: DebridApiResponse<PremiumizeDeviceAuthorizationDto>,
    providerId: String,
): DebridDeviceAuthorization? {
    val data = response.body?.takeIf { response.isSuccessful } ?: return null
    val deviceCode = data.deviceCode?.takeIf { it.isNotBlank() } ?: return null
    val userCode = data.userCode?.takeIf { it.isNotBlank() } ?: return null
    val verificationUrl = data.verificationUri?.takeIf { it.isNotBlank() } ?: return null
    return DebridDeviceAuthorization(
        providerId = providerId,
        deviceCode = deviceCode,
        userCode = userCode,
        verificationUrl = verificationUrl,
        friendlyVerificationUrl = data.verificationUriComplete?.takeIf { it.isNotBlank() }
            ?: verificationUrl,
        intervalSeconds = data.interval?.coerceAtLeast(1) ?: 5,
        expiresAt = data.expiresIn?.takeIf { it > 0 }?.let { "${it}s" },
    )
}

fun torboxDeviceAuthorizationTokenResult(
    response: DebridApiResponse<TorboxEnvelopeDto<TorboxDeviceTokenDto>>,
): DebridDeviceAuthorizationTokenResult {
    val envelope = response.body
    val accessToken = envelope
        ?.takeIf { response.isSuccessful && it.success != false }
        ?.data
        ?.accessToken
        ?.takeIf { it.isNotBlank() }
    if (accessToken != null) {
        return DebridDeviceAuthorizationTokenResult.Authorized(accessToken)
    }
    val message = listOfNotNull(envelope?.error, envelope?.detail, response.rawBody)
        .joinToString(" ")
        .lowercase()
    return when {
        message.contains("pending") ||
            message.contains("not authorized") ||
            message.contains("not been used") ||
            message.contains("not used yet") ||
            message.contains("scan the code") ->
            DebridDeviceAuthorizationTokenResult.Pending
        message.contains("expired") ->
            DebridDeviceAuthorizationTokenResult.Expired
        response.status == 404 || response.status == 409 || response.status == 425 ->
            DebridDeviceAuthorizationTokenResult.Pending
        response.status == 410 ->
            DebridDeviceAuthorizationTokenResult.Expired
        else ->
            DebridDeviceAuthorizationTokenResult.Failed(envelope?.detail ?: envelope?.error)
    }
}

fun premiumizeDeviceAuthorizationTokenResult(
    response: DebridApiResponse<PremiumizeDeviceTokenDto>,
): DebridDeviceAuthorizationTokenResult {
    val body = response.body
    body?.accessToken?.takeIf { response.isSuccessful && it.isNotBlank() }?.let { accessToken ->
        return DebridDeviceAuthorizationTokenResult.Authorized(accessToken)
    }
    return when (body?.error?.lowercase()) {
        "authorization_pending", "slow_down" -> DebridDeviceAuthorizationTokenResult.Pending
        "invalid_grant", "expired_token" -> DebridDeviceAuthorizationTokenResult.Expired
        "access_denied" -> DebridDeviceAuthorizationTokenResult.Failed(body.errorDescription)
        else -> {
            if (response.status == 400 && body?.error.isNullOrBlank()) {
                DebridDeviceAuthorizationTokenResult.Pending
            } else {
                DebridDeviceAuthorizationTokenResult.Failed(body?.errorDescription ?: body?.error ?: response.rawBody)
            }
        }
    }
}

internal fun allDebridDeviceAuthorizationTokenResult(
    response: DebridApiResponse<AllDebridEnvelopeDto<AllDebridPinCheckDataDto>>,
): DebridDeviceAuthorizationTokenResult {
    val envelope = response.body
    val activatedData = envelope
        ?.takeIf { response.isSuccessful && it.isSuccess }
        ?.data
    val apiKey = activatedData
        ?.takeIf { it.activated == true }
        ?.apikey
        ?.takeIf { it.isNotBlank() }
    if (apiKey != null) {
        return DebridDeviceAuthorizationTokenResult.Authorized(apiKey)
    }
    if (activatedData?.activated == false) {
        return DebridDeviceAuthorizationTokenResult.Pending
    }
    val errorCode = envelope?.error?.code.orEmpty()
    return when {
        errorCode.equals("PIN_EXPIRED", ignoreCase = true) ->
            DebridDeviceAuthorizationTokenResult.Expired
        errorCode.equals("PIN_INVALID", ignoreCase = true) ->
            DebridDeviceAuthorizationTokenResult.Failed(envelope?.error?.message)
        response.status == 404 || response.status == 409 || response.status == 425 ->
            DebridDeviceAuthorizationTokenResult.Pending
        response.status == 410 ->
            DebridDeviceAuthorizationTokenResult.Expired
        else ->
            DebridDeviceAuthorizationTokenResult.Failed(envelope?.error?.message ?: response.rawBody)
    }
}

/**
 * AllDebrid has no bulk cache-check endpoint — `ready` on `magnet/upload` is the only cache
 * signal. This mirrors the shape of both TorBox's resolveClientStream (magnet -> resolve -> link)
 * and the local-torrent-resolve path in DirectDebridResolver.kt, since AllDebrid's ClientResolve
 * and LocalTorrentResolve capabilities both bottom out in the same upload -> files -> link/unlock
 * sequence. If the magnet isn't ready, the just-created magnet is deleted (so it doesn't sit as a
 * queued download on the user's account) and NotCached is returned; magnets are left alone after
 * a successful resolve.
 */
internal suspend fun resolveAllDebridMagnet(
    apiKey: String,
    magnet: String,
    resolve: StreamClientResolve,
    season: Int?,
    episode: Int?,
    fallbackFilename: String? = null,
    fallbackSize: Long? = null,
    fileSelector: AllDebridFileSelector = AllDebridFileSelector(),
): DirectDebridResolveResult {
    val normalizedMagnet = magnet.trim().takeIf { it.isNotBlank() } ?: return DirectDebridResolveResult.Stale
    return try {
        val upload = AllDebridApiClient.uploadMagnet(apiKey = apiKey, magnet = normalizedMagnet)
        if (!upload.isSuccessful || upload.body?.isSuccess != true) {
            return upload.toFailureForUpload()
        }
        val item = upload.body.data?.magnets?.firstOrNull() ?: return DirectDebridResolveResult.Stale
        if (item.error != null) {
            return DirectDebridResolveResult.Stale
        }
        val magnetId = item.id.asAllDebridId() ?: return DirectDebridResolveResult.Stale
        if (item.ready != true) {
            runCatching { AllDebridApiClient.deleteMagnet(apiKey = apiKey, magnetId = magnetId) }
            return DirectDebridResolveResult.NotCached
        }

        val filesResponse = AllDebridApiClient.magnetFiles(apiKey = apiKey, magnetId = magnetId)
        if (!filesResponse.isSuccessful || filesResponse.body?.isSuccess != true) {
            return DirectDebridResolveResult.Stale
        }
        val nodeFiles = filesResponse.body.data?.magnets
            ?.firstOrNull { it.id.asAllDebridId() == magnetId }
            ?.files
            .orEmpty()
        val file = fileSelector.selectFile(nodeFiles.flattenAllDebridFiles(), resolve, season, episode)
            ?: return DirectDebridResolveResult.Stale

        val unlock = AllDebridApiClient.unlockLink(apiKey = apiKey, link = file.link)
        if (!unlock.isSuccessful || unlock.body?.isSuccess != true) {
            return DirectDebridResolveResult.Stale
        }
        val unlockData = unlock.body.data ?: return DirectDebridResolveResult.Stale
        val url = unlockData.link?.takeIf { it.isNotBlank() } ?: return DirectDebridResolveResult.Stale

        DirectDebridResolveResult.Success(
            url = url,
            filename = unlockData.filename?.takeIf { it.isNotBlank() }
                ?: file.displayName().takeIf { it.isNotBlank() }
                ?: fallbackFilename,
            videoSize = unlockData.filesize ?: file.size ?: fallbackSize,
        )
    } catch (error: Exception) {
        if (error is CancellationException) throw error
        DirectDebridResolveResult.Error()
    }
}

private fun DebridApiResponse<AllDebridEnvelopeDto<AllDebridMagnetUploadDataDto>>.toFailureForUpload(): DirectDebridResolveResult =
    when (status) {
        401, 403 -> DirectDebridResolveResult.Error()
        else -> DirectDebridResolveResult.Stale
    }

internal suspend fun resolvePremiumizeDirectDownload(
    apiKey: String,
    source: String,
    resolve: StreamClientResolve,
    season: Int?,
    episode: Int?,
    fallbackFilename: String? = null,
    fallbackSize: Long? = null,
    fileSelector: PremiumizeDirectDownloadFileSelector = PremiumizeDirectDownloadFileSelector(),
): DirectDebridResolveResult {
    val normalizedSource = source.trim().takeIf { it.isNotBlank() } ?: return DirectDebridResolveResult.Stale
    return try {
        val response = PremiumizeApiClient.directDownload(apiKey = apiKey, source = normalizedSource)
        if (!response.isSuccessful) {
            return when (response.status) {
                401, 403 -> DirectDebridResolveResult.Error()
                else -> DirectDebridResolveResult.Stale
            }
        }
        val body = response.body ?: return DirectDebridResolveResult.Stale
        if (body.status.equals("error", ignoreCase = true)) {
            val message = listOfNotNull(body.message, body.code).joinToString(" ").lowercase()
            return if (message.contains("cache") || message.contains("not found")) {
                DirectDebridResolveResult.NotCached
            } else {
                DirectDebridResolveResult.Stale
            }
        }
        val file = fileSelector.selectFile(
            files = body.content.orEmpty(),
            resolve = resolve,
            season = season,
            episode = episode,
        ) ?: return DirectDebridResolveResult.Stale
        val url = file.link?.takeIf { it.isNotBlank() } ?: return DirectDebridResolveResult.Stale
        DirectDebridResolveResult.Success(
            url = url,
            filename = file.displayName().takeIf { it.isNotBlank() } ?: fallbackFilename,
            videoSize = file.size ?: fallbackSize,
        )
    } catch (error: Exception) {
        if (error is CancellationException) throw error
        DirectDebridResolveResult.Error()
    }
}

private fun String.toTrackerUrlOrNull(): String? {
    val value = trim()
    if (value.isBlank() || value.startsWith("dht:", ignoreCase = true)) return null
    return value.removePrefix("tracker:").trim().takeIf { it.isNotBlank() }
}

// BUG-21: keep 409 = NotCached; everything else surfaces TorBox's error code + detail
// (see the twin mapping in DirectDebridResolver.kt).
private fun DebridApiResponse<TorboxEnvelopeDto<TorboxCreateTorrentDataDto>>.toFailureForCreate(): DirectDebridResolveResult =
    when (status) {
        409 -> DirectDebridResolveResult.NotCached
        else -> torboxStepFailure("adding the item", status, body)
    }

private fun DebridApiResponse<RealDebridAddTorrentDto>.toFailureForAdd(): DirectDebridResolveResult =
    when (status) {
        401, 403 -> DirectDebridResolveResult.Error()
        else -> DirectDebridResolveResult.Stale
    }

private fun RealDebridTorrentInfoDto.firstDownloadLink(): String? {
    if (!status.equals("downloaded", ignoreCase = true)) return null
    return links.orEmpty().firstOrNull { it.isNotBlank() }
}
