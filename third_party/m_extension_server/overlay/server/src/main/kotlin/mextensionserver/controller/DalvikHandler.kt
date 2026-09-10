package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import fi.iki.elonen.NanoHTTPD
import io.github.oshai.kotlinlogging.KotlinLogging
import mextensionserver.impl.MExtensionServerLoader
import mextensionserver.impl.MihonInvoker
import mextensionserver.model.DataBody
import mextensionserver.model.FiltersResponse

/**
 * Hibiki serializes manga filters into an explicit wire shape. Jackson cannot
 * otherwise preserve the concrete sealed subtype, which makes TriState and
 * Sort indistinguishable to clients.
 */
private const val MAX_STACK_TRACE_CHARS = 16_000

class DalvikHandler {
    private val logger = KotlinLogging.logger {}
    private val objectMapper = jacksonObjectMapper()

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        // Declared outside the try so the catch clauses can still report the
        // jar: the failing call is the one most likely to have rotated the
        // session.
        var pendingJarCookies: String? = null
        return try {
            val body = mutableMapOf<String, String>()
            session.parseBody(body)
            val json = body["postData"] ?: throw IllegalArgumentException("No JSON body")
            val dataBody = objectMapper.readValue(json, DataBody::class.java)

            // A failing call is the *most* likely one to have rotated the
            // session -- a 401/403 usually is the site handing out a fresh
            // cookie as it rejects the stale one. Capturing the jar here rather
            // than only on the success path is what lets the error response
            // carry it back; otherwise the host retries forever with the dead
            // value it already had.
            val invocationResult =
                MExtensionServerLoader.invokeWithExtension(dataBody.data) { loadedExtension ->
                    val selectedSource = MihonInvoker.selectSource(loadedExtension.sources, dataBody)
                    MihonInvoker.preparePreferences(dataBody, selectedSource)
                    // Host-owned login session; see [SourceCookieInjection].
                    val domain = SourceCookieInjection.domainOf(selectedSource)
                    SourceCookieInjection.injectRequestCookies(session, selectedSource)
                    SourceCookieInjection.applyRequestUserAgent(session, selectedSource)
                    try {
                        MihonInvoker.invokeMethod(loadedExtension, dataBody)
                    } finally {
                        pendingJarCookies =
                            SourceCookieInjection.encodeJarCookies(
                                objectMapper,
                                selectedSource,
                                domain,
                            )
                    }
                }

            val serializableResult = filterResponseForBridge(invocationResult)
            val responseJson = objectMapper.writeValueAsString(serializableResult)
            NanoHTTPD
                .newFixedLengthResponse(
                    NanoHTTPD.Response.Status.OK,
                    "application/json",
                    responseJson,
                ).withJarCookies(pendingJarCookies)
        } catch (error: LinkageError) {
            errorResponse(error).withJarCookies(pendingJarCookies)
        } catch (error: Exception) {
            errorResponse(error).withJarCookies(pendingJarCookies)
        }
    }

    /** Attaches [SET_COOKIE_HEADER] when the call actually touched cookies. */
    private fun NanoHTTPD.Response.withJarCookies(payload: String?): NanoHTTPD.Response =
        apply { if (payload != null) addHeader(SET_COOKIE_HEADER, payload) }

    internal fun errorResponse(error: Throwable): NanoHTTPD.Response {
        logger.error(error) { "Error handling request" }
        // Only the typed source HTTP failure establishes an upstream status.
        // Exception messages (including ones mentioning HTTP) are not a protocol.
        val sourceStatusCode =
            (error as? eu.kanade.tachiyomi.network.HttpException)?.code?.takeIf { it in 400..599 }
        val status =
            if (sourceStatusCode != null) {
                NanoHTTPD.Response.Status.lookup(sourceStatusCode)
                    ?: object : NanoHTTPD.Response.IStatus {
                        override fun getRequestStatus(): Int = sourceStatusCode

                        override fun getDescription(): String = "$sourceStatusCode Source HTTP error"
                    }
            } else {
                NanoHTTPD.Response.Status.INTERNAL_ERROR
            }
        // 桌面端此前只回 `error`（= e.message），Java 栈仅存在于本进程 stdout，而宿主
        // 把 sidecar 的 stdout/stderr 直接丢弃，于是扩展加载类错误（NoSuchMethodError /
        // InstantiationError / ClassCastException）在 UI 上只剩一行没有出处的文本，
        // 无法定位是哪个扩展的哪个方法。把类型与栈一并回传，宿主填进
        // MihonRuntimeException.details，与 Android 路径对齐。
        val responseJson =
            objectMapper.writeValueAsString(
                mapOf(
                    "error" to (error.message ?: error.javaClass.simpleName),
                    "errorType" to error.javaClass.name,
                    "stackTrace" to error.stackTraceToString().take(MAX_STACK_TRACE_CHARS),
                    "errorKind" to if (sourceStatusCode != null) "sourceHttp" else "bridge",
                    "sourceStatusCode" to sourceStatusCode,
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

/** Preserve both supported response envelopes without serializing extension objects. */
internal fun filterResponseForBridge(result: Any?): Any? =
    when (result) {
        is FilterList -> result.map { it.toBridgeMap() }
        is FiltersResponse -> mapOf("filterList" to result.filterList?.map { it.toBridgeMap() }.orEmpty())
        else -> result
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
