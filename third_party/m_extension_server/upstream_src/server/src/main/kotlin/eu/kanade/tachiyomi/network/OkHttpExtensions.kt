package eu.kanade.tachiyomi.network

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Cookie
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import rx.Observable
import rx.Producer
import rx.Subscription
import java.io.IOException
import java.net.HttpCookie
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resumeWithException

// Based on https://github.com/gildor/kotlin-coroutines-okhttp
@OptIn(ExperimentalCoroutinesApi::class)
private suspend fun Call.await(callStack: Array<StackTraceElement>): Response {
    return suspendCancellableCoroutine { continuation ->
        val callback =
            object : Callback {
                override fun onResponse(
                    call: Call,
                    response: Response,
                ) {
                    continuation.resume(response) { cause, value, context ->
                        value.body.close()
                    }
                }

                override fun onFailure(
                    call: Call,
                    e: IOException,
                ) {
                    // Don't bother with resuming the continuation if it is already cancelled.
                    if (continuation.isCancelled) return
                    val exception = IOException(e.message, e).apply { stackTrace = callStack }
                    continuation.resumeWithException(exception)
                }
            }

        enqueue(callback)

        continuation.invokeOnCancellation {
            try {
                cancel()
            } catch (ex: Throwable) {
                // Ignore cancel exception
            }
        }
    }
}

suspend fun Call.await(): Response {
    val callStack = Exception().stackTrace.run { copyOfRange(1, size) }
    return await(callStack)
}

/**
 * @since extensions-lib 15
 */
suspend fun Call.awaitSuccess(): Response {
    val callStack = Exception().stackTrace.run { copyOfRange(1, size) }
    val response = await(callStack)
    if (!response.isSuccessful) {
        response.close()
        throw HttpException(response.code).apply { stackTrace = callStack }
    }
    return response
}

@Suppress("unused_parameter", "UnusedParameter")
fun OkHttpClient.newCachelessCallWithProgress(
    request: Request,
    listener: ProgressListener,
): Call {
    val progressClient =
        newBuilder()
            .cache(null)
            .build()

    return progressClient.newCall(request)
}

fun Call.asObservable(): Observable<Response> {
    return Observable.unsafeCreate { subscriber ->
        // Since Call is a one-shot type, clone it for each new subscriber.
        val call = clone()

        // Wrap the call in a helper which handles both unsubscription and backpressure.
        val requestArbiter =
            object : AtomicBoolean(), Producer, Subscription {
                override fun request(n: Long) {
                    if (n == 0L || !compareAndSet(false, true)) return

                    try {
                        val response = call.execute()
                        if (!subscriber.isUnsubscribed) {
                            subscriber.onNext(response)
                            subscriber.onCompleted()
                        }
                    } catch (e: Exception) {
                        if (!subscriber.isUnsubscribed) {
                            subscriber.onError(e)
                        }
                    }
                }

                override fun unsubscribe() {
                    call.cancel()
                }

                override fun isUnsubscribed(): Boolean = call.isCanceled()
            }

        subscriber.add(requestArbiter)
        subscriber.setProducer(requestArbiter)
    }
}

fun Call.asObservableSuccess(): Observable<Response> =
    asObservable().doOnNext { response ->
        if (!response.isSuccessful) {
            response.close()
            throw HttpException(response.code)
        }
    }

fun OkHttpClient.newCallWithProgress(
    request: Request,
    listener: ProgressListener,
): Call {
    val progressClient =
        newBuilder()
            .build()

    return progressClient.newCall(request)
}

class HttpException(
    val code: Int,
) : IllegalStateException("HTTP error $code")

fun Cookie.toHttpCookie(url: HttpUrl): HttpCookie {
    val httpCookie = HttpCookie(name, value)
    httpCookie.domain = domain
    httpCookie.path = path
    httpCookie.secure = secure
    // httpCookie.httpOnly = httpOnly // private field
    if (expiresAt != Long.MAX_VALUE) {
        httpCookie.maxAge = (expiresAt - System.currentTimeMillis()) / 1000
    }
    return httpCookie
}

fun HttpCookie.toCookie(url: HttpUrl): Cookie {
    val builder =
        Cookie
            .Builder()
            .name(name)
            .value(value)
    if (domain != null) builder.domain(domain)
    if (path != null) builder.path(path)
    if (secure) builder.secure()
    // if (httpOnly) builder.httpOnly() // private field
    if (maxAge > 0) {
        builder.expiresAt(System.currentTimeMillis() + maxAge * 1000)
    }
    return builder.build()
}
