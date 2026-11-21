package mextensionserver.controller

import fi.iki.elonen.NanoHTTPD
import io.github.oshai.kotlinlogging.KotlinLogging
import mextensionserver.impl.MihonImageProxy

class ImageProxyHandler {
    private val logger = KotlinLogging.logger {}

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        val token = session.uri.removePrefix(ROUTE_PREFIX)
        if (token.isEmpty() || token == session.uri) {
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.NOT_FOUND,
                NanoHTTPD.MIME_PLAINTEXT,
                "Image not found",
            )
        }

        return try {
            val upstream =
                MihonImageProxy.open(token)
                    ?: return NanoHTTPD.newFixedLengthResponse(
                        NanoHTTPD.Response.Status.NOT_FOUND,
                        NanoHTTPD.MIME_PLAINTEXT,
                        "Image not found",
                    )
            // Fushi: relayed as it arrives instead of buffered whole (manga-18b).
            streamingImageResponse(
                upstream,
                maxBytes = null,
                extraHeaders = mapOf("Cache-Control" to "private, max-age=86400"),
            )
        } catch (error: Throwable) {
            logger.error(error) { "Error proxying extension image" }
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.INTERNAL_ERROR,
                NanoHTTPD.MIME_PLAINTEXT,
                error.message ?: error.javaClass.simpleName,
            )
        }
    }

    companion object {
        const val ROUTE_PREFIX = "/image/"
    }
}
