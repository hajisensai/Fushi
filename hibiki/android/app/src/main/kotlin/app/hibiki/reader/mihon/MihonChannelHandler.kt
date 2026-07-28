package app.hibiki.reader.mihon

import android.app.Application
import android.os.Handler
import android.os.Looper
import eu.kanade.tachiyomi.network.NetworkHelper
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
            "app.hibiki.reader/mihon",
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
                    mainHandler.post { result.success(value) }
                } catch (error: MihonHostException) {
                    mainHandler.post { result.error(error.code, error.message, null) }
                } catch (error: IllegalArgumentException) {
                    mainHandler.post {
                        result.error("INVALID_ARGUMENT", error.message ?: "Invalid argument", null)
                    }
                } catch (_: Throwable) {
                    mainHandler.post {
                        result.error("RUNTIME_FAILURE", "Mihon extension operation failed", null)
                    }
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

    private fun handle(call: MethodCall): Any? = when (call.method) {
        "capabilities" -> mapOf(
            "hibikiMihonBridge" to 1,
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
        "invalidateExtension" -> {
            loader.invalidate(stringArgument(call, "packageName"))
            null
        }
        "dispose" -> {
            loader.clear()
            null
        }
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
        if (method == "sourcesManga") {
            return loaded.sources.map { source ->
                mapOf(
                    "id" to source.id.toString(),
                    "name" to source.name,
                    "lang" to source.lang,
                    "baseUrl" to ((source as? HttpSource)?.getHomeUrl().orEmpty()),
                )
            }
        }
        val source = sourceFromPreferences(loaded, arguments)
        applyPreferences(source, arguments)
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
                source.getMangaUpdate(
                    manga = manga,
                    chapters = emptyList(),
                    fetchDetails = true,
                    fetchChapters = false,
                ).manga.also { result ->
                    loaded.mangaCache[cacheKey(source, result.url)] = result
                }.toBridgeMap()
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
        val http = source as? HttpSource
            ?: throw MihonHostException("UNSUPPORTED_SOURCE", "Source cannot fetch HTTP images")
        val request = Request.Builder()
            .url(arguments.requiredString("url"))
            .headers(http.headers)
            .build()
        http.client.newCall(request).execute().use { response ->
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
        if (source is HttpSource) {
            val network = Injekt.get<NetworkHelper>()
            runCatching { network.cookieJar.remove(source.baseUrl.toHttpUrl()) }
        }
        loaded.mangaCache.keys.removeAll { key -> key.startsWith("${source.id}:") }
        loaded.chapterCache.keys.removeAll { key -> key.startsWith("${source.id}:") }
    }

    private fun sourceFromPreferences(
        loaded: LoadedMihonExtension,
        arguments: Map<String, Any?>,
    ): Source {
        val context = arguments.mapList("preferences")
            .firstOrNull { item -> item["key"] == "__mangatan_bridge_context__" }
        val sourceId = context?.get("sourceId")?.toString()
            ?: throw MihonHostException("SOURCE_NOT_FOUND", "Mihon source context is missing")
        return loaded.source(sourceId)
    }

    private fun applyPreferences(source: Source, arguments: Map<String, Any?>) {
        if (source is ConfigurableSource) {
            MihonPreferenceBridge.apply(app, source, arguments.mapList("preferences"))
        }
    }

    private fun LoadedMihonExtension.source(sourceId: String): Source =
        sources.firstOrNull { source -> source.id.toString() == sourceId }
            ?: throw MihonHostException("SOURCE_NOT_FOUND", "Mihon source is unavailable")

    private fun cacheKey(source: Source, url: String): String = "${source.id}:$url"

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

    companion object {
        private const val MAX_APK_BYTES = 100L * 1024L * 1024L
    }
}
