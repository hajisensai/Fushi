package mextensionserver.controller

import fi.iki.elonen.NanoHTTPD
import okhttp3.Response
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream

/**
 * Relays an upstream image to the host as it arrives (manga-18b).
 *
 * Upstream read the whole image into memory and only then sent a fixed-length
 * response, so the host's header timeout swallowed the entire download and its
 * idle timeout only ever watched a loopback memory copy: the "no data for N
 * seconds" rule never applied, and every page sat whole in the 512 MiB heap.
 * Here the response headers leave as soon as the source's do, and each chunk is
 * forwarded as it is read.
 *
 * The response is chunked and closes its connection: if the source stalls past
 * its read timeout or the body breaks off, NanoHTTPD stops before the chunked
 * terminator and the socket closes, so the host sees a truncated body (an
 * error) at once instead of waiting for an end that never comes. Closing the
 * relay -- normal end, host cancel, or failure -- closes [upstream], which
 * cancels the source call.
 *
 * [maxBytes] caps the relayed size (covers); `null` keeps pages unbounded as
 * before.
 */
internal fun streamingImageResponse(
    upstream: Response,
    maxBytes: Long?,
    extraHeaders: Map<String, String> = emptyMap(),
): NanoHTTPD.Response {
    val body = upstream.body
    val declared = body.contentLength()
    if (maxBytes != null && declared > maxBytes) {
        upstream.close()
        throw IllegalStateException("Source image exceeds $maxBytes bytes")
    }
    val contentType = body.contentType()?.toString() ?: "application/octet-stream"
    return NanoHTTPD
        .newChunkedResponse(
            NanoHTTPD.Response.Status.OK,
            contentType,
            UpstreamImageStream(upstream, body.byteStream(), maxBytes),
        ).apply {
            closeConnection(true)
            extraHeaders.forEach { (name, value) -> addHeader(name, value) }
        }
}

/** Counts relayed bytes against [maxBytes] and owns the upstream response's lifetime. */
internal class UpstreamImageStream(
    private val upstream: Response,
    source: InputStream,
    private val maxBytes: Long?,
) : FilterInputStream(source) {
    private var relayed = 0L
    private var closed = false

    override fun read(): Int {
        val value = super.read()
        if (value >= 0) count(1)
        return value
    }

    override fun read(
        buffer: ByteArray,
        offset: Int,
        length: Int,
    ): Int {
        val read = super.read(buffer, offset, length)
        if (read > 0) count(read)
        return read
    }

    private fun count(read: Int) {
        relayed += read
        if (maxBytes != null && relayed > maxBytes) {
            throw IOException("Source image exceeds $maxBytes bytes")
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        try {
            super.close()
        } finally {
            upstream.close()
        }
    }
}
