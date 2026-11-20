package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 截屏 OCR 识别中的取消与过期回调（BUG-4790）。 */
class ScreenOcrRecognitionGateTest {
    @Test
    fun cancelDuringRecognitionIsAcceptedOnce() {
        val gate = ScreenOcrRecognitionGate()
        val flow = gate.begin()
        gate.onRecognitionStarted(flow)
        assertTrue(gate.isRecognizing())
        assertTrue(gate.takeCancel(flow))
        // 同一次取消只收尾一次（用户连点两下通知按钮）。
        assertFalse(gate.takeCancel(flow))
        assertFalse(gate.isRecognizing())
    }

    @Test
    fun cancelBeforeRecognitionIsIgnored() {
        val gate = ScreenOcrRecognitionGate()
        val flow = gate.begin()
        // 还在截屏（帧没交给识别器）：通知上没有取消，晚到的取消也不接受。
        assertFalse(gate.takeCancel(flow))
    }

    @Test
    fun cancelAfterSelectionShownIsIgnored() {
        val gate = ScreenOcrRecognitionGate()
        val flow = gate.begin()
        gate.onRecognitionStarted(flow)
        gate.onRecognitionEnded()
        // 选取层已经画出来：用户在选取层上自己关，不经通知取消。
        assertFalse(gate.takeCancel(flow))
    }

    @Test
    fun staleNotificationCannotCancelTheNextFlow() {
        val gate = ScreenOcrRecognitionGate()
        val first = gate.begin()
        gate.onRecognitionStarted(first)
        assertTrue(gate.takeCancel(first))
        val second = gate.begin()
        gate.onRecognitionStarted(second)
        // 上一次流程残留的取消（晚投递的 PendingIntent）不碰这一次。
        assertFalse(gate.takeCancel(first))
        assertTrue(gate.isRecognizing())
        assertTrue(gate.takeCancel(second))
    }

    @Test
    fun lateResultOfCancelledFlowIsStale() {
        val gate = ScreenOcrRecognitionGate()
        val first = gate.begin()
        gate.onRecognitionStarted(first)
        gate.takeCancel(first)
        val second = gate.begin()
        // 取消后识别器（本机模型 / ML Kit）晚到的结果带着旧编号：不能落进新流程。
        assertFalse(gate.isCurrent(first))
        assertTrue(gate.isCurrent(second))
        // 旧流程晚到的「开始识别」也不会把新流程标成识别中。
        gate.onRecognitionStarted(first)
        assertFalse(gate.isRecognizing())
    }

    @Test
    fun freshInstanceHasNoCurrentFlow() {
        val gate = ScreenOcrRecognitionGate()
        assertEquals(0L, gate.current())
        // 服务被杀后由通知按钮冷启动的新实例：任何编号都不是它的。
        assertFalse(gate.isCurrent(0L))
        assertFalse(gate.isCurrent(1L))
        assertFalse(gate.takeCancel(1L))
    }
}
