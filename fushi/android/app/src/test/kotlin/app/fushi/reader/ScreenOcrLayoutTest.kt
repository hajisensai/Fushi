package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 截屏 OCR 选取层「点哪个字」的纯几何契约（ScreenOcrLayout）。 */
class ScreenOcrLayoutTest {
    private fun line(
        text: String,
        l: Int,
        t: Int,
        r: Int,
        b: Int,
        glyphs: List<ScreenOcrLayout.Glyph>,
        vertical: Boolean,
    ) = ScreenOcrLayout.Line(text, l, t, r, b, glyphs, vertical)

    @Test
    fun symbolsAlignToTextOffsetsAndSkipMismatches() {
        val glyphs = ScreenOcrLayout.glyphsFromSymbols(
            "日本 語",
            listOf("日", "本", "X", "語"),
            listOf(
                intArrayOf(0, 0, 10, 10),
                intArrayOf(10, 0, 20, 10),
                intArrayOf(20, 0, 25, 10),
                intArrayOf(30, 0, 40, 10),
            ),
        )
        // 「X」在行文本里找不到：跳过，且不把后面「語」的偏移带歪（空格占下标 2）。
        assertEquals(listOf(0, 1, 3), glyphs.map { it.start })
    }

    @Test
    fun horizontalTapPicksContainingOrNearestGlyph() {
        val glyphs = ScreenOcrLayout.proportionalGlyphs("あいう", 0, 0, 300, 40, false)
        val l = line("あいう", 0, 0, 300, 40, glyphs, false)
        assertEquals(0, ScreenOcrLayout.charIndexAt(l, 50, 20))
        assertEquals(1, ScreenOcrLayout.charIndexAt(l, 150, 20))
        assertEquals(2, ScreenOcrLayout.charIndexAt(l, 299, 20))
        // 行框外侧（容差内命中行之后）按阅读轴取最近的字。
        assertEquals(2, ScreenOcrLayout.charIndexAt(l, 320, 50))
    }

    @Test
    fun verticalLinesSplitAlongY() {
        val glyphs = ScreenOcrLayout.proportionalGlyphs("縦書き", 100, 0, 140, 300, true)
        val l = line("縦書き", 100, 0, 140, 300, glyphs, true)
        assertEquals(0, ScreenOcrLayout.charIndexAt(l, 120, 10))
        assertEquals(1, ScreenOcrLayout.charIndexAt(l, 120, 150))
        assertEquals(2, ScreenOcrLayout.charIndexAt(l, 120, 290))
    }

    @Test
    fun surrogatePairsStayWholeInProportionalSplit() {
        val text = "𠮷野"
        val glyphs = ScreenOcrLayout.proportionalGlyphs(text, 0, 0, 200, 20, false)
        assertEquals(2, glyphs.size)
        assertEquals(0, glyphs[0].start)
        assertEquals(2, glyphs[1].start)
    }

    @Test
    fun verticalDetectionUsesGlyphCentersThenAspect() {
        val col = listOf(
            ScreenOcrLayout.Glyph(0, 1, 0, 0, 20, 20),
            ScreenOcrLayout.Glyph(1, 2, 0, 20, 20, 40),
        )
        assertTrue(ScreenOcrLayout.isVertical(0, 0, 20, 40, col))
        assertFalse(ScreenOcrLayout.isVertical(0, 0, 100, 20, emptyList()))
        assertTrue(ScreenOcrLayout.isVertical(0, 0, 20, 100, emptyList()))
        // 单字方框不算竖排。
        assertFalse(ScreenOcrLayout.isVertical(0, 0, 20, 22, emptyList()))
    }

    @Test
    fun hitLinePrefersSmallestContainingThenSlopThenMiss() {
        val big = line("a", 0, 0, 500, 500, emptyList(), false)
        val small = line("b", 100, 100, 200, 140, emptyList(), false)
        val lines = listOf(big, small)
        assertEquals(1, ScreenOcrLayout.hitLine(lines, 150, 120, 10))
        assertEquals(0, ScreenOcrLayout.hitLine(lines, 400, 400, 10))
        val only = listOf(small)
        assertEquals(0, ScreenOcrLayout.hitLine(only, 205, 120, 10))
        assertEquals(-1, ScreenOcrLayout.hitLine(only, 400, 400, 10))
    }

    @Test
    fun lineWithoutGlyphsHasNoCharIndex() {
        val l = line("", 0, 0, 10, 10, emptyList(), false)
        assertNull(ScreenOcrLayout.glyphAt(l, 5, 5))
        assertEquals(-1, ScreenOcrLayout.charIndexAt(l, 5, 5))
    }
}
