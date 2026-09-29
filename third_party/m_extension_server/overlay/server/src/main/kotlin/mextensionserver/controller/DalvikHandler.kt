package mextensionserver.controller

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.host.AnimeVideoLoader
import eu.kanade.tachiyomi.animesource.model.AnimeFilter
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.network.interceptor.CloudflareChallengeRequiredException
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import fi.iki.elonen.NanoHTTPD
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.runBlocking
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
                        if (dataBody.method == "getVideoList") {
                            // Upstream's invokeGetVideoList returns the raw lib-14
                            // `getVideoList(episode)`: no hoster expansion, no
                            // `resolveVideo` / `getVideoUrl`. Both generations of
                            // extensions go through the shared host loader instead.
                            loadEpisodeVideos(selectedSource, dataBody)
                        } else {
                            MihonInvoker.invokeMethod(loadedExtension, dataBody)
                        }
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
        // The interceptor's exception is usually wrapped by the time it reaches here (Rx /
        // coroutine adapters, extension-side catch-and-rethrow), so walk the cause chain
        // rather than testing the top-level type -- the Android host does the same.
        val challenge =
            generateSequence(error) { it.cause }
                .filterIsInstance<CloudflareChallengeRequiredException>()
                .firstOrNull()
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
                    "errorKind" to
                        when {
                            challenge != null -> "cloudflare"
                            sourceStatusCode != null -> "sourceHttp"
                            else -> "bridge"
                        },
                    "sourceStatusCode" to sourceStatusCode,
                    // The host opens a browser at exactly this URL with exactly this
                    // User-Agent; cf_clearance is issued against both.
                    "challengeUrl" to challenge?.url?.toString(),
                    "userAgent" to challenge?.userAgent,
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
        // Aniyomi's filter model is a parallel sealed hierarchy with the same
        // eight shapes; it goes through the same explicit wire so the host can
        // reuse one decoder for both ecosystems.
        is AnimeFilterList -> result.map { it.toBridgeMap() }
        // `getVideoList` hands back the extension's `Video` objects verbatim.
        // Jackson would serialize their okhttp `Headers` and the transient
        // download-progress fields into an unstable shape; project the five
        // fields the player needs instead.
        is List<*> ->
            if (result.isNotEmpty() && result.all { it is Video }) {
                result.map { (it as Video).toBridgeMap() }
            } else {
                result
            }
        else -> result
    }

/**
 * `getVideoList` across both extension generations; see [AnimeVideoLoader].
 * `EpisodeData` is upstream's wire model; the `SEpisode` is rebuilt here because
 * upstream keeps its converter private.
 */
internal fun loadEpisodeVideos(
    source: Any,
    dataBody: DataBody,
): List<Video> {
    val episodeData = dataBody.episodeData ?: throw IllegalArgumentException("episodeData is required for getVideoList")
    if (source !is AnimeSource) {
        throw IllegalArgumentException("Source must be an AnimeSource for getVideoList")
    }
    val episode =
        SEpisode.create().also { episode ->
            episode.url = episodeData.url ?: ""
            episode.name = episodeData.name ?: ""
            episode.date_upload = episodeData.date_upload ?: 0L
            episode.episode_number = episodeData.episode_number ?: 0f
            episode.scanlator = episodeData.scanlator
        }
    return runBlocking { AnimeVideoLoader.loadVideos(source, episode) }
}

/**
 * The wire shape of one playable candidate. `quality` / `url` are the lib-14 names
 * the host already decodes; `videoTitle` / `resolution` / `bitrate` / `preferred`
 * are the lib-16 fields the player's candidate picker uses. Android's
 * `MihonModelBridge.Video.toBridgeMap` must stay identical.
 */
internal fun Video.toBridgeMap(): Map<String, Any?> =
    mapOf(
        "url" to url,
        "quality" to quality,
        // The lib-16 deprecated constructor stores a null url as the string
        // "null"; the wire keeps the lib-14 meaning (null = unresolved).
        "videoUrl" to videoUrl.takeUnless { isVideoUrlUnresolved },
        "videoTitle" to videoTitle,
        "resolution" to resolution,
        "bitrate" to bitrate,
        "preferred" to preferred,
        "headers" to
            headers?.let { headers ->
                (0 until headers.size).associate { index -> headers.name(index) to headers.value(index) }
            },
        "subtitleTracks" to subtitleTracks.map { track -> mapOf("url" to track.url, "lang" to track.lang) },
        "audioTracks" to audioTracks.map { track -> mapOf("url" to track.url, "lang" to track.lang) },
        "mpvArgs" to mpvArgs.map { (key, value) -> mapOf("key" to key, "value" to value) },
    )

private fun AnimeFilter<*>.toBridgeMap(): Map<String, Any?> {
    val filter = this
    val type =
        when (filter) {
            is AnimeFilter.Header -> "header"
            is AnimeFilter.Separator -> "separator"
            is AnimeFilter.Select<*> -> "select"
            is AnimeFilter.Text -> "text"
            is AnimeFilter.CheckBox -> "checkBox"
            is AnimeFilter.TriState -> "triState"
            is AnimeFilter.Group<*> -> "group"
            is AnimeFilter.Sort -> "sort"
        }
    return buildMap {
        put("name", filter.name)
        put("type", type)
        when (filter) {
            is AnimeFilter.Select<*> -> {
                put("state", filter.state)
                put("values", filter.values.map { value -> value.toString() })
            }
            is AnimeFilter.Text -> put("state", filter.state)
            is AnimeFilter.CheckBox -> put("state", filter.state)
            is AnimeFilter.TriState -> put("state", filter.state)
            is AnimeFilter.Group<*> ->
                put(
                    "children",
                    filter.state.filterIsInstance<AnimeFilter<*>>().map { child -> child.toBridgeMap() },
                )
            is AnimeFilter.Sort -> {
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
