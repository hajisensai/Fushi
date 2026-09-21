package eu.kanade.tachiyomi.network.interceptor

import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * `rateLimit(permits, period: Duration)` is what extensions-lib 16 sources call; `Duration` is a
 * value class so the JVM name is mangled (`rateLimit-SxA4cEA`). The legacy TimeUnit overload must
 * stay next to it for lib 14 sources.
 */
class RateLimitInterceptorTest {
    private val methods =
        Class.forName("eu.kanade.tachiyomi.network.interceptor.RateLimitInterceptorKt").declaredMethods

    @Test
    fun exposesDurationDefaultAbiUsedByCurrentExtensions() {
        assertTrue(methods.any { it.name == "rateLimit-SxA4cEA\$default" && it.parameterCount == 5 })
    }

    @Test
    fun keepsTheLegacyTimeUnitAbi() {
        assertTrue(methods.any { it.name == "rateLimit\$default" && it.parameterCount == 6 })
    }
}
