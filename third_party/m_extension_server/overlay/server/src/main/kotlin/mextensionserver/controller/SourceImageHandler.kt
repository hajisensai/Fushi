package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.source.online.HttpSource
import fi.iki.elonen.NanoHTTPD
import mextensionserver.impl.MExtensionServerLoader
import mextensionserver.impl.MihonInvoker
import mextensionserver.model.DataBody
import okhttp3.Request

class SourceImageHandler {
    private val mapper = jacksonObjectMapper()

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        var pendingJarCookies: String? = null
        return try {
            // Not `parseBody`: it spools the body into a temp file (BUG-4914).
            val request = mapper.readValue(BridgeRequests.readJson(session), SourceImageRequest::class.java)
            val data =
                DataBody(
                    apkSha256 = request.apkSha256,
                    method = "headersManga",
                    preferences = request.preferences,
                )
            // Only the request runs under the extension's lane lock; the body is
            // relayed after it is released, so a slow cover does not hold up the
            // source's searches.
            val upstream =
                MExtensionServerLoader.invokeWithExtension(request.apkSha256) { loaded ->
                    val source = MihonInvoker.selectSource(loaded.sources, data)
                    // Covers of manga and anime sources are fetched the same
                    // way: the source's own OkHttp client plus its default
                    // headers (Referer / User-Agent the site expects).
                    val (client, headers) =
                        when (source) {
                            is HttpSource -> source.client to source.headers
                            is AnimeHttpSource -> source.client to source.headers
                            else -> throw IllegalArgumentException("Source is not an HTTP source")
                        }
                    MihonInvoker.preparePreferences(data, source)
                    // Covers are fetched with the source's own client, so they need the
                    // host-owned session too (BUG-2425). Without this a login-gated source
                    // renders signed-in pages next to broken covers whenever an image is
                    // the first call after a sidecar restart -- the bridge jar is empty
                    // until some /dalvik call happens to refill it.
                    SourceCookieInjection.injectRequestCookies(session, source)
                    SourceCookieInjection.applyRequestUserAgent(session, source)
                    try {
                        val response =
                            client
                                .newCall(
                                    Request
                                        .Builder()
                                        .url(request.url)
                                        .headers(headers)
                                        .build(),
                                ).execute()
                        if (!response.isSuccessful) {
                            response.close()
                            throw IllegalStateException("Source image HTTP ${response.code}")
                        }
                        response
                    } finally {
                        // Images are usually the most frequent calls, so they are
                        // typically what first meets a session renewal. Injecting
                        // without reporting back loses every cookie rotated on this
                        // path (BUG-2425). The jar already holds this response's
                        // Set-Cookie: OkHttp stores it when the headers arrive.
                        pendingJarCookies =
                            SourceCookieInjection.encodeJarCookies(
                                mapper,
                                source,
                                SourceCookieInjection.domainOf(source),
                            )
                    }
                }
            // Relayed as it arrives (manga-18b) and still capped: the URL is
            // chosen by the source site and the sidecar runs with `-Xmx512m`.
            // `body.byteStream()` is counted against [MAX_IMAGE_BYTES] as it is
            // read -- `Content-Length` is only a hint (absent on chunked
            // responses, attacker-controlled anyway); never `body.bytes()`.
            streamingImageResponse(
                upstream,
                maxBytes = MAX_IMAGE_BYTES,
                extraHeaders = pendingJarCookies?.let { mapOf(SET_COOKIE_HEADER to it) }.orEmpty(),
            )
        } catch (error: RequestBodyException) {
            with(BridgeRequests) { error.toResponse() }
        } catch (error: Throwable) {
            val missing = BridgeRequests.apkNotRegisteredIn(error)
            NanoHTTPD
                .newFixedLengthResponse(
                    if (missing != null) NanoHTTPD.Response.Status.CONFLICT else NanoHTTPD.Response.Status.INTERNAL_ERROR,
                    "application/json",
                    mapper.writeValueAsString(
                        with(BridgeRequests) { missing?.apkUnknownPayload() }
                            ?: mapOf("error" to (error.message ?: "Image request failed")),
                    ),
                ).apply {
                    pendingJarCookies?.let { addHeader(SET_COOKIE_HEADER, it) }
                }
        }
    }

    private companion object {
        /** Generous for cover art, far below the sidecar's 512 MiB heap. */
        const val MAX_IMAGE_BYTES: Long = 32L * 1024 * 1024
    }

    private data class SourceImageRequest(
        val apkSha256: String,
        val sourceId: String,
        val url: String,
        val preferences: MutableList<Map<String, Any>>? =
            mutableListOf(
                mutableMapOf(
                    "key" to "__mangatan_bridge_context__",
                    "sourceId" to sourceId,
                ),
            ),
    )
}
