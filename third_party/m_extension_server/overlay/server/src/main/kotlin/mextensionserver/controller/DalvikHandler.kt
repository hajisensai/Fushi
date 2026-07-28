package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.online.HttpSource
import fi.iki.elonen.NanoHTTPD
import io.github.oshai.kotlinlogging.KotlinLogging
import mextensionserver.impl.MExtensionServerLoader
import mextensionserver.impl.MihonInvoker
import mextensionserver.model.DataBody
import mextensionserver.model.FiltersResponse
import okhttp3.Cookie
import okhttp3.HttpUrl

/**
 * Hibiki serializes manga filters into an explicit wire shape. Jackson cannot
 * otherwise preserve the concrete sealed subtype, which makes TriState and
 * Sort indistinguishable to clients.
 */
class DalvikHandler {
    private val logger = KotlinLogging.logger {}
    private val objectMapper = jacksonObjectMapper()

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response =
        try {
            val body = mutableMapOf<String, String>()
            session.parseBody(body)
            val json = body["postData"] ?: throw IllegalArgumentException("No JSON body")
            val dataBody = objectMapper.readValue(json, DataBody::class.java)

            val result =
                MExtensionServerLoader.invokeWithExtension(dataBody.data) { loadedExtension ->
                    val selectedSource = MihonInvoker.selectSource(loadedExtension.sources, dataBody)
                    MihonInvoker.preparePreferences(dataBody, selectedSource)
                    val domain =
                        selectedSource.let { source ->
                            try {
                                val baseUrl = source.javaClass.getMethod("getBaseUrl").invoke(source) as String
                                java.net.URI(baseUrl).host
                            } catch (error: Exception) {
                                logger.error(error) { "Error getting domain from source" }
                                null
                            }
                        } ?: "localhost"

                    val cookies =
                        (session.headers["cookie"] ?: session.headers["Cookie"])
                            ?.let { cookieHeader ->
                                cookieHeader
                                    .split(";")
                                    .map { cookieString ->
                                        val parts = cookieString.trim().split("=", limit = 2)
                                        Cookie
                                            .Builder()
                                            .name(parts[0].trim())
                                            .value(parts.getOrElse(1) { "" }.trim())
                                            .domain(domain.removePrefix("."))
                                            .path("/")
                                            .build()
                                    }.distinctBy { it.name }
                            }?.toList()
                    val network =
                        when (selectedSource) {
                            is HttpSource -> selectedSource.network
                            is AnimeHttpSource -> selectedSource.network
                            else -> null
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
                    (session.headers["user-agent"] ?: session.headers["User-Agent"])
                        ?.let { userAgent -> network?.setUA(userAgent) }

                    MihonInvoker.invokeMethod(loadedExtension, dataBody)
                }

            val serializableResult =
                if (result is FiltersResponse) {
                    mapOf(
                        "filterList" to
                            result.filterList?.map { filter -> filter.toBridgeMap() }.orEmpty(),
                    )
                } else {
                    result
                }
            val responseJson = objectMapper.writeValueAsString(serializableResult)
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.OK,
                "application/json",
                responseJson,
            )
        } catch (error: LinkageError) {
            errorResponse(error)
        } catch (error: Exception) {
            errorResponse(error)
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
                        else -> NanoHTTPD.Response.Status.INTERNAL_ERROR
                    }
                }
                else -> NanoHTTPD.Response.Status.INTERNAL_ERROR
            }
        val responseJson =
            objectMapper.writeValueAsString(
                mapOf(
                    "error" to (error.message ?: error.javaClass.simpleName),
                    "code" to
                        if (error is eu.kanade.tachiyomi.network.HttpException) {
                            error.code
                        } else {
                            500
                        },
                ),
            )
        return NanoHTTPD.newFixedLengthResponse(
            status,
            "application/json",
            responseJson,
        )
    }
}

private fun Filter<*>.toBridgeMap(): Map<String, Any?> {
    val filter = this
    val type =
        when (filter) {
            is Filter.Header -> "header"
            is Filter.Separator -> "separator"
            is Filter.Select<*> -> "select"
            is Filter.Text -> "text"
            is Filter.CheckBox -> "checkBox"
            is Filter.TriState -> "triState"
            is Filter.Group<*> -> "group"
            is Filter.Sort -> "sort"
        }
    return buildMap {
        put("name", filter.name)
        put("type", type)
        when (filter) {
            is Filter.Select<*> -> {
                put("state", filter.state)
                put("values", filter.values.map { value -> value.toString() })
            }
            is Filter.Text -> put("state", filter.state)
            is Filter.CheckBox -> put("state", filter.state)
            is Filter.TriState -> put("state", filter.state)
            is Filter.Group<*> ->
                put(
                    "children",
                    filter.state.filterIsInstance<Filter<*>>().map { child -> child.toBridgeMap() },
                )
            is Filter.Sort -> {
                put("values", filter.values.toList())
                put(
                    "state",
                    mapOf(
                        "index" to (filter.state?.index ?: 0),
                        "ascending" to (filter.state?.ascending ?: true),
                    ),
                )
            }
            else -> Unit
        }
    }
}
