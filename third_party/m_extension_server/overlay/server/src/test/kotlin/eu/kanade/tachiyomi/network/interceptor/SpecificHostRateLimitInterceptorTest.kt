package eu.kanade.tachiyomi.network.interceptor

import kotlin.test.Test
import kotlin.test.assertTrue

class SpecificHostRateLimitInterceptorTest {
    private val methods =
        Class.forName("eu.kanade.tachiyomi.network.interceptor.SpecificHostRateLimitInterceptorKt").declaredMethods

    @Test
    fun exportsTheDurationAbiUsedByCurrentExtensions() {
        assertTrue(methods.any { it.name == "rateLimitHost-Wn2Vu4Y" && it.parameterCount == 4 })
        assertTrue(methods.any { it.name == "rateLimitHost-Wn2Vu4Y\$default" && it.parameterCount == 6 })
    }

    @Test
    fun keepsTheLegacyTimeUnitAbi() {
        assertTrue(methods.any { it.name == "rateLimitHost\$default" && it.parameterCount == 7 })
    }
}
