package com.nuvio.app.features.player

import platform.Foundation.NSLog
import platform.Foundation.NSURL
import platform.Foundation.NSUserDefaults
import platform.UIKit.UIApplication

private data class IosExternalPlayerSpec(
    val id: String,
    val name: String,
    val scheme: String,
    val buildUrl: (ExternalPlayerPlaybackRequest) -> String,
)

private val iosExternalPlayerSpecs = listOf(
    IosExternalPlayerSpec(
        id = "infuse",
        name = "Infuse",
        scheme = "infuse",
        buildUrl = { request ->
            buildString {
                append("infuse://x-callback-url/play?url=")
                append(request.sourceUrl.urlQueryEncode())
                // Upstream 99ced26a4: start where the built-in player would resume (seconds)…
                append("&position=")
                append(request.resumePositionMs.coerceAtLeast(0L) / 1000L)
                append("&filename=")
                append(request.buildPlayerTitle(includeEpisodeTitle = true).urlQueryEncode())
                request.subtitles?.forEach { subtitle ->
                    append("&sub=")
                    append(subtitle.url.urlQueryEncode())
                }
                // …and report where playback stopped: Infuse opens x-success with `position` and
                // `lastPlayedUrl` when the viewer leaves it (x-error when it can't play the file).
                request.callbackSuccessUrl?.takeIf { it.isNotBlank() }?.let { callback ->
                    append("&x-success=")
                    append(callback.urlQueryEncode())
                }
                request.callbackErrorUrl?.takeIf { it.isNotBlank() }?.let { callback ->
                    append("&x-error=")
                    append(callback.urlQueryEncode())
                }
            }
        },
    ),
    IosExternalPlayerSpec(
        id = "vlc",
        name = "VLC",
        scheme = "vlc-x-callback",
        buildUrl = { request ->
            buildString {
                append("vlc-x-callback://x-callback-url/stream?url=")
                append(request.sourceUrl.urlQueryEncode())
                request.subtitles?.firstOrNull()?.let { subtitle ->
                    append("&sub=")
                    append(subtitle.url.urlQueryEncode())
                }
            }
        },
    ),
    IosExternalPlayerSpec(
        id = "outplayer",
        name = "Outplayer",
        scheme = "outplayer",
        buildUrl = { request ->
            buildString {
                append("outplayer://x-callback-url/play?url=")
                append(request.sourceUrl.urlQueryEncode())
                append("&filename=")
                append(request.buildPlayerTitle(includeEpisodeTitle = true).urlQueryEncode())
            }
        },
    ),
    IosExternalPlayerSpec(
        id = "vidhub",
        name = "VidHub",
        scheme = "open-vidhub",
        // FEAT-21 (beta.12): modernized from the legacy `/open` method to `/play` — the only
        // method VidHub's integration docs list as supporting Apple TV (they also cover Mac,
        // iPhone/iPad, Android; /open is Apple-legacy-only). /play adds `filename`, `position`
        // (seconds), and `sub`, which /open lacked for the title, so the handoff now carries
        // the same metadata Infuse gets.
        //
        // 2026-08-12 device pass: on the tvOS VidHub build, /play opened the app but never
        // started playback (post-onboarding retest included), despite the docs' Apple TV
        // support table. `debug.vidhubMethod` bisects the handoff live from launch args
        // without a rebuild: "open" = legacy method, "minimal" = /play with url only,
        // "bare" = undocumented vidhub://play (seen in bobsupra/NuvioTVOS, unverified there),
        // anything else/unset = the full documented /play.
        buildUrl = { request ->
            when (NSUserDefaults.standardUserDefaults.stringForKey("debug.vidhubMethod")) {
                // url-only, replicating the pre-beta.12 shipped builder byte-for-byte so the
                // bisect tests the legacy method exactly as it used to go out. (VidHub's docs
                // do list `sub` on /open, but a diagnostic branch adds nothing new.)
                "open" -> "open-vidhub://x-callback-url/open?url=" + request.sourceUrl.urlQueryEncode()
                "minimal" -> buildString {
                    append("open-vidhub://x-callback-url/play?url=")
                    append(request.sourceUrl.urlQueryEncode())
                }
                // Bare scheme, no x-callback-url host. Launch still gates on the open-vidhub
                // probe (spec.scheme), so this fires even if vidhub:// isn't registered —
                // the ContentView probe logs canOpenURL(vidhub://) to interpret a no-op.
                "bare" -> "vidhub://play?url=" + request.sourceUrl.urlQueryEncode()
                else -> buildString {
                    append("open-vidhub://x-callback-url/play?url=")
                    append(request.sourceUrl.urlQueryEncode())
                    append("&filename=")
                    append(request.buildPlayerTitle(includeEpisodeTitle = true).urlQueryEncode())
                    if (request.resumePositionMs > 0) {
                        append("&position=")
                        append(request.resumePositionMs / 1000)
                    }
                    request.subtitles?.firstOrNull()?.let { subtitle ->
                        append("&sub=")
                        append(subtitle.url.urlQueryEncode())
                    }
                }
            }
        },
    ),
)

actual object ExternalPlayerPlatform {
    actual fun defaultPlayerId(): String? = null

    actual fun availablePlayers(): List<ExternalPlayerApp> =
        iosExternalPlayerSpecs
            .filter { spec -> UIApplication.sharedApplication.canOpenURL(spec.schemeProbeUrl()) }
            .map { spec -> ExternalPlayerApp(spec.id, spec.name) }

    actual fun open(
        request: ExternalPlayerPlaybackRequest,
        playerId: String?,
    ): ExternalPlayerOpenResult {
        if (playerId.isNullOrBlank()) return ExternalPlayerOpenResult.NotConfigured
        val spec = iosExternalPlayerSpecs.firstOrNull { it.id == playerId }
            ?: return ExternalPlayerOpenResult.NotConfigured
        if (!UIApplication.sharedApplication.canOpenURL(spec.schemeProbeUrl())) {
            return ExternalPlayerOpenResult.NoPlayerAvailable
        }
        val urlString = spec.buildUrl(request)
        // Knob-gated, console-only: the string embeds tokenized debrid URLs, so it must never
        // log unconditionally (the Sentry breadcrumb scrub in d5b29180 exists for this reason).
        if (NSUserDefaults.standardUserDefaults.boolForKey("debug.extPlayerProbe")) {
            // Single-arg NSLog with % escaped: K/N strings do not bridge through NSLog's C
            // varargs — NSLog("%@", kotlinString) SIGSEGVs (field-proven 2026-08-01).
            val line = "[ExtPlayerProbe] open player=" + spec.id + " url=" + urlString
            NSLog(line.replace("%", "%%"))
        }
        val url = NSURL.URLWithString(urlString)
            ?: return ExternalPlayerOpenResult.Failed
        UIApplication.sharedApplication.openURL(
            url = url,
            options = emptyMap<Any?, Any>(),
            completionHandler = null,
        )
        return ExternalPlayerOpenResult.Opened
    }

    actual fun buildIntent(
        request: ExternalPlayerPlaybackRequest,
        playerId: String?,
    ): ExternalPlayerIntentResult {
        // iOS doesn't use Android intents; this returns the URL as the "intent" payload
        if (playerId.isNullOrBlank()) return ExternalPlayerIntentResult.NotConfigured
        val spec = iosExternalPlayerSpecs.firstOrNull { it.id == playerId }
            ?: return ExternalPlayerIntentResult.NotConfigured
        if (!UIApplication.sharedApplication.canOpenURL(spec.schemeProbeUrl())) {
            return ExternalPlayerIntentResult.Failed
        }
        val url = NSURL.URLWithString(spec.buildUrl(request))
            ?: return ExternalPlayerIntentResult.Failed
        return ExternalPlayerIntentResult.Success(url)
    }
}

private fun IosExternalPlayerSpec.schemeProbeUrl(): NSURL =
    NSURL.URLWithString("$scheme://") ?: NSURL.URLWithString("nuvio://")!!

private fun String.urlQueryEncode(): String {
    val hex = "0123456789ABCDEF"
    return buildString {
        encodeToByteArray().forEach { byte ->
            val value = byte.toInt() and 0xFF
            val char = value.toChar()
            val safe = char in 'A'..'Z' ||
                char in 'a'..'z' ||
                char in '0'..'9' ||
                char == '-' ||
                char == '_' ||
                char == '.' ||
                char == '~'
            if (safe) {
                append(char)
            } else {
                append('%')
                append(hex[value ushr 4])
                append(hex[value and 0x0F])
            }
        }
    }
}
