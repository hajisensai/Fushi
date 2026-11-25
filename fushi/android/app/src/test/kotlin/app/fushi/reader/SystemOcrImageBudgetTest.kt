package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * BUG-4705：系统 OCR 送检位图的像素预算。以前全分辨率解码，8000×11300 的页图是 361 MB
 * 位图，真机上主线程卡 1.1 s 并触发系统低内存杀进程。
 */
class SystemOcrImageBudgetTest {
    private val budget = SystemOcrImageBudget.MAX_RECOGNIZE_PIXELS

    @Test
    fun ordinaryPagesDecodeAtFullResolution() {
        // 常见扫描页（含反馈里的「2k 以上」）原样识别，精度不变。
        assertEquals(1, SystemOcrImageBudget.sampleSizeFor(2048, 2900, budget))
        assertEquals(1, SystemOcrImageBudget.sampleSizeFor(2894, 4093, budget))
        assertEquals(1, SystemOcrImageBudget.sampleSizeFor(4096, 4096, budget))
    }

    @Test
    fun oversizedPagesAreSampledUnderTheBudget() {
        val cases = listOf(
            intArrayOf(8000, 11300),
            intArrayOf(2400, 40000),
            intArrayOf(6000, 8500),
            intArrayOf(20000, 20000),
        )
        for ((width, height) in cases.map { it[0] to it[1] }) {
            val sample = SystemOcrImageBudget.sampleSizeFor(width, height, budget)
            assertTrue(sample > 1, "${width}x$height should be sampled")
            assertEquals(0, sample and (sample - 1), "inSampleSize must be a power of two")
            assertTrue(
                SystemOcrImageBudget.pixelsAt(width, height, sample) <= budget,
                "${width}x$height at $sample exceeds the budget",
            )
            // 取的是最小的够用采样率：再小一档就超预算，不多丢精度。
            assertTrue(SystemOcrImageBudget.pixelsAt(width, height, sample / 2) > budget)
        }
        assertEquals(4, SystemOcrImageBudget.sampleSizeFor(8000, 11300, budget))
    }

    @Test
    fun invalidSizesFallBackToNoSampling() {
        assertEquals(1, SystemOcrImageBudget.sampleSizeFor(0, 100, budget))
        assertEquals(1, SystemOcrImageBudget.sampleSizeFor(100, -1, budget))
    }

    @Test
    fun boxesMapBackToOriginalCoordinates() {
        // 8000 宽按 2 采样解出 4000：识别位图上的 1234 落回原图 2468。
        assertEquals(2468, SystemOcrImageBudget.toOriginal(1234, 8000, 4000))
        // 奇数尺寸向上取整解码（11300 / 2 = 5650），右下角映射回原图边界、不越界。
        assertEquals(11300, SystemOcrImageBudget.toOriginal(5650, 11300, 5650))
        assertEquals(11300, SystemOcrImageBudget.toOriginal(5700, 11300, 5650))
        assertEquals(0, SystemOcrImageBudget.toOriginal(-3, 11300, 5650))
        // 没降采样时原样返回。
        assertEquals(777, SystemOcrImageBudget.toOriginal(777, 2894, 2894))
    }
}
