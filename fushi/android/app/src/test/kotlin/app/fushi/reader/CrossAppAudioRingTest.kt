package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

/** 跨应用语音缓存（拍板 oqk37s3QFL）的环形缓冲：只留最近一段、取的时候按时间先后且帧对齐。 */
class CrossAppAudioRingTest {
    private fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

    @Test
    fun tailReturnsMostRecentBytesInOrderAcrossTheWrapPoint() {
        val ring = CrossAppAudioRing(8, 2)
        ring.write(bytes(1, 2, 3, 4, 5, 6), 0, 6)
        ring.write(bytes(7, 8, 9, 10), 0, 4)
        // 容量 8：1、2 被覆盖。
        assertEquals(8, ring.size())
        assertContentEquals(bytes(3, 4, 5, 6, 7, 8, 9, 10), ring.tail(100))
        assertContentEquals(bytes(7, 8, 9, 10), ring.tail(4))
    }

    @Test
    fun tailIsFrameAlignedAndBoundedByWhatWasWritten() {
        val ring = CrossAppAudioRing(16, 4)
        ring.write(bytes(1, 2, 3, 4, 5, 6, 7, 8), 0, 8)
        // 要 7 字节：向下对齐到一帧（4 字节），取最近的那一帧。
        assertContentEquals(bytes(5, 6, 7, 8), ring.tail(7))
        assertContentEquals(bytes(1, 2, 3, 4, 5, 6, 7, 8), ring.tail(1000))
        assertEquals(0, ring.tail(-5).size)
    }

    @Test
    fun oversizedWriteKeepsOnlyItsLastFullRing() {
        val ring = CrossAppAudioRing(4, 2)
        ring.write(bytes(1, 2, 3, 4, 5, 6, 7, 8, 9, 10), 2, 8)
        assertContentEquals(bytes(7, 8, 9, 10), ring.tail(4))
        ring.write(bytes(11, 12), 0, 2)
        assertContentEquals(bytes(9, 10, 11, 12), ring.tail(4))
    }

    @Test
    fun capacityIsAlignedDownToWholeFramesAndClearEmptiesTheRing() {
        val ring = CrossAppAudioRing(7, 2)
        assertEquals(6, ring.capacity())
        ring.write(bytes(1, 2), 0, 2)
        ring.clear()
        assertEquals(0, ring.size())
        assertEquals(0, ring.tail(6).size)
    }
}
