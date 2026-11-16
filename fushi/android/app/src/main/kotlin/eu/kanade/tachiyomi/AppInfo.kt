package eu.kanade.tachiyomi

import app.fushi.reader.BuildConfig

/**
 * Host API that Mihon extensions link against (extension-lib 1.3+, image MIME
 * types since 1.5). Upstream Mihon declares it in its **app** module, not in
 * `source-api`, so `prepareMihonSourceApi` never brings it in; the Android host
 * has to declare it itself (BUG-4738). Extensions compile it `compileOnly` and
 * resolve `AppInfo.INSTANCE.getVersionName()` etc. by name at runtime, so the
 * shape must stay a Kotlin `object` with instance methods of exactly these
 * signatures, and R8 must keep it (proguard-rules.pro, Mihon host ABI block).
 *
 * Version values differ between forks; extensions only use them for
 * User-Agent strings.
 */
object AppInfo {
    fun getVersionCode(): Int = BuildConfig.VERSION_CODE

    fun getVersionName(): String = BuildConfig.VERSION_NAME

    /**
     * Page formats the manga reader can display. Pages are rendered by the
     * system WebView and sniffed by `manga_page_provider.dart`
     * (`mangaImageContentType`), which recognises exactly these five.
     */
    fun getSupportedImageMimeTypes(): List<String> = SUPPORTED_IMAGE_MIME_TYPES

    private val SUPPORTED_IMAGE_MIME_TYPES: List<String> = listOf(
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp",
        "image/avif",
    )
}
