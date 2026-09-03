package eu.kanade.tachiyomi.network

import android.content.Context
import android.webkit.WebSettings
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import okhttp3.Cache
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Small Android host implementation of the NetworkHelper ABI used by Mihon
 * extensions. Extension-provided interceptors are retained by client builders.
 */
class NetworkHelper(context: Context) {
    val cookieJar = AndroidCookieJar()

    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .cookieJar(cookieJar)
            .addInterceptor(UncaughtExceptionInterceptor())
            .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))
            .addInterceptor(CloudflareInterceptor(context, ::defaultUserAgentProvider))
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(45, TimeUnit.SECONDS)
            .callTimeout(2, TimeUnit.MINUTES)
            .cache(Cache(File(context.cacheDir, "mihon_network"), 16L * 1024L * 1024L))
            .build()
    }

    @Deprecated("The regular client is used on the Hibiki host")
    val cloudflareClient: OkHttpClient
        get() = client

    // Cloudflare binds cf_clearance to the solving User-Agent, and the WebView
    // that solves the challenge reports the platform's browser UA. Seeding the
    // OkHttp UA from the same WebView default keeps the two in lockstep and
    // makes ordinary requests look like a browser (falling back to a generic
    // string only if WebView is somehow unavailable).
    private var userAgent: String = runCatching { WebSettings.getDefaultUserAgent(context) }
        .getOrNull()
        ?.takeIf { it.isNotBlank() }
        ?: System.getProperty("http.agent").orEmpty()
            .ifBlank { "Hibiki Mihon Extension Host" }

    fun setUA(value: String) {
        userAgent = value
    }

    fun defaultUserAgentProvider(): String = userAgent
}
