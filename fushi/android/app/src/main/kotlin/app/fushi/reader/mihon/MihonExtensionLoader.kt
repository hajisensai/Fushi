package app.fushi.reader.mihon

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.AnimeSourceFactory
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

internal data class MihonExtensionInspection(
    val packageName: String,
    val name: String,
    val versionCode: Long,
    val versionName: String,
    val libVersion: String,
    val signerSha256: String,
    val sourceClasses: List<String>,
    /** `manga`（Mihon）| `anime`（Aniyomi），由 manifest feature 判定。 */
    val kind: String,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "packageName" to packageName,
        "name" to name,
        "versionCode" to versionCode,
        "versionName" to versionName,
        "libVersion" to libVersion,
        "signerSha256" to signerSha256,
        "sourceClasses" to sourceClasses,
        "kind" to kind,
    )
}

/**
 * 一个已加载的扩展。[sources] 里是 `Source`（漫画）或 `AnimeSource`（视频），
 * 同一个 APK 只会有其中一种——两个生态的 manifest feature 互斥。
 */
internal class LoadedMihonExtension(
    val inspection: MihonExtensionInspection,
    val sources: List<Any>,
    val classLoader: ClassLoader,
) {
    val mangaCache = ConcurrentHashMap<String, SManga>()
    val chapterCache = ConcurrentHashMap<String, SChapter>()
    val animeCache = ConcurrentHashMap<String, SAnime>()
    val episodeCache = ConcurrentHashMap<String, SEpisode>()
}

internal class MihonExtensionLoader(private val context: Context) {
    private val packageManager = context.packageManager
    private val cache = ConcurrentHashMap<String, LoadedMihonExtension>()
    private val extensionsDir = File(context.filesDir, "exts").apply { mkdirs() }

    fun extensionFile(packageName: String): File {
        require(PACKAGE_NAME.matches(packageName)) { "Invalid extension package name" }
        return File(extensionsDir, "$packageName.ext")
    }

    fun inspect(file: File): MihonExtensionInspection {
        require(file.isFile) { "Extension file does not exist" }
        val packageInfo = packageInfo(file)
            ?: throw MihonHostException("INVALID_APK", "Unable to parse extension APK")
        val features = packageInfo.reqFeatures.orEmpty().mapNotNull { feature -> feature.name }
        val kind = when {
            EXTENSION_FEATURE in features -> KIND_MANGA
            ANIME_EXTENSION_FEATURE in features -> KIND_ANIME
            else -> throw MihonHostException(
                "NOT_EXTENSION",
                "APK does not declare tachiyomi.extension or tachiyomi.animeextension",
            )
        }
        val appInfo = packageInfo.applicationInfo
            ?: throw MihonHostException("INVALID_APK", "APK has no application metadata")
        appInfo.sourceDir = file.absolutePath
        appInfo.publicSourceDir = file.absolutePath
        val metadata = appInfo.metaData
            ?: throw MihonHostException("INVALID_APK", "Extension metadata is missing")
        val classMetadataKey = if (kind == KIND_ANIME) METADATA_ANIME_SOURCE_CLASS else METADATA_SOURCE_CLASS
        val sourceClasses = metadata.getString(classMetadataKey)
            ?.split(";")
            ?.map { name ->
                val trimmed = name.trim()
                if (trimmed.startsWith(".")) packageInfo.packageName + trimmed else trimmed
            }
            ?.filter { name -> name.isNotEmpty() }
            .orEmpty()
        if (sourceClasses.isEmpty()) {
            throw MihonHostException("INVALID_APK", "Extension source class is missing")
        }
        val versionName = packageInfo.versionName.orEmpty()
        if (versionName.isEmpty()) {
            throw MihonHostException("INVALID_APK", "Extension versionName is missing")
        }
        val libVersion = metadata.getFloat(METADATA_EXTENSION_LIB)
            .takeUnless { version -> version == 0.0f }
            ?.toString()
            ?.toDoubleOrNull()
            ?: versionName.substringBeforeLast('.').toDoubleOrNull()
        // 视频扩展收 Aniyomi extensions-lib 14 / 15 / 16：编进宿主的 `animesource` ABI
        // （third_party/m_extension_server/overlay）是 lib 14 与 lib 16 的并集——老构造
        // `Video(url, quality, videoUrl, …)` + `getVideoList(episode)` 与新 data class
        // `Video(videoUrl, videoTitle, …)` + Hoster API 并存。yuzono / Anikku 的 APK
        // versionName 写 14、dex 却按 lib 16 面编译，版本标签本身从不决定能不能播。
        val libVersionLabel = supportedLibVersionLabel(kind, libVersion)
            ?: throw MihonHostException(
                "UNSUPPORTED_LIB",
                if (kind == KIND_ANIME) {
                    "Only Aniyomi extension-lib 14 to 16 is supported"
                } else {
                    "Only Mihon extension-lib 1.4 and 1.6 are supported"
                },
            )
        val signatures = signatures(packageInfo)
        if (signatures.isEmpty()) {
            throw MihonHostException("UNSIGNED", "Extension APK is not signed")
        }
        val label = metadata.getString(METADATA_NAME)
            ?: packageManager.getApplicationLabel(appInfo)
                .toString()
                .substringAfter("Tachiyomi: ")
                .substringAfter("Aniyomi: ")
        return MihonExtensionInspection(
            packageName = packageInfo.packageName,
            name = label,
            versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                packageInfo.versionCode.toLong()
            },
            versionName = versionName,
            libVersion = libVersionLabel,
            signerSha256 = signatures.last(),
            sourceClasses = sourceClasses,
            kind = kind,
        )
    }

    fun load(packageName: String): LoadedMihonExtension =
        cache[packageName] ?: synchronized(cache) {
            cache[packageName] ?: loadFile(extensionFile(packageName)).also { loaded ->
                if (loaded.inspection.packageName != packageName) {
                    throw MihonHostException(
                        "PACKAGE_MISMATCH",
                        "Stored extension package name does not match",
                    )
                }
                cache[packageName] = loaded
            }
        }

    fun validate(file: File): LoadedMihonExtension = loadFile(file)

    fun invalidate(packageName: String) {
        cache.remove(packageName)
    }

    fun clear() {
        cache.clear()
    }

    private fun loadFile(file: File): LoadedMihonExtension {
        val inspection = inspect(file)
        val classLoader = ChildFirstPathClassLoader(file.absolutePath, context.classLoader)
        val sources = inspection.sourceClasses.flatMap { className ->
            val instance = try {
                Class.forName(className, true, classLoader)
                    .getDeclaredConstructor()
                    .newInstance()
            } catch (error: Throwable) {
                // 把不透明的实例化失败变成可诊断的错误：附上链式根因（通常是
                // NoClassDefFoundError / ClassNotFoundException，指明扩展需要而
                // host 未提供的类），否则用户只看到「无法安装」而无从判断原因。
                // reflective 调用会把真异常包在 InvocationTargetException 里，故
                // 走到最深一层 cause。
                throw MihonHostException(
                    "LOAD_FAILED",
                    "Unable to instantiate extension source $className: " +
                        describeCauseChain(error),
                    error,
                )
            }
            when (instance) {
                is Source -> listOf<Any>(instance)
                is SourceFactory -> instance.createSources()
                is AnimeSource -> listOf<Any>(instance)
                is AnimeSourceFactory -> instance.createSources()
                else -> throw MihonHostException(
                    "LOAD_FAILED",
                    "Extension class does not implement Source, SourceFactory, " +
                        "AnimeSource or AnimeSourceFactory",
                )
            }
        }
        // 生态与实例类型必须对上：声明 anime feature 却给出 `Source` 的 APK 不是
        // 任何一个生态会产出的形状，落进去会让上层按错误的调用面去打它。
        val mismatched = sources.any { source ->
            when (inspection.kind) {
                KIND_ANIME -> source !is AnimeSource
                else -> source !is Source
            }
        }
        if (mismatched) {
            throw MihonHostException(
                "LOAD_FAILED",
                "Extension sources do not match its declared kind ${inspection.kind}",
            )
        }
        if (sources.isEmpty()) {
            throw MihonHostException("NO_SOURCES", "Extension did not expose any sources")
        }
        return LoadedMihonExtension(inspection, sources, classLoader)
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(file: File): PackageInfo? = packageManager.getPackageArchiveInfo(
        file.absolutePath,
        PackageManager.GET_CONFIGURATIONS or
            PackageManager.GET_META_DATA or
            PackageManager.GET_SIGNATURES or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                0
            },
    )

    @Suppress("DEPRECATION")
    private fun signatures(packageInfo: PackageInfo): List<String> {
        val values = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.let { info ->
                if (info.hasMultipleSigners()) {
                    info.apkContentsSigners
                } else {
                    info.signingCertificateHistory
                }
            }
        } else {
            packageInfo.signatures
        }.orEmpty()
        return values.map { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte) }
        }
    }

    companion object {
        const val KIND_MANGA = "manga"
        const val KIND_ANIME = "anime"
        private const val EXTENSION_FEATURE = "tachiyomi.extension"
        private const val ANIME_EXTENSION_FEATURE = "tachiyomi.animeextension"
        private const val METADATA_SOURCE_CLASS = "tachiyomi.extension.class"
        private const val METADATA_ANIME_SOURCE_CLASS = "tachiyomi.animeextension.class"

        /** 与桌面 sidecar `InspectHandler.supportedLibVersionLabel` 同一张表。 */
        internal fun supportedLibVersionLabel(kind: String, libVersion: Double?): String? =
            when (kind) {
                KIND_ANIME -> when (libVersion) {
                    14.0 -> "14"
                    15.0 -> "15"
                    16.0 -> "16"
                    else -> null
                }
                else -> when (libVersion) {
                    1.4 -> "1.4"
                    1.6 -> "1.6"
                    else -> null
                }
            }
        private const val METADATA_EXTENSION_LIB = "tachiyomix.extensionLib"
        private const val METADATA_NAME = "tachiyomix.name"
        private val PACKAGE_NAME = Regex("""[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+""")
    }
}

internal class MihonHostException(
    val code: String,
    override val message: String,
    cause: Throwable? = null,
) : Exception(message, cause)
