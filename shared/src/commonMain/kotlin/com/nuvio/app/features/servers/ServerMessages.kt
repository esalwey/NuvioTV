package com.nuvio.app.features.servers

// Fork: upstream resolves these through Compose Resources. :shared has no resource bundle, so the
// English text lives here and the tvOS UI maps `ServerFailure` (by name) to its own localized
// strings. These are only the fallback copy for text that crosses the bridge as a plain String
// (a stream group's error line, a toast).

fun Throwable.serverFailure(): ServerFailure = (this as? ServerException)?.failure ?: ServerFailure.FAILED

internal fun Throwable.serverMessage(): String? = (this as? ServerException)?.failure?.message()

internal fun Throwable.serverPlaybackMessage(): String =
    serverFailure().takeUnless { it == ServerFailure.FAILED }?.message() ?: SERVER_PLAYBACK_FAILED

fun ServerFailure.message(): String = when (this) {
    ServerFailure.AUTH_REQUIRED -> "Sign in to this server again in Settings."
    ServerFailure.UNREACHABLE -> "The server is unavailable."
    ServerFailure.NOT_FOUND -> "This item is no longer available on the server."
    ServerFailure.INCOMPLETE -> "Still checking this server's library. Try again in a moment."
    ServerFailure.FORBIDDEN -> "This user does not have access."
    ServerFailure.UNSUPPORTED -> "The server doesn't support this item."
    ServerFailure.FAILED -> "Could not connect to the server."
}

fun ServerPlayMethod.label(): String = when (this) {
    ServerPlayMethod.DIRECT_PLAY -> "Direct play"
    ServerPlayMethod.DIRECT_STREAM -> "Direct stream"
    ServerPlayMethod.TRANSCODE -> "Transcoding"
}

internal fun readableTranscodeReason(reason: String): String =
    reason.replace(WORD_BOUNDARY, " ").lowercase().replaceFirstChar(Char::uppercase)

internal const val SERVER_PLAYBACK_FAILED = "Could not start playback from the server."
internal const val SERVER_WATCHED_FAILED = "Could not update watched state on the server."
internal const val SERVER_AUDIO_SWITCH_FAILED = "Couldn't switch the audio track."
internal const val SERVER_SUBTITLE_SWITCH_FAILED = "Couldn't switch the subtitle track."

private val WORD_BOUNDARY = Regex("(?<=[a-z])(?=[A-Z])")
