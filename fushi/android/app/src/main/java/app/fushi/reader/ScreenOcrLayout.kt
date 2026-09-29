package app.fushi.reader

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * 截屏 OCR 选取层的纯几何：识别行 → 逐字框，点一下 → 哪一行、哪个字。
 *
 * 刻意不碰任何 android.* 类型（`Rect` 在 JVM 单测里是空桩），全部用 int 坐标，
 * 这样 [ScreenOcrLayoutTest] 能在 host JVM 上直接跑。坐标系一律是**屏幕物理像素**
 * （截屏位图与屏幕 1:1，见 ScreenOcrService）。
 */
object ScreenOcrLayout {
    /** 一个字（或 ML Kit 的一个 symbol）：它在行文本里的 [start, end) 与屏幕框。 */
    class Glyph(
        @JvmField val start: Int,
        @JvmField val end: Int,
        @JvmField val left: Int,
        @JvmField val top: Int,
        @JvmField val right: Int,
        @JvmField val bottom: Int,
    ) {
        fun contains(x: Int, y: Int): Boolean = x in left..right && y in top..bottom
    }

    /** 一行识别结果。[vertical] 决定「沿哪条轴找最近的字」。 */
    class Line(
        @JvmField val text: String,
        @JvmField val left: Int,
        @JvmField val top: Int,
        @JvmField val right: Int,
        @JvmField val bottom: Int,
        @JvmField val glyphs: List<Glyph>,
        @JvmField val vertical: Boolean,
    ) {
        fun contains(x: Int, y: Int, slop: Int): Boolean =
            x >= left - slop && x <= right + slop && y >= top - slop && y <= bottom + slop
    }

    /**
     * 用 ML Kit 的 symbol 建逐字框：按顺序在 [text] 里 indexOf 每个 symbol 的文字，
     * 定出它在行文本里的偏移。对不上的 symbol（ML Kit 偶尔把 symbol 与 line 文本
     * 归一化得不一样）直接跳过——宁缺一个字的框，也不能把后面所有字的偏移带歪。
     *
     * [symbolBoxes] 每项是 [left, top, right, bottom]；长度须与 [symbolTexts] 相同。
     * 一个都对不上时返回空表，调用方退回 [proportionalGlyphs]。
     */
    @JvmStatic
    fun glyphsFromSymbols(
        text: String,
        symbolTexts: List<String>,
        symbolBoxes: List<IntArray>,
    ): List<Glyph> {
        val out = ArrayList<Glyph>(symbolTexts.size)
        var cursor = 0
        val n = min(symbolTexts.size, symbolBoxes.size)
        for (i in 0 until n) {
            val s = symbolTexts[i]
            val box = symbolBoxes[i]
            if (s.isEmpty() || box.size != 4) continue
            val at = text.indexOf(s, cursor)
            if (at < 0) continue
            out.add(Glyph(at, at + s.length, box[0], box[1], box[2], box[3]))
            cursor = at + s.length
        }
        return out
    }

    /**
     * 没有 symbol 时的兜底：把行框沿阅读方向按码点数等分。等宽假设对 CJK 基本成立，
     * 对拉丁文会有偏差——这正是它只作兜底的原因。
     */
    @JvmStatic
    fun proportionalGlyphs(
        text: String,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        vertical: Boolean,
    ): List<Glyph> {
        val count = text.codePointCount(0, text.length)
        if (count <= 0) return emptyList()
        val out = ArrayList<Glyph>(count)
        val span = if (vertical) bottom - top else right - left
        var offset = 0
        for (i in 0 until count) {
            val next = text.offsetByCodePoints(offset, 1)
            val a = (span.toLong() * i / count).toInt()
            val b = (span.toLong() * (i + 1) / count).toInt()
            out.add(
                if (vertical) {
                    Glyph(offset, next, left, top + a, right, top + b)
                } else {
                    Glyph(offset, next, left + a, top, left + b, bottom)
                },
            )
            offset = next
        }
        return out
    }

    /**
     * 竖排判定。ML Kit 不直接报书写方向：有 ≥2 个字框时看首尾字中心的位移主轴；
     * 否则看行框形状（高明显大于宽才算竖排，单字方框按横排处理）。
     */
    @JvmStatic
    fun isVertical(left: Int, top: Int, right: Int, bottom: Int, glyphs: List<Glyph>): Boolean {
        if (glyphs.size >= 2) {
            val first = glyphs.first()
            val last = glyphs.last()
            val dx = abs((last.left + last.right) - (first.left + first.right))
            val dy = abs((last.top + last.bottom) - (first.top + first.bottom))
            return dy > dx
        }
        return (bottom - top) > (right - left) * 3 / 2
    }

    /**
     * 点 ([x], [y]) 落在哪一行：先找严格包含的行（多行重叠时取面积最小的，贴字最紧）；
     * 都不包含时在 [slop] 容差内取离得最近的行；再没有就 -1（= 点在行外，关闭选取层）。
     */
    @JvmStatic
    fun hitLine(lines: List<Line>, x: Int, y: Int, slop: Int): Int {
        var best = -1
        var bestArea = Long.MAX_VALUE
        for (i in lines.indices) {
            val l = lines[i]
            if (!l.contains(x, y, 0)) continue
            val area = (l.right - l.left).toLong() * (l.bottom - l.top)
            if (area < bestArea) {
                bestArea = area
                best = i
            }
        }
        if (best >= 0) return best
        var bestDist = Int.MAX_VALUE
        for (i in lines.indices) {
            val l = lines[i]
            if (!l.contains(x, y, slop)) continue
            val d = distanceToBox(x, y, l.left, l.top, l.right, l.bottom)
            if (d < bestDist) {
                bestDist = d
                best = i
            }
        }
        return best
    }

    /**
     * 行内被点的字：优先严格包含该点的字框；否则取沿阅读方向（横排看 x、竖排看 y）
     * 离点最近的字——字与字之间的缝、行框比字框略高的上下边都应当算点到了邻近的字。
     * 行没有字框时返回 null。
     */
    @JvmStatic
    fun glyphAt(line: Line, x: Int, y: Int): Glyph? {
        if (line.glyphs.isEmpty()) return null
        for (g in line.glyphs) {
            if (g.contains(x, y)) return g
        }
        var best: Glyph? = null
        var bestDist = Int.MAX_VALUE
        for (g in line.glyphs) {
            val d = if (line.vertical) {
                axisDistance(y, g.top, g.bottom) * 4 + axisDistance(x, g.left, g.right)
            } else {
                axisDistance(x, g.left, g.right) * 4 + axisDistance(y, g.top, g.bottom)
            }
            if (d < bestDist) {
                bestDist = d
                best = g
            }
        }
        return best
    }

    /** 点到的字在行文本里的 UTF-16 下标（交给 Dart `wordFromIndex`），没字框时 -1。 */
    @JvmStatic
    fun charIndexAt(line: Line, x: Int, y: Int): Int = glyphAt(line, x, y)?.start ?: -1

    private fun axisDistance(v: Int, lo: Int, hi: Int): Int = when {
        v < lo -> lo - v
        v > hi -> v - hi
        else -> 0
    }

    private fun distanceToBox(x: Int, y: Int, l: Int, t: Int, r: Int, b: Int): Int =
        max(axisDistance(x, l, r), axisDistance(y, t, b))
}
