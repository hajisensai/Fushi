package mextensionserver.controller

import fi.iki.elonen.NanoHTTPD
import io.github.oshai.kotlinlogging.KotlinLogging
import mextensionserver.impl.MExtensionServerLoader
import mextensionserver.impl.MihonImageProxy
import java.io.IOException
import java.security.MessageDigest

class MExtensionServerController {
    private val logger = KotlinLogging.logger {}
    private var server: WebServer? = null

    fun start(port: Int) {
        try {
            server = WebServer(port)
            server?.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
            val actualPort = server?.listeningPort ?: 0
            MihonImageProxy.configure(actualPort)
            logger.info { "Hibiki M-Extension-Server started on loopback port $actualPort" }
            announceReady(actualPort)
        } catch (error: IOException) {
            logger.error(error) { "Failed to start M-Extension-Server" }
            throw error
        }
    }

    /**
     * Tells the host, on stdout, which port this process actually holds.
     *
     * The host starts us with port `0` and waits for this line instead of
     * picking a port itself. A host-side "bind, read the port, close, hand the
     * number to the child" dance is a TOCTOU: between the close and the child's
     * bind anything else on the machine can take the port, and the host would
     * then send its per-process Bearer token to a stranger. Here the port is
     * printed *after* [NanoHTTPD.start] has bound it, so the number is one this
     * process demonstrably owns at the moment it is reported.
     *
     * The line is deliberately machine-readable and prefix-anchored so it stays
     * separable from logback output on the same stream.
     */
    private fun announceReady(actualPort: Int) {
        println("$READY_LINE_PREFIX$actualPort")
        System.out.flush()
    }

    fun stop() {
        server?.stop()
        logger.info { "Hibiki M-Extension-Server stopped" }
        MExtensionServerLoader.cleanupTempFiles()
    }

    fun isRunning(): Boolean = server?.isAlive == true

    fun getPort(): Int = server?.listeningPort ?: 0

    companion object {
        /** Host-facing readiness contract; see [announceReady]. */
        const val READY_LINE_PREFIX = "HIBIKI_MIHON_READY port="
    }

    private inner class WebServer(port: Int) : NanoHTTPD("127.0.0.1", port) {
        private val bearer = System.getenv("HIBIKI_MIHON_TOKEN")
            ?.takeIf(String::isNotBlank)
            ?: throw IllegalStateException("HIBIKI_MIHON_TOKEN is required")

        override fun serve(session: IHTTPSession): Response {
            if (!authorized(session)) {
                return newFixedLengthResponse(
                    Response.Status.UNAUTHORIZED,
                    "application/json",
                    """{"error":"Unauthorized"}""",
                )
            }
            return when (session.uri) {
                "/dalvik" -> DalvikHandler().serve(session)
                "/inspect" -> InspectHandler().serve(session)
                "/source-image" -> SourceImageHandler().serve(session)
                "/source-data/clear" -> SourceDataHandler().serve(session)
                "/" -> newFixedLengthResponse("Hibiki M-Extension-Server")
                "/capabilities" -> newFixedLengthResponse(
                    Response.Status.OK,
                    "application/json",
                    """{"hibikiMihonBridge":1,"sourceFactory":true,"preferenceCallbacks":true,"imageProxy":true,"sourceUrls":true}""",
                )
                "/stop" -> newFixedLengthResponse("Server stopping").also {
                    Thread {
                        Thread.sleep(100)
                        stop()
                    }.start()
                }
                else -> if (session.uri.startsWith(ImageProxyHandler.ROUTE_PREFIX)) {
                    ImageProxyHandler().serve(session)
                } else {
                    newFixedLengthResponse(Response.Status.NOT_FOUND, MIME_PLAINTEXT, "Not Found")
                }
            }
        }

        private fun authorized(session: IHTTPSession): Boolean {
            val actual = session.headers["authorization"].orEmpty()
            val expected = "Bearer $bearer"
            return MessageDigest.isEqual(
                actual.toByteArray(Charsets.UTF_8),
                expected.toByteArray(Charsets.UTF_8),
            )
        }
    }
}
