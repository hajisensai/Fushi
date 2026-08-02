package mextensionserver.impl

import java.util.concurrent.locks.ReentrantLock
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.withLock

/**
 * Owns process-lifetime extension instances and serializes calls to each one.
 *
 * Many Mihon sources keep pagination cursors and other mutable state on the
 * source object. Reusing an instance is therefore part of the source contract,
 * not just a loading optimization.
 */
internal class ExtensionInstanceCache<T>(
    private val keyOf: (ByteArray) -> String,
    private val load: (ByteArray) -> T,
    private val dispose: (T) -> Unit,
) : AutoCloseable {
    private class Entry<T>(
        val value: T,
        val invocationLock: ReentrantLock = ReentrantLock(),
    )

    private val lifecycleLock = ReentrantReadWriteLock()
    private val cacheLock = Any()
    private val entries = mutableMapOf<String, Entry<T>>()

    fun <R> use(
        data: ByteArray,
        block: (T) -> R,
    ): R =
        lifecycleLock.readLock().withLock {
            val key = keyOf(data)
            val entry =
                synchronized(cacheLock) {
                    entries.getOrPut(key) {
                        Entry(load(data))
                    }
                }
            entry.invocationLock.withLock {
                block(entry.value)
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
