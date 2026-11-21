package mextensionserver.impl

import java.util.concurrent.locks.ReentrantLock
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.withLock

/**
 * Which serialization lane a bridge call runs in.
 *
 * Calls in one lane of one extension instance run one at a time; calls in
 * different lanes may overlap.
 *
 * - [CATALOGUE]: browse / search / details / episode lists / filters /
 *   preferences / covers. Mihon sources keep pagination cursors and similar
 *   request state on the source object for these, which is why upstream
 *   serializes them.
 * - [PLAYBACK]: resolving one episode's streams or one chapter's pages. These
 *   are the long calls (hoster expansion, WebView fallbacks with 30 s fetch
 *   timeouts each; feedback igLsy_gcWz measured a 5 min `getVideoList`) and
 *   take only the episode / chapter they were given. Upstream's single
 *   per-instance lock queued every search behind them until the host gave up
 *   with BRIDGE_TIMEOUT (BUG-5026).
 *
 * The Android host runs every call on a shared two-thread pool with no
 * per-source lock at all, so a source overlapping a playback call with a
 * catalogue call is behaviour the shipped extensions already see.
 */
internal enum class InvocationLane {
    CATALOGUE,
    PLAYBACK,
    ;

    companion object {
        private val playbackMethods = setOf("getVideoList", "getPageList")

        fun forMethod(method: String): InvocationLane = if (method in playbackMethods) PLAYBACK else CATALOGUE
    }
}

/**
 * Owns process-lifetime extension instances and serializes calls to each one
 * per [InvocationLane].
 *
 * Many Mihon sources keep pagination cursors and other mutable state on the
 * source object. Reusing an instance is therefore part of the source contract,
 * not just a loading optimization.
 *
 * Fushi: the lookup input [K] is generic. Upstream keyed by the raw APK bytes
 * every call carried; the sidecar now receives only the APK's SHA-256 and
 * [load] fetches the bytes from [ExtensionApkStore] on a miss.
 */
internal class ExtensionInstanceCache<K, T>(
    private val keyOf: (K) -> String,
    private val load: (K) -> T,
    private val dispose: (T) -> Unit,
) : AutoCloseable {
    private class Entry<T>(
        val value: T,
    ) {
        /** Read side for lane calls, write side for [useExclusively]. */
        val exclusiveLock = ReentrantReadWriteLock()
        val laneLocks: Map<InvocationLane, ReentrantLock> =
            InvocationLane.entries.associateWith { ReentrantLock() }
    }

    private val lifecycleLock = ReentrantReadWriteLock()
    private val cacheLock = Any()
    private val entries = mutableMapOf<String, Entry<T>>()

    fun <R> use(
        data: K,
        lane: InvocationLane = InvocationLane.CATALOGUE,
        block: (T) -> R,
    ): R =
        lifecycleLock.readLock().withLock {
            val entry = entryFor(data)
            entry.exclusiveLock.readLock().withLock {
                entry.laneLocks.getValue(lane).withLock {
                    block(entry.value)
                }
            }
        }

    /**
     * Runs [block] with no other call of any lane in flight on the same
     * instance -- for operations that reset state every lane reads (clearing
     * a source's preferences and cookies).
     */
    fun <R> useExclusively(
        data: K,
        block: (T) -> R,
    ): R =
        lifecycleLock.readLock().withLock {
            val entry = entryFor(data)
            entry.exclusiveLock.writeLock().withLock {
                block(entry.value)
            }
        }

    private fun entryFor(data: K): Entry<T> {
        val key = keyOf(data)
        return synchronized(cacheLock) {
            entries.getOrPut(key) {
                Entry(load(data))
            }
        }
    }

    override fun close() {
        lifecycleLock.writeLock().withLock {
            val cachedEntries =
                synchronized(cacheLock) {
                    entries.values.toList().also {
                        entries.clear()
                    }
                }
            var failure: Throwable? = null
            cachedEntries.forEach { entry ->
                try {
                    dispose(entry.value)
                } catch (error: Throwable) {
                    if (failure == null) {
                        failure = error
                    } else {
                        failure?.addSuppressed(error)
                    }
                }
            }
            failure?.let { throw it }
        }
    }
}
