package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * BUG-4922：App 外内录与截屏识字共用一份投屏授权。内录登记后截屏识字必须借到同一个
 * projection（不再申请第二个——第二个会让系统停掉内录那份），同一 projection 上的虚拟屏
 * 只建一次、反复借用；内录停止时先放掉虚拟屏，借用方此后不能再碰它。
 */
class ProjectionShareTest {
    private class Display(val id: Int)

    private val released = mutableListOf<Display>()
    private val share = ProjectionShare<Any, Display> { released.add(it) }

    @Test
    fun screenOcrBorrowsTheAudioCaptureProjection() {
        assertNull(share.current(), "没开内录时没有可借的授权，截屏识字照常弹确认框")
        val audioProjection = Any()
        share.publish(audioProjection)
        assertSame(audioProjection, share.current())
    }

    @Test
    fun virtualDisplayIsCreatedOncePerProjectionAndReused() {
        val p = Any()
        share.publish(p)
        var creates = 0
        val first = share.displayFor(p) { creates++; Display(1) }
        val second = share.displayFor(p) { creates++; Display(2) }
        assertSame(first, second)
        assertEquals(1, creates, "Android 14 起同一 projection 第二次 createVirtualDisplay 会抛异常")
        assertTrue(share.holds(p, first))
        assertTrue(released.isEmpty(), "借用方收尾只摘 surface，不放虚拟屏")
    }

    @Test
    fun withdrawReleasesTheDisplayBeforeTheProjectionStops() {
        val p = Any()
        share.publish(p)
        val d = share.displayFor(p) { Display(1) }
        share.withdraw(p)
        assertEquals(listOf(d), released)
        assertNull(share.current())
        assertFalse(share.holds(p, d), "撤下后借用方不能再对已放掉的虚拟屏 setSurface")
        assertFailsWith<IllegalStateException> { share.displayFor(p) { Display(2) } }
    }

    @Test
    fun staleWithdrawDoesNotDropTheNewProjection() {
        val old = Any()
        share.publish(old)
        val oldDisplay = share.displayFor(old) { Display(1) }
        val fresh = Any()
        share.publish(fresh)
        assertEquals(listOf(oldDisplay), released, "换授权时旧授权上的虚拟屏一并放掉")
        share.withdraw(old)
        assertSame(fresh, share.current())
        val freshDisplay = share.displayFor(fresh) { Display(2) }
        assertTrue(share.holds(fresh, freshDisplay))
        assertEquals(1, released.size)
    }
}
