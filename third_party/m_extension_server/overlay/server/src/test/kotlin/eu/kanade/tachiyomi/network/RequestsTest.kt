package eu.kanade.tachiyomi.network

import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import kotlin.coroutines.Continuation
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Extensions built against extensions-lib 16 link to `RequestsKt.get$default(...)` /
 * `post$default(...)` -- the synthetic default-argument bridges the Kotlin compiler emits for the
 * suspending `OkHttpClient.get` / `post` helpers. The JVM descriptors are pinned by reflection
 * because a NoSuchMethodError here surfaces only at runtime, as BRIDGE_HTTP_500 (measured on
 * AnimeKai's episode list, 2026-09-19).
 */
class RequestsTest {
    private val methods = Class.forName("eu.kanade.tachiyomi.network.RequestsKt").declaredMethods

    @Test
    fun exportsTheSuspendGetAbiUsedByCurrentExtensions() {
        // (OkHttpClient, String, Headers, CacheControl, Continuation, int mask, Object marker)
        assertTrue(
            methods.any {
                it.name == "get\$default" &&
                    it.parameterCount == 7 &&
                    it.parameterTypes[0] == OkHttpClient::class.java &&
                    it.parameterTypes[1] == String::class.java &&
                    it.parameterTypes[4] == Continuation::class.java
            },
        )
        assertTrue(
            methods.any {
                it.name == "get\$default" &&
                    it.parameterCount == 7 &&
                    it.parameterTypes[1] == HttpUrl::class.java &&
                    it.parameterTypes[4] == Continuation::class.java
            },
        )
        assertTrue(methods.any { it.name == "get" && it.parameterCount == 5 })
    }

    @Test
    fun exportsTheSuspendPostAbiUsedByCurrentExtensions() {
        assertTrue(methods.any { it.name == "post" && it.parameterCount == 6 })
        assertTrue(methods.any { it.name == "post\$default" && it.parameterCount == 8 })
    }
}
