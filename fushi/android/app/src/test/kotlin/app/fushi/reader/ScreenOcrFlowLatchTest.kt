package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 截屏 OCR 发起 / 回调欠账（BUG-3602 / BUG-3603）。 */
class ScreenOcrFlowLatchTest {
    @Test
    fun launchThatReachedOnCreateIsNotDropped() {
        val latch = ScreenOcrFlowLatch()
        latch.onLaunchRequested()
        latch.onHostCreated()
        assertFalse(latch.takeDroppedLaunch(false))
    }

    @Test
    fun launchThatNeverReachedOnCreateIsDroppedOnce() {
        val latch = ScreenOcrFlowLatch()
        latch.onLaunchRequested()
        assertTrue(latch.takeDroppedLaunch(false))
        // 读即清：同一次丢弃只报一次。
        assertFalse(latch.takeDroppedLaunch(false))
    }

    @Test
    fun runningFlowIsNeverReportedAsDropped() {
        val latch = ScreenOcrFlowLatch()
        latch.onLaunchRequested()
        assertFalse(latch.takeDroppedLaunch(true))
        // 流程在跑时不清账；流程结束后仍没 onCreate 才算丢。
        assertTrue(latch.takeDroppedLaunch(false))
    }

    @Test
    fun nothingLaunchedNothingDropped() {
        assertFalse(ScreenOcrFlowLatch().takeDroppedLaunch(false))
    }

    @Test
    fun finishIsSentOnlyWhenDartIsOwed() {
        val latch = ScreenOcrFlowLatch()
        // 悬浮球发起的流程不欠 Dart。
        assertFalse(latch.finish(true))
        latch.onDartStarted()
        assertTrue(latch.finish(true))
        // 截到帧后提前回调过，选取层关闭时的收尾是 no-op。
        assertFalse(latch.finish(true))
        assertFalse(latch.takeUndelivered(true))
    }

    @Test
    fun finishWithoutChannelIsKeptUntilChannelReturns() {
        val latch = ScreenOcrFlowLatch()
        latch.onDartStarted()
        // MainActivity 已销毁：不能丢。
        assertFalse(latch.finish(false))
        // 通道还没回来：继续留着。
        assertFalse(latch.takeUndelivered(false))
        // 主界面回到前台：补发一次，之后不再重复。
        assertTrue(latch.takeUndelivered(true))
        assertFalse(latch.takeUndelivered(true))
    }

    @Test
    fun failedDeliveryIsRetriedOnNextResume() {
        val latch = ScreenOcrFlowLatch()
        latch.onDartStarted()
        assertTrue(latch.finish(true))
        latch.onDeliveryFailed()
        assertTrue(latch.takeUndelivered(true))
    }

    @Test
    fun newDartStartSupersedesUndeliveredFinish() {
        val latch = ScreenOcrFlowLatch()
        latch.onDartStarted()
        latch.finish(false)
        latch.onDartStarted()
        assertFalse(latch.takeUndelivered(true))
        assertTrue(latch.finish(true))
    }
}
