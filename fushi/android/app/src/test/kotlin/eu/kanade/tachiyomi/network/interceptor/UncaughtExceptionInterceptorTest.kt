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
import kotlin.test.fail

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

    /**
     * BUG-5350：扩展按宿主 ABI 链接，缺类 / 签名不符是 LinkageError（不是 Exception），
     * 递归过深是 StackOverflowError；它们同样不得经 AsyncCall 在调度线程重抛。
     */
    @Test
    fun extensionErrorsOnAsyncCallDoNotEscapeToDispatcherThread() {
        val failures: List<Throwable> = listOf(
            NoClassDefFoundError("Failed resolution of: Leu/kanade/tachiyomi/AppInfo;"),
            NoSuchMethodError("No static method toJavaInstant(Lkotlin/time/Instant;)Ljava/time/Instant;"),
            ExceptionInInitializerError(IllegalStateException("static init")),
            StackOverflowError(),
        )
        for (failure in failures) {
            val (error: IOException, uncaught: List<Throwable>) = awaitThroughHostChain(failure)
            assertEquals(emptyList(), uncaught, "${failure::class.simpleName} 不得成为调度线程未捕获异常")
            assertSame(failure, generateSequence<Throwable>(error) { it.cause }.first { it === failure })
        }
    }

    /** OOM 这类 VM 已坏的错误不伪装成网络失败，照原样往上抛。 */
    @Test
    fun virtualMachineFailuresOtherThanStackOverflowAreNotWrapped() {
        val failure = OutOfMemoryError("Java heap space")
        val client = OkHttpClient.Builder()
            .addInterceptor(UncaughtExceptionInterceptor())
            .addInterceptor(Interceptor { throw failure })
            .build()

        val error = try {
            client.newCall(Request.Builder().url("http://127.0.0.1:9/page.jpg").build()).execute()
            fail("expected OutOfMemoryError")
        } catch (thrown: OutOfMemoryError) {
            thrown
        }

        assertSame(failure, error)
    }

    private fun awaitThroughHostChain(failure: Throwable): Pair<IOException, List<Throwable>> {
        val uncaught = Collections.synchronizedList(mutableListOf<Throwable>())
        val executor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "okhttp-dispatcher-test").apply {
                setUncaughtExceptionHandler { _, error -> uncaught += error }
            }
        }
        val client = OkHttpClient.Builder()
            .dispatcher(Dispatcher(executor))
            .addInterceptor(UncaughtExceptionInterceptor())
            .addInterceptor(Interceptor { throw failure })
            .build()

        val error = assertFailsWith<IOException> {
            runBlocking {
                client.newCall(Request.Builder().url("http://127.0.0.1:9/page.jpg").build()).await()
            }
        }

        executor.shutdown()
        assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS))
        return error to uncaught.toList()
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
