package app.fushi.reader.widgets

import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Goals widget: size (dp, as measured on a 420 dpi 4-column Pixel launcher) → columns / rows /
 * visible count, and the v2 snapshot fields with their v1 fallback.
 */
class GoalsLayoutTest {
    // Launcher cell spans on the test emulator (content size of the placed widget).
    private val w2 = 179f
    private val w3 = 276f
    private val w4 = 373f
    private val h2 = 210f
    private val h3 = 321f
    private val h5 = 543f

    private fun decide(w: Float, h: Float, n: Int) = GoalsLayoutPolicy.decide(w, h, n)

    @Test
    fun neverMoreThanTwoColumnsAndOnlyWhenCellsStayWide() {
        assertEquals(1, GoalsLayoutPolicy.columnsFor(w2))
        assertEquals(1, GoalsLayoutPolicy.columnsFor(w3))
        assertEquals(2, GoalsLayoutPolicy.columnsFor(w4))
        assertEquals(2, GoalsLayoutPolicy.columnsFor(1200f))
    }

    @Test
    fun oneGoalIsAHeroWhenThereIsRoom() {
        assertEquals(GoalsLayout(GoalsMode.HERO, 1, 1, 1, 0), decide(w2, h2, 1))
        assertEquals(GoalsLayout(GoalsMode.HERO, 1, 1, 1, 0), decide(w4, h5, 1))
        // A 1-row-high widget (110 dp): compact row instead.
        assertEquals(GoalsLayout(GoalsMode.LIST, 1, 1, 1, 0), decide(w4, 100f, 1))
        // Narrow 2-cell widget stacks the ring above the text so "1h 36m / 30m" is not cut.
        assertFalse(GoalsLayoutPolicy.heroSideBySide(w2))
        assertTrue(GoalsLayoutPolicy.heroSideBySide(w3))
        assertTrue(GoalsLayoutPolicy.heroSideBySide(w4))
    }

    @Test
    fun twoGoalsGetTwoColumnsOrTwoRows() {
        assertEquals(GoalsLayout(GoalsMode.GRID, 2, 1, 2, 0, GoalsTier.REGULAR, false), decide(w4, h2, 2))
        assertEquals(GoalsLayout(GoalsMode.GRID, 1, 2, 2, 0), decide(w2, h2, 2))
    }

    @Test
    fun fourGoalsAreATwoByTwoGridOnA4x2() {
        assertEquals(GoalsLayout(GoalsMode.GRID, 2, 2, 4, 0), decide(w4, h2, 4))
        assertEquals(GoalsLayout(GoalsMode.GRID, 2, 2, 4, 0, GoalsTier.REGULAR, false), decide(w4, h3, 4))
        assertEquals(GoalsLayout(GoalsMode.GRID, 1, 4, 4, 0, GoalsTier.LARGE, false), decide(w3, h5, 4))
    }

    @Test
    fun manyGoalsUseCompactRowsThenShowMore() {
        // 4x5: everything fits as a 2-column grid.
        assertEquals(GoalsLayout(GoalsMode.GRID, 2, 5, 9, 0, GoalsTier.REGULAR, false), decide(w4, h5, 9))
        // 4x3: compact 2-column list, still everything.
        assertEquals(GoalsLayout(GoalsMode.LIST, 2, 5, 9, 0), decide(w4, h3, 9))
        // 4x2: compact list, the rest is counted, never silently dropped.
        val small = decide(w4, h2, 9)
        assertEquals(GoalsMode.LIST, small.mode)
        assertEquals(2, small.columns)
        assertEquals(9, small.visible + small.more)
        assertTrue(small.more > 0)
        // 2x2 with 4 goals: one column, "+N more".
        val narrow = decide(w2, h2, 4)
        assertEquals(1, narrow.columns)
        assertEquals(4, narrow.visible + narrow.more)
        assertTrue(narrow.visible >= 2)
    }

    @Test
    fun rowsFitTheHeight() {
        for (w in listOf(w2, w3, w4, 640f)) for (h in listOf(110f, h2, h3, h5, 900f)) for (n in 1..12) {
            val l = decide(w, h, n)
            assertTrue(l.columns in 1..2, "columns $w x $h n=$n")
            assertEquals(n, l.visible + l.more, "count $w x $h n=$n")
            assertTrue(l.rows <= GoalsLayoutPolicy.MAX_ROWS)
            if (l.mode == GoalsMode.HERO) continue
            val rowH = when {
                l.mode == GoalsMode.LIST -> GoalsLayoutPolicy.LIST_ROW_H
                l.tier == GoalsTier.COMPACT -> GoalsLayoutPolicy.GRID_ROW_H
                l.stacked -> l.tier.stackedRowH
                else -> l.tier.sideRowH
            }
            // Only a grid that shows everything grows past compact; the cell is wide enough for it.
            if (l.tier != GoalsTier.COMPACT) {
                assertEquals(GoalsMode.GRID, l.mode)
                assertEquals(0, l.more)
                val cellW = (w - GoalsLayoutPolicy.PADDING - (l.columns - 1) * GoalsLayoutPolicy.COLUMN_GAP) / l.columns
                val minW = if (l.stacked) l.tier.stackedMinW else l.tier.sideMinW
                assertTrue(cellW >= minW, "width $w x $h n=$n: $cellW < $minW")
            }
            val used = l.rows * rowH + (l.rows - 1) * GoalsLayoutPolicy.ROW_GAP +
                (if (l.more > 0) GoalsLayoutPolicy.MORE else 0f)
            val avail = h - GoalsLayoutPolicy.PADDING - GoalsLayoutPolicy.HEADER
            if (l.rows > 1 || h >= 110f + 1) assertTrue(used <= avail + 0.5f, "fits $w x $h n=$n: $used > $avail")
        }
    }

    @Test
    fun smallWidgetsKeepTheCompactCells() {
        for (n in 2..9) {
            assertEquals(GoalsTier.COMPACT, decide(w2, h2, n).tier, "2x2 n=$n")
            assertEquals(GoalsTier.COMPACT, decide(w4, 100f, n).tier, "4x1 n=$n")
        }
        assertEquals(GoalsTier.COMPACT, decide(w4, h2, 4).tier)
        assertEquals(GoalsTier.COMPACT, decide(w4, h3, 9).tier)
        assertEquals(GoalsTier.COMPACT, decide(w4, h2, 9).tier)
    }

    @Test
    fun tallWidgetsGrowTheCellsAndShareTheHeight() {
        // 2 goals on 4x5: one column, two tall rows with the biggest cells (96 dp ring, 28 sp value).
        assertEquals(GoalsLayout(GoalsMode.GRID, 1, 2, 2, 0, GoalsTier.XLARGE, false), decide(w4, h5, 2))
        // 2 goals on 4x3: two columns, ring above the text.
        assertEquals(GoalsLayout(GoalsMode.GRID, 2, 1, 2, 0, GoalsTier.LARGE, true), decide(w4, h3, 2))
        // 4 goals on 4x5 stay a 2 x 2 grid, with large stacked cells.
        assertEquals(GoalsLayout(GoalsMode.GRID, 2, 2, 4, 0, GoalsTier.LARGE, true), decide(w4, h5, 4))
        // 3 goals on 4x5: one column of big rows beats a 2 x 2 grid with a hole.
        assertEquals(GoalsLayout(GoalsMode.GRID, 1, 3, 3, 0, GoalsTier.XLARGE, false), decide(w4, h5, 3))
        // Narrow but tall: stacked cells.
        assertEquals(GoalsLayout(GoalsMode.GRID, 1, 2, 2, 0, GoalsTier.LARGE, true), decide(w2, h5, 2))
    }

    @Test
    fun tierCapsAndOrder() {
        // Multi-goal ring never above 96 dp, value never above 28 sp, rings grow with the tier.
        val tiers = GoalsTier.entries
        assertEquals(40, GoalsTier.COMPACT.ring)
        assertEquals(14, GoalsTier.COMPACT.valueSp)
        assertTrue(tiers.all { it.ring <= 96 && it.valueSp <= 28 })
        assertTrue(tiers.zipWithNext().all { (a, b) -> a.ring < b.ring && a.valueSp < b.valueSp && a.sideRowH < b.sideRowH })
        // Every tier's row is at least as tall as its ring and its estimated text lines.
        assertTrue(tiers.all { it.sideRowH >= it.ring && it.sideRowH >= it.linesH }, "row height")
        // A huge cell takes the biggest tier side by side; a too-small one stays compact.
        assertEquals(GoalsTier.XLARGE to false, GoalsLayoutPolicy.tierFor(600f, 600f))
        assertEquals(GoalsTier.COMPACT to false, GoalsLayoutPolicy.tierFor(150f, 70f))
        assertEquals(GoalsTier.XLARGE to true, GoalsLayoutPolicy.tierFor(200f, 400f))
        assertEquals(128, GoalsTier.COMPACT.ringPx)
        assertTrue(GoalsTier.XLARGE.ringPx in 129..224)
    }

    @Test
    fun heroKeepsSmallSizesAndGrowsOnTallWidgets() {
        // 2x2 stacked and 4x2 / 3x2 side by side: the original sizes.
        assertEquals(GoalsHeroSpec(false, 60f, 13, 13, 15, 17, 13), GoalsLayoutPolicy.heroSpec(w2, h2))
        assertEquals(GoalsHeroSpec(true, 96f, 18, 13, 15, 22, 13), GoalsLayoutPolicy.heroSpec(w4, h2))
        assertEquals(GoalsHeroSpec(true, 96f, 18, 13, 15, 22, 13), GoalsLayoutPolicy.heroSpec(w3, h3))
        // 4x3 and 4x5: ring capped at 140 dp, value 28 sp.
        for (h in listOf(h3, h5)) {
            val big = GoalsLayoutPolicy.heroSpec(w4, h)
            assertTrue(big.sideBySide)
            assertEquals(140f, big.ring)
            assertEquals(28, big.valueSp)
            // The value line still fits beside the ring.
            assertTrue(w4 - GoalsLayoutPolicy.PADDING - big.ring - 14f >= big.valueSp * GoalsTier.VALUE_EM)
        }
        // Narrow and tall: stacked, the ring grows, the value is sized to the width.
        val tall = GoalsLayoutPolicy.heroSpec(w2, h5)
        assertFalse(tall.sideBySide)
        assertTrue(tall.ring in 100f..140f)
        assertTrue(tall.valueSp * GoalsTier.VALUE_EM <= w2 - GoalsLayoutPolicy.PADDING)
        for (w in listOf(w2, w3, w4, 640f)) for (h in listOf(h2, h3, h5, 900f)) {
            val spec = GoalsLayoutPolicy.heroSpec(w, h)
            assertTrue(spec.ring <= 140f && spec.valueSp <= 28, "caps $w x $h")
            assertTrue(spec.ring <= h - GoalsLayoutPolicy.PADDING - GoalsLayoutPolicy.HEADER, "ring fits $w x $h")
        }
    }

    @Test
    fun narrowListRowsDropTheRedundantReachedStatus() {
        assertFalse(GoalsLayoutPolicy.listShowsReachedStatus(w2, 1))
        assertTrue(GoalsLayoutPolicy.listShowsReachedStatus(w3, 1))
        assertTrue(GoalsLayoutPolicy.listShowsReachedStatus(w4, 2))
    }

    @Test
    fun titleIsDailyOnlyWhenEveryGoalIsDaily() {
        assertTrue(GoalsLayoutPolicy.allDaily(listOf("daily", "daily", "")))
        assertFalse(GoalsLayoutPolicy.allDaily(listOf("daily", "weekly")))
        assertFalse(GoalsLayoutPolicy.allDaily(listOf("monthly")))
    }

    @Test
    fun parsesV2FieldsAndFallsBackToV1() {
        val v2 = WidgetStore.parseGoal(
            JSONObject(
                """{"id":"chars","label":"日本語 · Chars","value":"14.8K characters","target":"5000 characters",
                "frac":1.0,"done":true,"period":"weekly","language":"日本語","caption":"Characters · Week",
                "compact":"14.8K / 5K","targetShort":"5K","state":"exceeded","status":"+9.8K","pct":100}""",
            ),
        )
        assertEquals("weekly", v2.period)
        assertEquals("日本語", v2.language)
        assertEquals("Characters · Week", v2.caption)
        assertEquals("14.8K / 5K", v2.compact)
        assertEquals("+9.8K", v2.status)
        assertTrue(v2.reached)

        val v1 = WidgetStore.parseGoal(
            JSONObject("""{"id":"chars","label":"Chars","value":"998","target":"1000","frac":0.998,"done":false}"""),
        )
        assertEquals("daily", v1.period)
        assertEquals("Chars", v1.caption)
        assertEquals("998 / 1000", v1.compact)
        assertEquals("inProgress", v1.state)
        assertEquals(99, v1.pct)
        assertFalse(v1.reached)
        assertFalse(v1.splits)
        assertEquals("", v1.todayLine)
    }

    private fun weekly(line: String, short: String) = WidgetStore.parseGoal(
        JSONObject(
            """{"id":"chars","label":"Chars","value":"15","target":"100","frac":0.15,"done":false,
            "period":"weekly","compact":"15 / 100","state":"inProgress","status":"85 left","pct":15,
            "splits":true,"todayLine":"$line","todayShort":"$short"}""",
        ),
    )

    @Test
    fun weeklyGoalsShowTodaysShareThatFits() {
        val g = weekly("5 / 18 today · 27 behind", "5 / 18 today")
        assertTrue(g.splits)
        fun gridTextW(w: Float, layout: GoalsLayout): Float =
            GoalsLayoutPolicy.cellWidth(w, layout.columns) - layout.tier.ring - GoalsTier.RING_GAP
        // 3x5 one-column grid (LARGE, 13 sp status): the whole line fits.
        val tall = decide(w3, h5, 4)
        assertEquals(GoalsTier.LARGE, tall.tier)
        assertEquals("5 / 18 today · 27 behind", GoalsLayoutPolicy.statusText(g, gridTextW(w3, tall), tall.tier.statusSp))
        // 4x3 two-column grid (REGULAR): only the short form (no pace) fits, never a cut line.
        val twoCol = decide(w4, h3, 4)
        assertEquals(2, twoCol.columns)
        assertEquals("5 / 18 today", GoalsLayoutPolicy.statusText(g, gridTextW(w4, twoCol), twoCol.tier.statusSp))
        assertEquals("5 / 18 today", GoalsLayoutPolicy.statusText(g, 70f, 11))
        // CJK counts full width: four Han characters add 4 em.
        assertEquals(
            GoalsLayoutPolicy.estimateTextWidth("5 / 18 · 27", 11) + 4 * 11f + 0.28f * 11,
            GoalsLayoutPolicy.estimateTextWidth("今天 5 / 18 · 落后27", 11),
            0.01f,
        )
        // Daily goals keep their status.
        val daily = WidgetStore.parseGoal(
            JSONObject("""{"id":"chars","label":"C","value":"1","target":"2","frac":0.5,"done":false,"status":"1 left"}"""),
        )
        assertEquals("1 left", GoalsLayoutPolicy.statusText(daily, 500f, 12))
        // Rest day / week done arrive as their own short text.
        assertEquals("Week done", GoalsLayoutPolicy.statusText(weekly("Week done", "Week done"), 40f, 11))
    }

    @Test
    fun weeklyStatusFitsTheSameFourLinesSoRowHeightsHold() {
        // Today's share replaces the status line (no extra line): the tier estimates stay valid.
        for (t in GoalsTier.entries) {
            assertEquals((t.languageSp + t.captionSp + t.valueSp + t.statusSp) * GoalsTier.LINE_FACTOR, t.linesH)
            assertTrue(t.sideRowH >= t.ring, "row holds the ring: $t")
        }
    }
}
