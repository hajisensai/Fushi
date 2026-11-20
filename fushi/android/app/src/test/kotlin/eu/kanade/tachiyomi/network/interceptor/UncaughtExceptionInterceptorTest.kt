package eu.kanade.tachiyomi.network.interceptor

import eu.kanade.tachiyomi.network.await
import kotlinx.coroutines.runBlocking
import okhttp3.Dispatcher
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * BUG-4951：扩展拦截器（例如把 StreamResetException 包成 PlainTextException 的那类）
 * 在 `Call.await()` 的异步路径上抛非 IOException 时，OkHttp 的 AsyncCall 先回调
 * onFailure、再把原异常在调度线程上重抛；Android 上那就是未捕获异常，整个进程被杀。
 * 宿主最外层的 UncaughtExceptionInterceptor 必须把它收成 IOException。
 */
class UncaughtExceptionInterceptorTest {
    private class PlainTextException(message: String) : RuntimeException(message)

    @Test
    fun extensionRuntimeExceptionOnAsyncCallDoesNotEscapeToDispatcherThread() {
        val uncaught = Collections.synchronizedList(mutableListOf<Throwable>())
        val executor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "okhttp-dispatcher-test").apply {
                setUncaughtExceptionHandler { _, error -> uncaught += error }
            }
        }
        val extensionFailure = PlainTextException("未知網路錯誤 (stream was reset: CANCEL)")
        val client = OkHttpClient.Builder()
            .dispatcher(Dispatcher(executor))
            .addInterceptor(UncaughtExceptionInterceptor())
            // 扩展 client 是 network.client.newBuilder().addInterceptor(...)，排在宿主拦截器之后。
            .addInterceptor(Interceptor { throw extensionFailure })
            .build()

        val error = assertFailsWith<IOException> {
            runBlocking {
                client.newCall(Request.Builder().url("http://127.0.0.1:9/page.jpg").build()).await()
            }
        }

        executor.shutdown()
        assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS))
        assertEquals(emptyList(), uncaught.toList(), "调度线程不得出现未捕获异常（Android 上即进程崩溃）")
        // 原因链保留：通道错误信息与 Cloudflare 判定都沿 cause 链读。
        assertSame(extensionFailure, generateSequence<Throwable>(error) { it.cause }.first { it is PlainTextException })
    }

    @Test
    fun ioExceptionsPassThroughUnwrapped() {
        val failure = IOException("timeout")
        val client = OkHttpClient.Builder()
            .addInterceptor(UncaughtExceptionInterceptor())
            .addInterceptor(Interceptor { throw failure })
            .build()

        val error = assertFailsWith<IOException> {
            client.newCall(Request.Builder().url("http://127.0.0.1:9/page.jpg").build()).execute()
        }

        assertSame(failure, error)
    }
}
