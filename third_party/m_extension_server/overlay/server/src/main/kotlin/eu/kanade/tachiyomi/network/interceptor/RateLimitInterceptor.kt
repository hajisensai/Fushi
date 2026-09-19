package eu.kanade.tachiyomi.network.interceptor

import android.os.SystemClock
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import java.util.concurrent.TimeUnit
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * An OkHttp interceptor that handles rate limiting.
 *
 * Examples:
 *
 * permits = 5,  period = 1, unit = seconds  =>  5 requests per second
 * permits = 10, period = 2, unit = minutes  =>  10 requests per 2 minutes
 *
 * @since extension-lib 1.3
 *
 * @param permits {Int}   Number of requests allowed within a period of units.
 * @param period {Long}   The limiting duration. Defaults to 1.
 * @param unit {TimeUnit} The unit of time for the period. Defaults to seconds.
 */
fun OkHttpClient.Builder.rateLimit(
    permits: Int,
    period: Long = 1,
    unit: TimeUnit = TimeUnit.SECONDS,
) = addInterceptor(RateLimitInterceptor(permits, period, unit))

/**
 * Duration-based overload used by current extensions (extensions-lib 16).
 *
 * Kept next to the legacy TimeUnit API: `Duration` is a value class, so this
 * overload mangles to the JVM name (`rateLimit-SxA4cEA`) that extensions
 * compiled against lib 16+ link to. Same shape as kodjodevf/M-Extension-Server
 * v1.0.7.
 */
fun OkHttpClient.Builder.rateLimit(
    permits: Int,
    period: Duration = 1.seconds,
) = addInterceptor(RateLimitInterceptor(permits, period.inWholeMilliseconds, TimeUnit.MILLISECONDS))

private class RateLimitInterceptor(
    private val permits: Int,
    period: Long,
    unit: TimeUnit,
) : Interceptor {
    private val requestQueue = ArrayList<Long>(permits)
    private val rateLimitMillis = unit.toMillis(period)

    override fun intercept(chain: Interceptor.Chain): Response {
        synchronized(requestQueue) {
            val now = SystemClock.elapsedRealtime()
            val waitTime =
                if (requestQueue.size < permits) {
                    0
                } else {
                    val oldestReq = requestQueue[0]
                    val newestReq = requestQueue[permits - 1]

                    if (newestReq - oldestReq > rateLimitMillis) {
                        0
                    } else {
                        oldestReq + rateLimitMillis - now // Remaining time
                    }
                }

            if (requestQueue.size == permits) {
                requestQueue.removeAt(0)
            }
            if (waitTime > 0) {
                requestQueue.add(now + waitTime)
                Thread.sleep(waitTime) // Sleep inside synchronized to pause queued requests
            } else {
                requestQueue.add(now)
            }
        }

        return chain.proceed(chain.request())
    }
}
