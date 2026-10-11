package com.nuvio.app.features.servers

import com.nuvio.app.features.streams.StreamItem
import kotlinx.coroutines.CancellationException

/**
 * What a media-server file became once the player asked for it: a playable [stream] (URL, request
 * headers and the server's own subtitle files filled in) or the reason it could not be prepared.
 * [resumePositionMs] is a position the server holds that is newer than the one saved here, or null.
 */
class ServerPrepareResult(
    val stream: StreamItem?,
    val failure: ServerFailure?,
    val resumePositionMs: Long?,
)

/**
 * Swift-facing helpers over [ServerPlayback]: failures come back as values instead of exceptions
 * (a thrown `ServerException` reaches Swift as an opaque `NSError`), so the stream picker and the
 * in-player source switch can say what went wrong in the app's own words.
 */
object ServerPlaybackBridge {
    /**
     * Resolves a server file to a playable stream and asks the server for a newer resume point.
     * [savedAtEpochMs] is when the position saved on this device was last updated (0 or less when
     * there is none), so the server's position only wins when it is the more recent of the two.
     * A stream that is not a server file is returned as it is.
     */
    suspend fun prepare(stream: StreamItem, savedAtEpochMs: Long): ServerPrepareResult {
        if (stream.serverTarget == null) return ServerPrepareResult(stream, null, null)
        return try {
            val prepared = ServerPlayback.prepare(stream)
            val resume = ServerPlayback.newerResumePositionMs(
                url = prepared.playableDirectUrl,
                savedAtEpochMs = savedAtEpochMs.takeIf { it > 0L },
            )
            ServerPrepareResult(prepared, null, resume)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            ServerPrepareResult(null, error.serverFailure(), null)
        }
    }

    /** "DIRECT_PLAY", "DIRECT_STREAM" or "TRANSCODE" for the session playing [url]; null when [url] is not a server file. */
    fun playMethod(url: String?): String? = ServerPlayback.session(url)?.playMethod?.name

    /** Why the server transcodes [url], one readable phrase each ("Audio codec not supported"); empty for a direct play. */
    fun transcodeReasons(url: String?): List<String> =
        ServerPlayback.session(url)?.transcodeReasons.orEmpty().map(::readableTranscodeReason)

    /** True when the audio track of [url] can be switched: a transcode of a file with several tracks. */
    fun canSwitchAudio(url: String?): Boolean = ServerPlayback.audioTracks(url).isNotEmpty()

    /** True when the session for [url] plays the original file, so a failure can still fall back to a transcode. */
    fun canFallBack(url: String?): Boolean =
        ServerPlayback.session(url)?.playMethod == ServerPlayMethod.DIRECT_PLAY
}
