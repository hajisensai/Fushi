package tachiyomi.core.common.util.lang

import kotlinx.coroutines.suspendCancellableCoroutine
import rx.Observable
import rx.Subscriber
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

suspend fun <T> Observable<T>.awaitSingle(): T = suspendCancellableCoroutine { continuation ->
    val subscription = single().subscribe(
        object : Subscriber<T>() {
            override fun onStart() = request(1)

            override fun onNext(value: T) {
                if (continuation.isActive) continuation.resume(value)
            }

            override fun onCompleted() {
                if (continuation.isActive) {
                    continuation.resumeWithException(
                        NoSuchElementException("Observable completed without a value"),
                    )
                }
            }

            override fun onError(error: Throwable) {
                if (continuation.isActive) continuation.resumeWithException(error)
            }
        },
    )
    continuation.invokeOnCancellation { subscription.unsubscribe() }
}

suspend fun <T> withIOContext(block: suspend () -> T): T =
    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { block() }
