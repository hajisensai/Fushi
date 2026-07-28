package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Host compatibility boundary for extension-core.
 *
 * WebView-based Cloudflare challenge solving is outside the V1 native host;
 * ordinary requests pass through and challenge-dependent sources are reported
 * as incompatible instead of affecting other installed sources.
 */
class CloudflareInterceptor : Interceptor {
    @Synchronized
    override fun intercept(chain: Interceptor.Chain): Response =
        chain.proceed(chain.request())
}
