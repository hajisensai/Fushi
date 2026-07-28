package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.source.online.HttpSource
import fi.iki.elonen.NanoHTTPD
import mextensionserver.impl.MExtensionServerLoader
import mextensionserver.impl.MihonInvoker
import mextensionserver.model.DataBody
import okhttp3.Request
import java.io.ByteArrayInputStream

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
                        body.bytes(),
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
