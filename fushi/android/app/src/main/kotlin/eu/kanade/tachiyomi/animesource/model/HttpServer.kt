package eu.kanade.tachiyomi.animesource.model

/**
 * Android variant of the extensions-lib 17 `HttpServer` (same FQCN as the desktop
 * sidecar's, `third_party/m_extension_server/overlay/.../model/HttpServer.kt`).
 *
 * The lib's server extends NanoHTTPD, which this app does not ship, so the Android
 * host cannot run an extension-provided local server: `AnimeHttpSource.
 * createHttpServer()` still links (it returns this type), but `AnimeVideoLoader` is
 * called without a `localServer`, so a video on [PLACEHOLDER_URL] is reported as
 * unplayable instead of handing the player an unreachable `http://localhost:1` url.
 * An extension subclass of this type only fails when instantiated, which the
 * Android host never does.
 *
 * @since extensions-lib 17
 */
open class HttpServer {
    /** Never running on Android; see the class comment. */
    val url: String
        get() = throw UnsupportedOperationException("Extension local servers are not available on Android")

    companion object {
        const val PLACEHOLDER_URL = "http://localhost:1"
    }
}
