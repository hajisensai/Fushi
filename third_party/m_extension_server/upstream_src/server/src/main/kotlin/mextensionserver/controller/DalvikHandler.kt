package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.source.online.HttpSource
import fi.iki.elonen.NanoHTTPD
import io.github.oshai.kotlinlogging.KotlinLogging
import mextensionserver.impl.MExtensionServerLoader
import mextensionserver.impl.MihonInvoker
import mextensionserver.model.DataBody
import okhttp3.Cookie
import okhttp3.HttpUrl

class DalvikHandler {
    private val logger = KotlinLogging.logger {}
    private val objectMapper = jacksonObjectMapper()

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response =
        try {
            // Parse JSON body first to get extension data
            val body = mutableMapOf<String, String>()
            session.parseBody(body)
            val json = body["postData"] ?: throw IllegalArgumentException("No JSON body")

            // Deserialize DataBody
            val dataBody = objectMapper.readValue(json, DataBody::class.java)

            val result =
                MExtensionServerLoader.invokeWithExtension(dataBody.data) { loadedExtension ->
                    val selectedSource = MihonInvoker.selectSource(loadedExtension.sources, dataBody)
                    MihonInvoker.preparePreferences(dataBody, selectedSource)

                    // Get domain from source
                    val domain =
                        selectedSource.let { source ->
                            try {
                                val baseUrl = source.javaClass.getMethod("getBaseUrl").invoke(source) as String
                                java.net.URI(baseUrl).host
                            } catch (e: Exception) {
                                logger.error(e) { "Error getting domain from source" }
                                null
                            }
                        } ?: "localhost"

                    // Intercept Cookie header and save to global cookie jar
                    val cookies =
                        (session.headers["cookie"] ?: session.headers["Cookie"])
                            ?.let { cookieHeader ->
                                cookieHeader
                                    .split(";")
                                    .map { cookieStr ->
                                        val trimmed = cookieStr.trim()
                                        val parts = trimmed.split("=", limit = 2)
                                        val name = parts[0].trim()
                                        val value = parts[1].trim()
                                        Cookie
                                            .Builder()
                                            .name(name)
                                            .value(value)
                                            .domain(domain.removePrefix("."))
                                            .path("/")
                                            .build()
                                    }.distinctBy { it.name }
                            }?.toList()
                    val network =
                        selectedSource.let { source ->
                            when (source) {
                                is HttpSource -> source.network
                                is AnimeHttpSource -> source.network
                                else -> null
                            }
                        }
                    if (cookies != null) {
                        network?.cookieJar?.addAll(
                            HttpUrl
                                .Builder()
                                .scheme("http")
                                .host(domain.removePrefix("."))
                                .build(),
                            cookies,
                        )
                    }
                    val ua = (session.headers["user-agent"] ?: session.headers["User-Agent"])
                    if (ua != null) {
                        network?.setUA(ua)
                    }

                    MihonInvoker.invokeMethod(loadedExtension, dataBody)
                }

            // Serialize response
            val responseJson = objectMapper.writeValueAsString(result)

            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK,
                "application/json",
                responseJson,
            )
        } catch (e: LinkageError) {
            errorResponse(e)
        } catch (e: Exception) {
            errorResponse(e)
        }

    private fun errorResponse(error: Throwable): NanoHTTPD.Response {
        logger.error(error) { "Error handling request" }
        val status =
            when (error) {
                is eu.kanade.tachiyomi.network.HttpException -> {
                    when (error.code) {
                        400 -> NanoHTTPD.Response.Status.BAD_REQUEST
                        401 -> NanoHTTPD.Response.Status.UNAUTHORIZED
                        403 -> NanoHTTPD.Response.Status.FORBIDDEN
                        404 -> NanoHTTPD.Response.Status.NOT_FOUND
                        429 -> NanoHTTPD.Response.Status.INTERNAL_ERROR
                        500 -> NanoHTTPD.Response.Status.INTERNAL_ERROR
                        else -> NanoHTTPD.Response.Status.INTERNAL_ERROR
                    }
                }
                else -> NanoHTTPD.Response.Status.INTERNAL_ERROR
            }
        val errorResponse =
            mapOf(
                "error" to (error.message ?: error.javaClass.simpleName),
                "code" to (if (error is eu.kanade.tachiyomi.network.HttpException) error.code else 500),
            )
        val errorJson = objectMapper.writeValueAsString(errorResponse)
        return NanoHTTPD.newFixedLengthResponse(
            status,
            "application/json",
            errorJson,
        )
    }
}
