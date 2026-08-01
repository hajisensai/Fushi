package app.hibiki.reader.mihon

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
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
) {
    fun toMap(): Map<String, Any> = mapOf(
        "packageName" to packageName,
        "name" to name,
        "versionCode" to versionCode,
        "versionName" to versionName,
        "libVersion" to libVersion,
        "signerSha256" to signerSha256,
        "sourceClasses" to sourceClasses,
    )
}

internal class LoadedMihonExtension(
    val inspection: MihonExtensionInspection,
    val sources: List<Source>,
    val classLoader: ClassLoader,
) {
    val mangaCache = ConcurrentHashMap<String, SManga>()
    val chapterCache = ConcurrentHashMap<String, SChapter>()
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
        if (packageInfo.reqFeatures.orEmpty().none { feature -> feature.name == EXTENSION_FEATURE }) {
            throw MihonHostException("NOT_EXTENSION", "APK does not declare tachiyomi.extension")
        }
        val appInfo = packageInfo.applicationInfo
            ?: throw MihonHostException("INVALID_APK", "APK has no application metadata")
        appInfo.sourceDir = file.absolutePath
        appInfo.publicSourceDir = file.absolutePath
        val metadata = appInfo.metaData
            ?: throw MihonHostException("INVALID_APK", "Extension metadata is missing")
        val sourceClasses = metadata.getString(METADATA_SOURCE_CLASS)
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
        if (libVersion != 1.4 && libVersion != 1.6) {
            throw MihonHostException(
                "UNSUPPORTED_LIB",
                "Only Mihon extension-lib 1.4 and 1.6 are supported",
            )
        }
        val signatures = signatures(packageInfo)
        if (signatures.isEmpty()) {
            throw MihonHostException("UNSIGNED", "Extension APK is not signed")
        }
        val label = metadata.getString(METADATA_NAME)
            ?: packageManager.getApplicationLabel(appInfo)
                .toString()
                .substringAfter("Tachiyomi: ")
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
            libVersion = if (libVersion == 1.4) "1.4" else "1.6",
            signerSha256 = signatures.last(),
            sourceClasses = sourceClasses,
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
                throw MihonHostException(
                    "LOAD_FAILED",
                    "Unable to instantiate extension source $className",
                    error,
                )
            }
            when (instance) {
                is Source -> listOf(instance)
                is SourceFactory -> instance.createSources()
                else -> throw MihonHostException(
                    "LOAD_FAILED",
                    "Extension class does not implement Source or SourceFactory",
                )
            }
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
        private const val EXTENSION_FEATURE = "tachiyomi.extension"
        private const val METADATA_SOURCE_CLASS = "tachiyomi.extension.class"
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
