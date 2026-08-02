package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Compatibility interceptor expected by modern extension-core sources.
 *
 * Desktop requests already surface failures through the server's request
 * boundary, so this interceptor intentionally preserves OkHttp's exception.
 */
class UncaughtExceptionInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response = chain.proceed(chain.request())
}
