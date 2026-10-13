package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * PR #2095 审查：反馈截图在原生侧合成时就缩到长边上限内再编码，
 * 不把全分辨率 PNG 经通道传给 Dart。
 */
class AppWindowSnapshotScaleTest {
    private fun size(width: Int, height: Int, maxSide: Int): List<Int> =
        AppWindowSnapshot.scaledSize(width, height, maxSide).toList()

    @Test
    fun scalesLongestSideDownToMaxSide() {
        assertEquals(listOf(720, 1600), size(1440, 3200, 1600))
        assertEquals(listOf(1600, 720), size(3200, 1440, 1600))
    }

    @Test
    fun neverUpscales() {
        assertEquals(listOf(800, 600), size(800, 600, 1600))
        assertEquals(listOf(1600, 900), size(1600, 900, 1600))
    }

    @Test
    fun nonPositiveMaxSideKeepsFullResolution() {
        assertEquals(listOf(1440, 3200), size(1440, 3200, 0))
    }

    @Test
    fun extremeAspectKeepsAtLeastOnePixel() {
        assertEquals(listOf(1600, 1), size(100000, 2, 1600))
    }
}
