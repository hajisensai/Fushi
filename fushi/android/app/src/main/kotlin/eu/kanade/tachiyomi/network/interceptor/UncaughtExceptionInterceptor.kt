package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/**
 * 宿主拦截器链的最外层（见 NetworkHelper），扩展自己加的拦截器都在它里面。
 *
 * 语义与 Mihon 原版一致：链里抛出的非 IOException 一律收成 `IOException(e)`。
 * 扩展走 `Call.await()`（`enqueue`）时，OkHttp 的 AsyncCall 遇到非 IOException
 * 会先回调 onFailure、再把原异常在调度线程上重抛——Android 上这就是未捕获异常，
 * 整个进程被杀（BUG-4951：扩展把 StreamResetException 改抛成 PlainTextException，
 * 在线漫画取图超时 / 取消后闪退）。原异常留在 cause 里，通道错误信息与
 * Cloudflare 判定照旧沿 cause 链读。
 *
 * 比 Mihon 原版多收一类：扩展里的 `Error`。扩展是独立编译的 APK，按宿主
 * kotlin-stdlib / okhttp / extension-lib 的 ABI 链接，宿主少一个类或签名对不上就是
 * `NoClassDefFoundError` / `NoSuchMethodError`（[LinkageError]，BUG-4695、BUG-5273
 * 都出现过），扩展递归过深是 [StackOverflowError]。它们不是 Exception，原版的
 * `catch (Exception)` 漏过去，AsyncCall 照样在调度线程重抛把进程带崩
 * （BUG-5350：3.3.0 扩展搜索连报 NoClassDefFoundError 的设备反复 reason=CRASH）。
 * 只放过真正表示 VM 坏掉的 [VirtualMachineError]（OOM / InternalError），
 * 那种情况包成 IOException 也救不回来。
 */
class UncaughtExceptionInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response =
        try {
            chain.proceed(chain.request())
        } catch (error: IOException) {
            throw error
        } catch (error: StackOverflowError) {
            throw IOException(error)
        } catch (error: VirtualMachineError) {
            throw error
        } catch (error: Throwable) {
            throw IOException(error)
        }
}
