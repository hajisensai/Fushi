package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.source.online.HttpSource
import fi.iki.elonen.NanoHTTPD
import mextensionserver.impl.MExtensionServerLoader
import mextensionserver.impl.MihonInvoker
import mextensionserver.model.DataBody
import okhttp3.Request
import okhttp3.ResponseBody
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class SourceImageHandler {
    private val mapper = jacksonObjectMapper()

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response =
        try {
            val files = mutableMapOf<String, String>()
            session.parseBody(files)
            val request = mapper.readValue(files["postData"], SourceImageRequest::class.java)
            val data = DataBody(
                data = request.data,
                method = "headersManga",
                preferences = request.preferences,
            )
            val image = MExtensionServerLoader.invokeWithExtension(request.data) { loaded ->
                val source = MihonInvoker.selectSource(loaded.sources, data) as? HttpSource
                    ?: throw IllegalArgumentException("Source is not an HTTP source")
                MihonInvoker.preparePreferences(data, source)
                val response = source.client.newCall(
                    Request.Builder().url(request.url).headers(source.headers).build(),
                ).execute()
                response.use {
                    if (!it.isSuccessful) {
                        throw IllegalStateException("Source image HTTP ${it.code}")
                    }
                    val body = it.body
                    ImageResult(
                        readBounded(body),
                        body.contentType()?.toString() ?: "application/octet-stream",
                    )
                }
            }
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK,
                image.contentType,
                ByteArrayInputStream(image.bytes),
                image.bytes.size.toLong(),
            )
        } catch (error: Throwable) {
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.INTERNAL_ERROR,
                "application/json",
                mapper.writeValueAsString(mapOf("error" to (error.message ?: "Image request failed"))),
            )
        }

    /**
     * Buffers the response with a hard ceiling instead of `body.bytes()`.
     *
     * The URL fetched here is chosen by the source site, and the sidecar runs
     * with `-Xmx512m`; an unbounded `bytes()` lets one hostile or broken
     * response OOM the whole JVM and take every other extension down with it.
     * `Content-Length` is only a hint (it is absent on chunked responses and
     * attacker-controlled anyway), so the stream is counted as it is read.
     */
    private fun readBounded(body: ResponseBody): ByteArray {
        val declared: Long = body.contentLength()
        if (declared > MAX_IMAGE_BYTES) {
            throw IllegalStateException("Source image exceeds $MAX_IMAGE_BYTES bytes")
        }
        // Content-Length only sizes the first allocation, and even that is
        // capped: a lying header must not be able to make us reserve 32 MiB.
        val initial: Int = declared.coerceIn(CHUNK_BYTES.toLong(), INITIAL_CAPACITY_CAP).toInt()
        val buffered = ByteArrayOutputStream(initial)
        val chunk = ByteArray(CHUNK_BYTES)
        var total = 0L
        body.byteStream().use { stream ->
            while (true) {
                val read = stream.read(chunk)
                if (read < 0) break
                total += read
                if (total > MAX_IMAGE_BYTES) {
                    throw IllegalStateException("Source image exceeds $MAX_IMAGE_BYTES bytes")
                }
                buffered.write(chunk, 0, read)
            }
        }
        return buffered.toByteArray()
    }

    private companion object {
        /** Generous for cover art, far below the sidecar's 512 MiB heap. */
        const val MAX_IMAGE_BYTES: Long = 32L * 1024 * 1024
        const val CHUNK_BYTES: Int = 64 * 1024
        const val INITIAL_CAPACITY_CAP: Long = 1L * 1024 * 1024
    }

    private data class SourceImageRequest(
        val data: String,
        val sourceId: String,
        val url: String,
        val preferences: MutableList<Map<String, Any>>? = mutableListOf(
            mutableMapOf(
                "key" to "__mangatan_bridge_context__",
                "sourceId" to sourceId,
            ),
        ),
    )

    private data class ImageResult(val bytes: ByteArray, val contentType: String)
}
