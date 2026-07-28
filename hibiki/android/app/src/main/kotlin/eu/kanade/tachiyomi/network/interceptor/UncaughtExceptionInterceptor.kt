package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Compatibility interceptor required by modern Mihon extension-core sources.
 *
 * Hibiki converts uncaught failures into stable MethodChannel error codes at
 * the runtime boundary, so this layer intentionally preserves the exception.
 */
class UncaughtExceptionInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response =
        chain.proceed(chain.request())
}
