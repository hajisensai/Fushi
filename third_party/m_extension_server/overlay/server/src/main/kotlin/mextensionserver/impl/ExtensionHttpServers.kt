package mextensionserver.impl

import eu.kanade.tachiyomi.animesource.model.HttpServer
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import fi.iki.elonen.NanoHTTPD

/**
 * Lifecycle of extension-provided lib-17 local servers (`createHttpServer`).
 *
 * The lib contract is that the *host* starts and stops the server; the extension
 * only says what it serves. A video url on [HttpServer.PLACEHOLDER_URL] is played
 * long after the bridge call that produced it returns, so the server must outlive
 * that call: one server per source, started on first need, reused while it is
 * alive, and kept for the sidecar's lifetime (daemon threads, loopback only — see
 * [HttpServer]). A server that died (the extension's `serve` threw at startup, the
 * socket was closed) is replaced on the next request instead of being handed out.
 */
object ExtensionHttpServers {
    private val servers = HashMap<Long, HttpServer>()

    /** Base url of [source]'s running server, or null when it does not provide one. */
    @Synchronized
    fun baseUrlFor(source: AnimeHttpSource): String? {
        servers[source.id]?.let { running ->
            if (running.isAlive) return running.url
            running.stop()
            servers.remove(source.id)
        }
        val server = source.createHttpServer() ?: return null
        server.start(NanoHTTPD.SOCKET_READ_TIMEOUT, true)
        servers[source.id] = server
        return server.url
    }
}
