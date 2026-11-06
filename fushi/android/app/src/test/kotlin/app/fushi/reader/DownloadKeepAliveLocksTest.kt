package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 下载保活锁（反馈 nLXqmvv5Fy）：acquire / release 幂等，停止路径重叠也必放锁。 */
class DownloadKeepAliveLocksTest {
    private class FakeLock : DownloadKeepAliveLocks.Lock {
        var held = false
        var acquires = 0
        var releases = 0

        override fun acquire() {
            check(!held) { "double acquire on a held lock" }
            held = true
            acquires++
        }

        override fun release() {
            check(held) { "release of a lock that is not held" }
            held = false
            releases++
        }

        override fun isHeld(): Boolean = held
    }

    @Test
    fun acquireTakesEveryLockOnce() {
        val wake = FakeLock()
        val wifi = FakeLock()
        val locks = DownloadKeepAliveLocks(listOf(wake, wifi))

        locks.acquire()
        locks.acquire()

        assertTrue(wake.held && wifi.held)
        assertEquals(1, wake.acquires)
        assertEquals(1, wifi.acquires)
        assertTrue(locks.isAnyHeld())
    }

    @Test
    fun overlappingStopPathsReleaseExactlyOnce() {
        val wake = FakeLock()
        val wifi = FakeLock()
        val locks = DownloadKeepAliveLocks(listOf(wake, wifi))
        locks.acquire()

        // stopNow 之后系统还会走 onDestroy：第二次 release 不能抛。
        locks.release()
        locks.release()

        assertFalse(locks.isAnyHeld())
        assertEquals(1, wake.releases)
        assertEquals(1, wifi.releases)
    }

    @Test
    fun releaseWithoutAcquireIsSafe() {
        val wake = FakeLock()
        val locks = DownloadKeepAliveLocks(listOf(wake))

        locks.release()

        assertEquals(0, wake.releases)
        assertFalse(locks.isAnyHeld())
    }

    @Test
    fun noLocksAvailableIsANoOp() {
        val locks = DownloadKeepAliveLocks(emptyList())
        locks.acquire()
        locks.release()
        assertFalse(locks.isAnyHeld())
    }
}
