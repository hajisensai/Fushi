package app.fushi.reader.mihon

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import eu.kanade.tachiyomi.animesource.AnimeCatalogueSource
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.ConfigurableAnimeSource
import eu.kanade.tachiyomi.animesource.host.AnimeVideoLoader
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.interceptor.CloudflareChallengeRequiredException
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.online.HttpSource
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.InjektModule
import uy.kohesive.injekt.api.InjektRegistrar
import uy.kohesive.injekt.api.InjektScope
import uy.kohesive.injekt.api.addSingleton
import uy.kohesive.injekt.api.addSingletonFactory
import uy.kohesive.injekt.api.get
import uy.kohesive.injekt.registry.default.DefaultRegistrar
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.ConcurrentHashMap

class MihonChannelHandler(private val app: Application) {
    private val executor: ExecutorService = Executors.newFixedThreadPool(2)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val loader = MihonExtensionLoader(app)
    private val activeImageRequests = ConcurrentHashMap<String, Future<*>>()
    private var channel: MethodChannel? = null
    @Volatile
    private var disposed = false

    init {
        CloudflareChallengeCoordinator.initialize(app)
        Injekt = InjektScope(DefaultRegistrar())
        Injekt.importModule(
            object : InjektModule {
                override fun InjektRegistrar.registerInjectables() {
                    addSingleton(app)
                    addSingletonFactory { NetworkHelper(app) }
                    addSingletonFactory {
                        Json {
                            ignoreUnknownKeys = true
                            explicitNulls = false
                            coerceInputValues = true
                        }
                    }
                }
            },
        )
    }

    fun register(engine: FlutterEngine) {
        val registered = MethodChannel(
            engine.dartExecutor.binaryMessenger,
            "app.fushi.reader/mihon",
        )
        channel = registered
        registered.setMethodCallHandler { call, result ->
            if (disposed) {
                result.error("DISPOSED", "Android Mihon runtime is disposed", null)
                return@setMethodCallHandler
            }
            if (call.method == "cancelImageRequests") {
                val requestIds = call.argument<List<String>>("requestIds").orEmpty()
                requestIds.forEach { requestId ->
                    activeImageRequests.remove(requestId)?.cancel(true)
                }
                result.success(null)
                return@setMethodCallHandler
            }
            val requestId = if (call.method == "fetchImage") {
                call.argument<String>("requestId")
            } else {
                null
            }
            val future = executor.submit {
                try {
                    val value = handle(call)
                    mainHandler.post { reply(result, value) }
                } catch (error: Throwable) {
                    val challenge = generateSequence(error) { it.cause }
                        .filterIsInstance<CloudflareChallengeRequiredException>().firstOrNull()
                    if (challenge != null) {
                        mainHandler.post {
                            result.error("CLOUDFLARE_CHALLENGE_REQUIRED", "Source requires browser verification",
                                mapOf("url" to challenge.url.toString(), "userAgent" to challenge.userAgent))
                        }
                        return@submit
                    }
                    val operation = describeOperation(call)
                    val code = when (error) {
                        is MihonHostException -> error.code
                        is IllegalArgumentException -> "INVALID_ARGUMENT"
                        else -> "RUNTIME_FAILURE"
                    }
                    // 不能把真实异常换成一句固定文案：扩展跑在第三方 dex 里，
                    // 失败原因（缺类 / 网络 / 站点改版）只存在于 cause 链，丢了就无从诊断。
                    val message = "Mihon $operation failed: ${describeCauseChain(error)}"
                    Log.e(TAG, message, error)
                    val details = diagnosticDetails(error)
                    mainHandler.post { result.error(code, message, details) }
                } finally {
                    requestId?.let(activeImageRequests::remove)
                }
            }
            if (requestId != null) {
                activeImageRequests[requestId] = future
                if (future.isDone) {
                    activeImageRequests.remove(requestId, future)
                }
            }
        }
    }

    fun destroy() {
        if (disposed) return
        disposed = true
        channel?.setMethodCallHandler(null)
        channel = null
        activeImageRequests.values.forEach { request -> request.cancel(true) }
        activeImageRequests.clear()
        loader.clear()
        executor.shutdownNow()
    }

    /**
     * 通道回复的唯一出口。
     *
     * [handle] 是 `when` 表达式，分支若调的是 Unit 函数，表达式值就是
     * `kotlin.Unit` 单例；StandardMessageCodec 不认它，`result.success(Unit)`
     * 在主线程 Runnable 里抛 IllegalArgumentException 直接把进程带崩
     * （BUG-2081：`uninstallPrivateExtension` / `clearSourceData` 都中招，预览
     * 标记清不掉后每次进漫画 Discover/Import 都复崩）。void 回 null 在这里
     * 一处收口，不靠每个分支手写 `; null`；其它编不了的值同样只能变成
     * error 回复——编码在发送之前整体完成，抛出时 reply 还没被消费。
     */
    private fun reply(result: MethodChannel.Result, value: Any?) {
        try {
            result.success(if (value === Unit) null else value)
        } catch (error: IllegalArgumentException) {
            val message = "Mihon reply cannot be encoded: ${describeCauseChain(error)}"
            Log.e(TAG, message, error)
            result.error("ENCODE_FAILED", message, diagnosticDetails(error))
        }
    }

    private fun handle(call: MethodCall): Any? = when (call.method) {
        "configureProxyPolicy" -> {
            HostProxyPolicy.configure(
                call.argument<Int>("port") ?: throw IllegalArgumentException("Missing policy port"),
                stringArgument(call, "token"),
            )
            CloudflareChallengeCoordinator.configure(URI(stringArgument(call, "challengeProxyEndpoint")))
        }
        "solveCloudflare" -> CloudflareChallengeCoordinator.solve(
            app,
            stringArgument(call, "url").toHttpUrl(),
            call.argument<String>("userAgent")?.takeIf { it.isNotBlank() }
                ?: Injekt.get<NetworkHelper>().defaultUserAgentProvider(),
        )
        "capabilities" -> mapOf(
            "fushiMihonBridge" to 1,
            "sourceFactory" to true,
            "preferenceCallbacks" to true,
            "imageProxy" to true,
            "sourceUrls" to true,
        )
        "inspectExtension" -> loader.inspect(fileArgument(call, "apkPath")).toMap()
        "installPrivateExtension" -> install(fileArgument(call, "apkPath"))
        "uninstallPrivateExtension" -> uninstall(stringArgument(call, "packageName"))
        "invoke" -> invoke(call.argumentsMap())
        "fetchImage" -> fetchPageImage(call.argumentsMap())
        "fetchSourceImage" -> fetchSourceImage(call.argumentsMap())
        "clearSourceData" -> clearSourceData(call.argumentsMap())
        "invalidateExtension" -> loader.invalidate(stringArgument(call, "packageName"))
        "dispose" -> loader.clear()
        else -> throw MihonHostException("NOT_IMPLEMENTED", "Unknown Mihon channel method")
    }

    private fun install(input: File): Map<String, Any> {
        if (input.length() > MAX_APK_BYTES) {
            throw MihonHostException("APK_TOO_LARGE", "Extension APK exceeds 100 MiB")
        }
        val inspection = loader.inspect(input)
        val target = loader.extensionFile(inspection.packageName)
        if (target.exists()) {
            val current = loader.inspect(target)
            if (inspection.versionCode < current.versionCode) {
                throw MihonHostException("DOWNGRADE_REJECTED", "Extension downgrade is not allowed")
            }
            if (inspection.signerSha256 != current.signerSha256) {
                throw MihonHostException("SIGNATURE_CHANGED", "Extension signer changed")
            }
        }
        val part = File(target.parentFile, "${target.name}.part")
        val backup = File(target.parentFile, "${target.name}.previous")
        part.delete()
        FileOutputStream(part).use { output ->
            input.inputStream().use { source -> source.copyTo(output) }
            output.fd.sync()
        }
        if (!part.setReadOnly()) {
            part.delete()
            throw MihonHostException(
                "READ_ONLY_FAILED",
                "Unable to make staged extension read-only",
            )
        }
        try {
            loader.validate(part)
        } catch (error: Throwable) {
            part.delete()
            throw error
        }
        backup.delete()
        if (target.exists() && !target.renameTo(backup)) {
            part.delete()
            throw MihonHostException("ATOMIC_INSTALL_FAILED", "Unable to stage extension update")
        }
        try {
            if (!part.renameTo(target)) {
                throw MihonHostException("ATOMIC_INSTALL_FAILED", "Unable to install extension")
            }
            target.setReadOnly()
            loader.invalidate(inspection.packageName)
            loader.load(inspection.packageName)
            backup.delete()
        } catch (error: Throwable) {
            target.delete()
            if (backup.exists()) backup.renameTo(target)
            loader.invalidate(inspection.packageName)
            throw error
        } finally {
            part.delete()
        }
        return mapOf("apkPath" to target.absolutePath)
    }

    private fun uninstall(packageName: String) {
        loader.invalidate(packageName)
        val target = loader.extensionFile(packageName)
        if (target.exists() && !target.delete()) {
            throw MihonHostException("UNINSTALL_FAILED", "Unable to remove private extension")
        }
    }

    private fun invoke(arguments: Map<String, Any?>): Any? {
        val packageName = arguments.requiredString("packageName")
        val method = arguments.requiredString("method")
        val loaded = loader.load(packageName)
        if (method == "sourcesManga" || method == "sourcesAnime") {
            return loaded.sources.map(::sourceDescriptor)
        }
        val selected = sourceFromPreferences(loaded, arguments)
        applyPreferences(selected, arguments)
        if (selected is AnimeSource) {
            return invokeAnime(loaded, selected, method, arguments)
        }
        val source = selected as? Source
            ?: throw MihonHostException("SOURCE_NOT_FOUND", "Unknown source type ${selected.javaClass}")
        return when (method) {
            "filtersManga" -> filterListToBridge(source.getFilterList())
            "getPopularManga" -> runBlocking {
                source.getPopularManga(arguments.intValue("page", 1)).let { page ->
                    page.mangas.forEach { manga -> loaded.mangaCache[cacheKey(source, manga.url)] = manga }
                    mapOf(
                        "mangas" to page.mangas.map { manga -> manga.toBridgeMap() },
                        "hasNextPage" to page.hasNextPage,
                    )
                }
            }
            "getLatestManga" -> runBlocking {
                source.getLatestUpdates(arguments.intValue("page", 1)).let { page ->
                    page.mangas.forEach { manga -> loaded.mangaCache[cacheKey(source, manga.url)] = manga }
                    mapOf(
                        "mangas" to page.mangas.map { manga -> manga.toBridgeMap() },
                        "hasNextPage" to page.hasNextPage,
                    )
                }
            }
            "getSearchManga" -> runBlocking {
                val filters = applyBridgeFilters(
                    source.getFilterList(),
                    arguments.mapList("filterList"),
                )
                source.getSearchManga(
                    arguments.intValue("page", 1),
                    arguments["search"]?.toString().orEmpty(),
                    filters,
                ).let { page ->
                    page.mangas.forEach { manga -> loaded.mangaCache[cacheKey(source, manga.url)] = manga }
                    mapOf(
                        "mangas" to page.mangas.map { manga -> manga.toBridgeMap() },
                        "hasNextPage" to page.hasNextPage,
                    )
                }
            }
            "getDetailsManga" -> runBlocking {
                val input = arguments.requiredMap("mangaData")
                val manga = loaded.mangaCache[cacheKey(source, input.requiredString("url"))]
                    ?: mangaFromBridge(input)
                val update = source.getMangaUpdate(
                    manga = manga,
                    chapters = emptyList(),
                    fetchDetails = true,
                    fetchChapters = false,
                ).manga
                // 详情结果是增量：身份（url）只能来自入参，读 update.url 会踩
                // 未初始化的 lateinit。见 SManga.mergedWithDetails。
                val merged = manga.mergedWithDetails(update)
                loaded.mangaCache[cacheKey(source, merged.url)] = merged
                merged.toBridgeMap()
            }
            // 作品在源站的网页地址（Mihon `HttpSource.getMangaUrl`，默认 = 详情请求
            // 的 URL；源可覆盖）。与桌面 sidecar 的 `getMangaUrl` 同一 wire 名。
            "getMangaUrl" -> {
                val input = arguments.requiredMap("mangaData")
                val manga = loaded.mangaCache[cacheKey(source, input.requiredString("url"))]
                    ?: mangaFromBridge(input)
                (source as? HttpSource)?.getMangaUrl(manga)
                    ?: throw MihonHostException("NOT_IMPLEMENTED", "Source has no web page for this title")
            }
            "getChapterList" -> runBlocking {
                val input = arguments.requiredMap("mangaData")
                val manga = loaded.mangaCache[cacheKey(source, input.requiredString("url"))]
                    ?: mangaFromBridge(input)
                source.getMangaUpdate(
                    manga = manga,
                    chapters = emptyList(),
                    fetchDetails = false,
                    fetchChapters = true,
                ).chapters.onEach { chapter ->
                    loaded.chapterCache[cacheKey(source, chapter.url)] = chapter
                }.map { chapter -> chapter.toBridgeMap() }
            }
            "getPageList" -> runBlocking {
                val input = arguments.requiredMap("chapterData")
                val chapter = loaded.chapterCache[cacheKey(source, input.requiredString("url"))]
                    ?: chapterFromBridge(input)
                source.getPageList(chapter).map { page -> page.toBridgeMap() }
            }
            "preferencesManga", "setPreferenceManga" -> {
                val configurable = source as? ConfigurableSource
                    ?: return emptyList<Map<String, Any?>>()
                MihonPreferenceBridge.applyAndRead(
                    app,
                    configurable,
                    arguments.mapList("preferences"),
                )
            }
            else -> throw MihonHostException("NOT_IMPLEMENTED", "Unsupported Mihon invoke method")
        }
    }

    /** Aniyomi 调用面：与漫画分支一一对应，wire 名与桌面 sidecar `MihonInvoker` 一致。 */
    private fun invokeAnime(
        loaded: LoadedMihonExtension,
        source: AnimeSource,
        method: String,
        arguments: Map<String, Any?>,
    ): Any? {
        val catalogue = source as? AnimeCatalogueSource
            ?: throw MihonHostException("UNSUPPORTED_SOURCE", "Anime source is not a catalogue source")
        fun page(page: eu.kanade.tachiyomi.animesource.model.AnimesPage): Map<String, Any?> {
            page.animes.forEach { anime -> loaded.animeCache[cacheKey(source, anime.url)] = anime }
            return mapOf(
                "animes" to page.animes.map { anime -> anime.toBridgeMap() },
                "hasNextPage" to page.hasNextPage,
            )
        }
        return when (method) {
            "filtersAnime" -> animeFilterListToBridge(catalogue.getFilterList())
            "getPopularAnime" -> runBlocking { page(catalogue.getPopularAnime(arguments.intValue("page", 1))) }
            "getLatestAnime" -> runBlocking { page(catalogue.getLatestUpdates(arguments.intValue("page", 1))) }
            "getSearchAnime" -> runBlocking {
                val filters = applyBridgeAnimeFilters(
                    catalogue.getFilterList(),
                    arguments.mapList("filterList"),
                )
                page(
                    catalogue.getSearchAnime(
                        arguments.intValue("page", 1),
                        arguments["search"]?.toString().orEmpty(),
                        filters,
                    ),
                )
            }
            "getDetailsAnime" -> runBlocking {
                val input = arguments.requiredMap("animeData")
                val anime = loaded.animeCache[cacheKey(source, input.requiredString("url"))]
                    ?: animeFromBridge(input)
                // 同漫画：详情是增量，身份只能来自入参（见 SAnime.mergedWithDetails）。
                val merged = anime.mergedWithDetails(catalogue.getAnimeDetails(anime))
                loaded.animeCache[cacheKey(source, merged.url)] = merged
                merged.toBridgeMap()
            }
            "getAnimeUrl" -> {
                val input = arguments.requiredMap("animeData")
                val anime = loaded.animeCache[cacheKey(source, input.requiredString("url"))]
                    ?: animeFromBridge(input)
                (catalogue as? AnimeHttpSource)?.getAnimeUrl(anime)
                    ?: throw MihonHostException("NOT_IMPLEMENTED", "Source has no web page for this title")
            }
            "getEpisodeList" -> runBlocking {
                val input = arguments.requiredMap("animeData")
                val anime = loaded.animeCache[cacheKey(source, input.requiredString("url"))]
                    ?: animeFromBridge(input)
                catalogue.getEpisodeList(anime).onEach { episode ->
                    loaded.episodeCache[cacheKey(source, episode.url)] = episode
                }.map { episode -> episode.toBridgeMap() }
            }
            "getVideoList" -> runBlocking {
                val input = arguments.requiredMap("episodeData")
                val episode = loaded.episodeCache[cacheKey(source, input.requiredString("url"))]
                    ?: episodeFromBridge(input)
                // 两代扩展共用的宿主取流器（与桌面 sidecar 同一份源码）：Hoster 展开、
                // `resolveVideo`、lib 14 的 `getVideoUrl`，解析不出的候选不过通道。
                AnimeVideoLoader.loadVideos(catalogue, episode).map { video -> video.toBridgeMap() }
            }
            "preferencesAnime", "setPreferenceAnime" -> {
                val configurable = source as? ConfigurableAnimeSource
                    ?: return emptyList<Map<String, Any?>>()
                MihonPreferenceBridge.applyAndRead(
                    app,
                    configurable,
                    arguments.mapList("preferences"),
                )
            }
            else -> throw MihonHostException("NOT_IMPLEMENTED", "Unsupported Mihon anime invoke method")
        }
    }

    private fun sourceDescriptor(source: Any): Map<String, Any?> = when (source) {
        is Source -> mapOf(
            "id" to source.id.toString(),
            "name" to source.name,
            "lang" to source.lang,
            "baseUrl" to ((source as? HttpSource)?.getHomeUrl().orEmpty()),
        )
        is AnimeSource -> mapOf(
            "id" to source.id.toString(),
            "name" to source.name,
            "lang" to source.lang,
            "baseUrl" to ((source as? AnimeHttpSource)?.baseUrl.orEmpty()),
        )
        else -> throw MihonHostException("SOURCE_NOT_FOUND", "Unknown source type ${source.javaClass}")
    }

    /** 漫画 / 视频 HTTP 源共有的取图三件套：客户端、默认头、站点根。 */
    private fun httpSurface(source: Any): Triple<okhttp3.OkHttpClient, okhttp3.Headers, String> =
        when (source) {
            is HttpSource -> Triple(source.client, source.headers, source.baseUrl)
            is AnimeHttpSource -> Triple(source.client, source.headers, source.baseUrl)
            else -> throw MihonHostException("UNSUPPORTED_SOURCE", "Source cannot fetch HTTP images")
        }

    private fun fetchPageImage(arguments: Map<String, Any?>): ByteArray {
        val loaded = loader.load(arguments.requiredString("packageName"))
        val source = loaded.source(arguments.requiredString("sourceId"))
        applyPreferences(source, arguments)
        val value = arguments.requiredMap("page")
        val page = Page(
            index = (value["index"] as? Number)?.toInt() ?: 0,
            url = value["url"]?.toString().orEmpty(),
            imageUrl = value["imageUrl"]?.toString(),
        )
        val http = source as? HttpSource
            ?: throw MihonHostException("UNSUPPORTED_SOURCE", "Source cannot fetch HTTP images")
        return runBlocking {
            http.getImage(page).use { response ->
                if (!response.isSuccessful) {
                    throw MihonHostException("IMAGE_HTTP", "Source image request failed")
                }
                response.body.bytes()
            }
        }
    }

    private fun fetchSourceImage(arguments: Map<String, Any?>): ByteArray {
        val loaded = loader.load(arguments.requiredString("packageName"))
        val source = loaded.source(arguments.requiredString("sourceId"))
        applyPreferences(source, arguments)
        val (client, headers, _) = httpSurface(source)
        val request = Request.Builder()
            .url(arguments.requiredString("url"))
            .headers(headers)
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw MihonHostException("IMAGE_HTTP", "Source image request failed")
            }
            return response.body.bytes()
        }
    }

    private fun clearSourceData(arguments: Map<String, Any?>) {
        val loaded = loader.load(arguments.requiredString("packageName"))
        val source = loaded.source(arguments.requiredString("sourceId"))
        if (source is ConfigurableSource) source.getSourcePreferences().edit().clear().commit()
        if (source is ConfigurableAnimeSource) source.getSourcePreferences().edit().clear().commit()
        if (source is HttpSource || source is AnimeHttpSource) {
            val network = Injekt.get<NetworkHelper>()
            val (_, _, baseUrl) = httpSurface(source)
            runCatching { network.cookieJar.remove(baseUrl.toHttpUrl()) }
        }
        val prefix = "${sourceId(source)}:"
        loaded.mangaCache.keys.removeAll { key -> key.startsWith(prefix) }
        loaded.chapterCache.keys.removeAll { key -> key.startsWith(prefix) }
        loaded.animeCache.keys.removeAll { key -> key.startsWith(prefix) }
        loaded.episodeCache.keys.removeAll { key -> key.startsWith(prefix) }
    }

    private fun sourceFromPreferences(
        loaded: LoadedMihonExtension,
        arguments: Map<String, Any?>,
    ): Any {
        val context = arguments.mapList("preferences")
            .firstOrNull { item -> item["key"] == "__mangatan_bridge_context__" }
        val sourceId = context?.get("sourceId")?.toString()
            ?: throw MihonHostException("SOURCE_NOT_FOUND", "Mihon source context is missing")
        return loaded.source(sourceId)
    }

    private fun applyPreferences(source: Any, arguments: Map<String, Any?>) {
        when (source) {
            is ConfigurableSource ->
                MihonPreferenceBridge.apply(app, source, arguments.mapList("preferences"))
            is ConfigurableAnimeSource ->
                MihonPreferenceBridge.apply(app, source, arguments.mapList("preferences"))
            else -> Unit
        }
    }

    private fun sourceId(source: Any): Long = when (source) {
        is Source -> source.id
        is AnimeSource -> source.id
        else -> throw MihonHostException("SOURCE_NOT_FOUND", "Unknown source type ${source.javaClass}")
    }

    private fun LoadedMihonExtension.source(sourceId: String): Any =
        sources.firstOrNull { source -> sourceId(source).toString() == sourceId }
            ?: throw MihonHostException("SOURCE_NOT_FOUND", "Mihon source is unavailable")

    private fun cacheKey(source: Any, url: String): String = "${sourceId(source)}:$url"

    private fun fileArgument(call: MethodCall, key: String): File =
        File(stringArgument(call, key))

    private fun stringArgument(call: MethodCall, key: String): String =
        call.argument<String>(key)?.takeIf { value -> value.isNotEmpty() }
            ?: throw IllegalArgumentException("$key is required")

    @Suppress("UNCHECKED_CAST")
    private fun MethodCall.argumentsMap(): Map<String, Any?> =
        arguments as? Map<String, Any?>
            ?: throw IllegalArgumentException("Method arguments must be a map")

    @Suppress("UNCHECKED_CAST")
    private fun Map<String, Any?>.requiredMap(key: String): Map<String, Any?> =
        this[key] as? Map<String, Any?>
            ?: throw IllegalArgumentException("$key must be a map")

    private fun Map<String, Any?>.requiredString(key: String): String =
        this[key]?.toString()?.takeIf { value -> value.isNotEmpty() }
            ?: throw IllegalArgumentException("$key is required")

    private fun Map<String, Any?>.intValue(key: String, fallback: Int): Int =
        (this[key] as? Number)?.toInt() ?: fallback

    private fun Map<String, Any?>.mapList(key: String): List<Map<String, Any?>> =
        (this[key] as? List<*>)
            .orEmpty()
            .mapNotNull { value ->
                @Suppress("UNCHECKED_CAST")
                value as? Map<String, Any?>
            }

    /**
     * 把失败归到具体操作上。
     *
     * 漫画详情页会连着发 `getDetailsManga` 和 `getChapterList` 两次
     * `invoke`，两者失败时原本回的 code/message 完全一样，用户和日志
     * 都分不出断在哪一步。内层 `method` 必须跟着错误一起回去。
     */
    private fun describeOperation(call: MethodCall): String {
        val inner = (call.arguments as? Map<*, *>)?.get("method")?.toString()
        return if (inner.isNullOrEmpty()) call.method else "${call.method}/$inner"
    }

    companion object {
        private const val MAX_APK_BYTES = 100L * 1024L * 1024L
        private const val TAG = "MihonChannel"
    }
}
