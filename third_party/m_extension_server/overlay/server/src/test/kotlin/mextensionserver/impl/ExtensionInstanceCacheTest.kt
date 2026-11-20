package mextensionserver.impl

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ExtensionInstanceCacheTest {
    @Test
    fun `reuses mutable extension state for identical data`() {
        val loads = AtomicInteger()
        val cache =
            ExtensionInstanceCache(
                keyOf = ByteArray::contentToString,
                load = {
                    loads.incrementAndGet()
                    MutableExtension()
                },
                dispose = {},
            )

        val first = cache.use(byteArrayOf(1)) { extension -> ++extension.page }
        val second = cache.use(byteArrayOf(1)) { extension -> ++extension.page }
        cache.use(byteArrayOf(2)) { extension -> ++extension.page }

        assertEquals(1, first)
        assertEquals(2, second)
        assertEquals(2, loads.get())
        cache.close()
    }

    @Test
    fun `serializes calls in one lane of one extension instance`() {
        val activeCalls = AtomicInteger()
        val maxActiveCalls = AtomicInteger()
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(4)
        val cache =
            ExtensionInstanceCache(
                keyOf = ByteArray::contentToString,
                load = { MutableExtension() },
                dispose = {},
            )

        try {
            val futures =
                List(4) {
                    executor.submit {
                        start.await()
                        cache.use(byteArrayOf(1)) {
                            val active = activeCalls.incrementAndGet()
                            maxActiveCalls.updateAndGet { current -> maxOf(current, active) }
                            Thread.sleep(25)
                            activeCalls.decrementAndGet()
                        }
                    }
                }
            start.countDown()
            futures.forEach { future -> future.get(5, TimeUnit.SECONDS) }

            assertEquals(1, maxActiveCalls.get())
        } finally {
            cache.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun `a long playback call does not block catalogue calls on the same instance`() {
        // BUG-5026 / feedback igLsy_gcWz: a 5 min getVideoList held the only
        // per-instance lock, so searches on the same extension waited behind it
        // until the host gave up with BRIDGE_TIMEOUT.
        val playbackStarted = CountDownLatch(1)
        val releasePlayback = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        val cache =
            ExtensionInstanceCache(
                keyOf = ByteArray::contentToString,
                load = { MutableExtension() },
                dispose = {},
            )

        try {
            val playback =
                executor.submit {
                    cache.use(byteArrayOf(1), InvocationLane.PLAYBACK) {
                        playbackStarted.countDown()
                        releasePlayback.await(5, TimeUnit.SECONDS)
                    }
                }
            assertTrue(playbackStarted.await(5, TimeUnit.SECONDS))

            val search =
                executor.submit<Int> {
                    cache.use(byteArrayOf(1), InvocationLane.CATALOGUE) { extension -> ++extension.page }
                }
            assertEquals(1, search.get(2, TimeUnit.SECONDS))
            assertFalse(playback.isDone)

            releasePlayback.countDown()
            playback.get(5, TimeUnit.SECONDS)
        } finally {
            releasePlayback.countDown()
            cache.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun `exclusive calls wait for in-flight lane calls`() {
        val events = java.util.Collections.synchronizedList(mutableListOf<String>())
        val playbackStarted = CountDownLatch(1)
        val releasePlayback = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(3)
        val cache =
            ExtensionInstanceCache(
                keyOf = ByteArray::contentToString,
                load = { MutableExtension() },
                dispose = {},
            )

        try {
            val playback =
                executor.submit {
                    cache.use(byteArrayOf(1), InvocationLane.PLAYBACK) {
                        playbackStarted.countDown()
                        releasePlayback.await(5, TimeUnit.SECONDS)
                        events += "playback-end"
                    }
                }
            assertTrue(playbackStarted.await(5, TimeUnit.SECONDS))
            val clear =
                executor.submit {
                    cache.useExclusively(byteArrayOf(1)) { events += "clear" }
                }
            Thread.sleep(100)
            assertFalse(clear.isDone, "exclusive call must wait for the in-flight playback call")

            releasePlayback.countDown()
            playback.get(5, TimeUnit.SECONDS)
            clear.get(5, TimeUnit.SECONDS)
            assertEquals(listOf("playback-end", "clear"), events.toList())
        } finally {
            releasePlayback.countDown()
            cache.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun `only stream and page resolution run in the playback lane`() {
        assertEquals(InvocationLane.PLAYBACK, InvocationLane.forMethod("getVideoList"))
        assertEquals(InvocationLane.PLAYBACK, InvocationLane.forMethod("getPageList"))
        listOf(
            "getSearchAnime",
            "getPopularAnime",
            "getEpisodeList",
            "getDetailsAnime",
            "getSearchManga",
            "setPreferenceAnime",
            "filtersAnime",
        ).forEach { method ->
            assertEquals(InvocationLane.CATALOGUE, InvocationLane.forMethod(method), method)
        }
    }

    @Test
    fun `close disposes cached instances and allows a clean reload`() {
        val loads = AtomicInteger()
        val disposals = AtomicInteger()
        val cache =
            ExtensionInstanceCache(
                keyOf = ByteArray::contentToString,
                load = {
                    loads.incrementAndGet()
                    MutableExtension()
                },
                dispose = { disposals.incrementAndGet() },
            )

        cache.use(byteArrayOf(1)) {}
        cache.close()
        cache.use(byteArrayOf(1)) {}
        cache.close()

        assertEquals(2, loads.get())
        assertEquals(2, disposals.get())
    }

    @Test
    fun `does not cache a failed load`() {
        var attempts = 0
        val cache =
            ExtensionInstanceCache(
                keyOf = ByteArray::contentToString,
                load = {
                    attempts++
                    if (attempts == 1) error("load failed")
                    MutableExtension()
                },
                dispose = {},
            )

        assertFailsWith<IllegalStateException> {
            cache.use(byteArrayOf(1)) {}
        }
        cache.use(byteArrayOf(1)) {}

        assertEquals(2, attempts)
        cache.close()
    }

    private class MutableExtension(
        var page: Int = 0,
    )
}
