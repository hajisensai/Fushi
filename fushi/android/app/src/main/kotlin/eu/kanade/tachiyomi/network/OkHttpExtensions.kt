package eu.kanade.tachiyomi.network

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.okio.decodeFromBufferedSource
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.Source
import okio.buffer
import rx.Observable
import rx.Producer
import rx.Subscription
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

val jsonMime: MediaType = "application/json; charset=utf-8".toMediaType()

class HttpException(val code: Int) : IllegalStateException("HTTP error $code")

interface ProgressListener {
    fun update(bytesRead: Long, contentLength: Long, done: Boolean)
}

@Deprecated("Use suspend APIs instead")
fun Call.asObservable(): Observable<Response> = Observable.unsafeCreate { subscriber ->
    val call = clone()
    val requested = AtomicBoolean(false)
    val arbiter = object : Producer, Subscription {
        override fun request(n: Long) {
            if (n == 0L || !requested.compareAndSet(false, true)) return
            try {
                val response = call.execute()
                if (!subscriber.isUnsubscribed) {
                    subscriber.onNext(response)
                    subscriber.onCompleted()
                }
            } catch (error: Throwable) {
                if (!subscriber.isUnsubscribed) subscriber.onError(error)
            }
        }

        override fun unsubscribe() = call.cancel()

        override fun isUnsubscribed(): Boolean = call.isCanceled()
    }
    subscriber.add(arbiter)
    subscriber.setProducer(arbiter)
}

@Deprecated("Use suspend APIs instead")
fun Call.asObservableSuccess(): Observable<Response> =
    asObservable().doOnNext { response ->
        if (!response.isSuccessful) {
            response.close()
            throw HttpException(response.code)
        }
    }

suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(
        object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (!continuation.isCancelled) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response) { _, value, _ -> value.close() }
            }
        },
    )
}

suspend fun Call.awaitSuccess(): Response {
    val response = await()
    if (!response.isSuccessful) {
        response.close()
        throw HttpException(response.code)
    }
    return response
}

fun OkHttpClient.newCachelessCallWithProgress(
    request: Request,
    listener: ProgressListener,
    existingSize: Long = 0L,
): Call {
    val progressClient = newBuilder()
        .cache(null)
        .addNetworkInterceptor { chain ->
            val ranged = chain.request().newBuilder().apply {
                if (existingSize > 0L && chain.request().header("Range") == null) {
                    header("Range", "bytes=$existingSize-")
                }
            }.build()
            val response = chain.proceed(ranged)
            val offset = if (response.code == 206) existingSize else 0L
            response.newBuilder()
                .body(ProgressResponseBody(response.body, listener, offset))
                .build()
        }
        .build()
    return progressClient.newCall(request)
}

class ProgressResponseBody(
    private val responseBody: ResponseBody,
    private val listener: ProgressListener,
    private val existingSize: Long,
) : ResponseBody() {
    private val buffered: BufferedSource by lazy { progress(responseBody.source()).buffer() }

    override fun contentType(): MediaType? = responseBody.contentType()

    override fun contentLength(): Long = responseBody.contentLength()

    override fun source(): BufferedSource = buffered

    private fun progress(source: Source): Source = object : ForwardingSource(source) {
        private var total = existingSize

        override fun read(sink: Buffer, byteCount: Long): Long {
            val read = super.read(sink, byteCount)
            if (read > 0) total += read
            val length = responseBody.contentLength().let {
                if (it < 0) -1L else it + existingSize
            }
            listener.update(total, length, read == -1L)
            return read
        }
    }
}

context(json: Json)
inline fun <reified T> Response.parseAs(): T =
    decodeFromJsonResponse(serializer(), this)

context(json: Json)
fun <T> decodeFromJsonResponse(
    deserializer: DeserializationStrategy<T>,
    response: Response,
): T = response.body.source().use { source ->
    json.decodeFromBufferedSource(deserializer, source)
}
