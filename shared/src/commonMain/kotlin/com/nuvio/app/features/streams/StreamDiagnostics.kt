package com.nuvio.app.features.streams

/**
 * BUG-74: a seam for reporting what a stream fetch actually did, to a surface a sideloading tester
 * can photograph.
 *
 * Everything here already existed as `log.d` inside the stream repositories, and it was useless
 * where it mattered: testers run unsigned sideloads with no console attached, and Kermit's output
 * does not reliably survive to `log show` on tvOS anyway. So the one fact that would have closed
 * BUG-74 on day one — *the id we sent to the addons was `tmdb:…`, not `tt…`* — was being written
 * every time and read by nobody, while the reporter and the maintainer traded guesses about
 * Vietnamese metadata for three weeks.
 *
 * The sink is null in every build until tvOS installs one (see `StreamProbe` on the Swift side,
 * gated on the Settings → About toggle), so this costs a null check per event when off, and the
 * repositories stay free of any platform or UI dependency. Same house pattern as `HomeHeroProbe`
 * and `TabBarProbe`, moved down into `shared` because the interesting events happen here.
 *
 * **Deliberate fork divergence** — upstream has no equivalent. It is additive and inert by
 * default, so it does not complicate future ports.
 */
object StreamDiagnostics {

    /**
     * Installed by the platform when the tester turns diagnostics on. Assigned from the main
     * thread at most; read from whichever dispatcher a fetch is running on. Kept deliberately
     * simple — a dropped or interleaved line is an acceptable cost for a diagnostic that must
     * never be able to affect the fetch it is describing.
     */
    var sink: ((String) -> Unit)? = null

    fun log(line: String) {
        sink?.invoke(line)
    }

    /**
     * Shortens an addon resource URL to something that fits a TV screen and a photograph: the
     * host plus the trailing `/stream/<type>/<id>.json`. The middle of a Stremio transport URL is
     * usually a base64 config blob that is both enormous and, in a screenshot posted to Reddit,
     * frequently a secret — debrid API keys live in there.
     */
    fun redactUrl(url: String): String {
        val scheme = url.substringBefore("://", missingDelimiterValue = "")
        val rest = if (scheme.isEmpty()) url else url.substringAfter("://")
        val host = rest.substringBefore('/')
        val tail = rest.substringAfterLast("/stream/", missingDelimiterValue = "")
        return if (tail.isEmpty()) host else "$host/…/stream/$tail"
    }
}
