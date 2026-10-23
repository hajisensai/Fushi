package eu.kanade.tachiyomi.animesource.model

import fi.iki.elonen.NanoHTTPD

/**
 * Extension-provided local HTTP server (extensions-lib 17).
 *
 * An extension returns a subclass from `AnimeHttpSource.createHttpServer()` and
 * emits video / track urls starting with [PLACEHOLDER_URL]; the host starts the
 * server and substitutes [url] for the placeholder (`AnimeVideoLoader`). The
 * extension never starts or stops it itself.
 *
 * Desktop sidecar variant (the Android host compiles its own, see
 * `fushi/android/app/src/main/kotlin/eu/kanade/tachiyomi/animesource/model/HttpServer.kt`).
 * Unlike the lib stub (`NanoHTTPD(0)`, every interface) the host binds loopback
 * only: the server exists to feed the local player, and an extension must not get
 * a listener reachable from the network.
 *
 * @since extensions-lib 17
 */
open class HttpServer : NanoHTTPD(LOOPBACK_HOST, 0) {
    /** Scheme, host and port of the running server, e.g. `http://127.0.0.1:53124`. */
    val url: String
        get() = "http://$LOOPBACK_HOST:$listeningPort"

    companion object {
        const val PLACEHOLDER_URL = "http://localhost:1"

        private const val LOOPBACK_HOST = "127.0.0.1"
    }
}
