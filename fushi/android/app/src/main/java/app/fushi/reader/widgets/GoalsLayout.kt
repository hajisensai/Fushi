package app.fushi.reader.widgets

/**
 * Layout decision of the Goals widget from its actual size (dp) and the number of goals. Pure, so
 * the size → columns / rows / visible-count rules are unit tested without Glance.
 *
 * - [GoalsMode.HERO]: one goal, big ring + large text.
 * - [GoalsMode.GRID]: goal cells (ring left; language; metric · period; value / target; status).
 * - [GoalsMode.LIST]: compact rows (language; metric · period; value / target + status on one line).
 *
 * Never more than two columns (a column is only added when a cell keeps [CELL_MIN_W]). When not all
 * goals fit, the first [GoalsLayout.visible] in the user's order are shown and [GoalsLayout.more]
 * is the "+N more" count, so nothing is dropped silently.
 */
internal enum class GoalsMode { HERO, GRID, LIST }

/**
 * Size tier of a grid cell: ring diameter (dp) and text sizes (sp). Glance cannot measure text, so
 * the needed height / width are estimated conservatively: a text line takes [LINE_FACTOR] × its sp
 * (Roboto with font padding is ~1.33), a value like "1h 36m / 30m" or "27.9K / 28K" takes
 * [VALUE_EM] × its sp in width.
 *
 * - [sideMinW] / [sideRowH]: ring left of the four text lines.
 * - [stackedMinW] / [stackedRowH]: ring above the centred text (tall but narrow cells).
 *
 * [COMPACT] is the original fixed layout (40 dp ring, 72 dp rows) and the only tier for small
 * widgets, lists and "+N more".
 */
internal enum class GoalsTier(
    val ring: Int,
    val ringSp: Int,
    val languageSp: Int,
    val captionSp: Int,
    val valueSp: Int,
    val statusSp: Int,
    val sideRowH: Float,
) {
    COMPACT(40, 10, 11, 12, 14, 11, 72f),
    REGULAR(48, 11, 12, 13, 16, 12, 84f),
    LARGE(72, 16, 13, 15, 22, 13, 110f),
    XLARGE(96, 20, 14, 17, 28, 14, 136f);

    /** Height of language + caption + value + status lines. */
    val linesH: Float get() = (languageSp + captionSp + valueSp + statusSp) * LINE_FACTOR

    /** Width the value / target line needs. */
    val textMinW: Float get() = valueSp * VALUE_EM

    val sideMinW: Float get() = ring + RING_GAP + textMinW
    val stackedMinW: Float get() = maxOf(ring.toFloat(), textMinW)
    val stackedRowH: Float get() = ring + STACK_GAP + linesH

    /** Bitmap resolution of the ring: the default 128 px gets soft above ~80 dp. */
    val ringPx: Int get() = ringBitmapPx(ring.toFloat())

    companion object {
        const val LINE_FACTOR = 1.4f
        const val VALUE_EM = 6.6f
        const val RING_GAP = 8f
        const val STACK_GAP = 6f
    }
}

internal data class GoalsLayout(
    val mode: GoalsMode,
    val columns: Int,
    val rows: Int,
    val visible: Int,
    val more: Int,
    /** Grid cell size; always [GoalsTier.COMPACT] outside [GoalsMode.GRID]. */
    val tier: GoalsTier = GoalsTier.COMPACT,
    /** Grid cell puts the ring above the text (tall, narrow cells). */
    val stacked: Boolean = false,
)

/** Single-goal sizes: ring (dp) and text (sp); [sideBySide] = ring left of the text. */
internal data class GoalsHeroSpec(
    val sideBySide: Boolean,
    val ring: Float,
    val ringSp: Int,
    val languageSp: Int,
    val captionSp: Int,
    val valueSp: Int,
    val statusSp: Int,
) {
    val ringPx: Int get() = ringBitmapPx(ring)
}

/**
 * Ring bitmap size (px) for a ring of [ringDp]: the default 128 px gets soft above ~80 dp, and the
 * bitmaps travel in the RemoteViews parcel, so big rings are capped at 224 px.
 */
internal fun ringBitmapPx(ringDp: Float): Int = (ringDp * 1.6f).toInt().coerceIn(128, 224)

internal object GoalsLayoutPolicy {
    /** WidgetRoot padding (12 dp per side). */
    const val PADDING = 24f
    /** Title line + gap under it. */
    const val HEADER = 22f
    /** The "+N more" line. */
    const val MORE = 16f
    /** Narrowest goal cell that still fits "Characters · Week" next to its ring. */
    const val CELL_MIN_W = 140f
    const val COLUMN_GAP = 10f
    const val ROW_GAP = 6f
    /** Grid cell: 40 dp ring beside four text lines. */
    const val GRID_ROW_H = 72f
    /** Compact row: 32 dp ring beside three short text lines (nothing is joined into one long line). */
    const val LIST_ROW_H = 50f
    /** Below this inner width a single goal stacks ring above text instead of beside it. */
    const val HERO_SIDE_BY_SIDE_MIN_W = 240f
    /** One goal gets the hero layout when this much height is left under the title. */
    const val HERO_MIN_H = 64f
    /** Glance caps a Column at 10 children (title + rows + "+N more"). */
    const val MAX_ROWS = 7

    fun columnsFor(widthDp: Float): Int =
        if (widthDp - PADDING >= 2 * CELL_MIN_W + COLUMN_GAP) 2 else 1

    private fun rowsFitting(rowH: Float, availH: Float): Int =
        if (availH < rowH) 0 else ((availH + ROW_GAP) / (rowH + ROW_GAP)).toInt().coerceAtMost(MAX_ROWS)

    /** One goal: ring beside the text when the widget is wide enough, else stacked. */
    fun heroSideBySide(widthDp: Float): Boolean = widthDp - PADDING >= HERO_SIDE_BY_SIDE_MIN_W

    /** Text width beside the compact ring (32 dp ring + 8 dp gap) in a list cell. */
    fun listTextWidth(widthDp: Float, columns: Int): Float =
        (widthDp - PADDING - (columns - 1) * COLUMN_GAP) / columns - 40f

    /**
     * Whether a list row also shows "+4.8K" / "Completed" after the value: on the narrowest widgets
     * "1h 36m / 30m +1h 6m" would be cut, and for a reached goal the check mark plus value / target
     * already say it. Remaining amounts ("400 left") are always shown.
     */
    fun listShowsReachedStatus(widthDp: Float, columns: Int): Boolean = listTextWidth(widthDp, columns) >= 125f

    private fun ceilDiv(a: Int, b: Int): Int = (a + b - 1) / b

    /** Largest tier whose cell fits [cellW] x [cellH]; side-by-side preferred over stacked. */
    fun tierFor(cellW: Float, cellH: Float): Pair<GoalsTier, Boolean> {
        for (t in GoalsTier.entries.reversed()) {
            if (t == GoalsTier.COMPACT) break
            if (cellW >= t.sideMinW && cellH >= t.sideRowH) return t to false
            if (cellW >= t.stackedMinW && cellH >= t.stackedRowH) return t to true
        }
        return GoalsTier.COMPACT to false
    }

    /**
     * Grows a grid that shows every goal: tries the widest column count and one column, each with
     * its rows sharing the height evenly, and keeps the bigger tier (ties keep more columns).
     */
    private fun scaled(base: GoalsLayout, widthDp: Float, innerH: Float, count: Int): GoalsLayout {
        val innerW = widthDp - PADDING
        var best = base
        for (columns in listOf(base.columns, 1).distinct()) {
            val rows = ceilDiv(count, columns)
            if (rows > MAX_ROWS) continue
            val cellW = (innerW - (columns - 1) * COLUMN_GAP) / columns
            val cellH = (innerH - (rows - 1) * ROW_GAP) / rows
            val (tier, stacked) = tierFor(cellW, cellH)
            if (tier.ordinal > best.tier.ordinal) {
                best = GoalsLayout(GoalsMode.GRID, columns, rows, count, 0, tier, stacked)
            }
        }
        return best
    }

    /**
     * One goal. Small widgets keep the original sizes (ring 56–96 dp beside the text, 44–72 dp
     * stacked; value 22 / 17 sp). Tall widgets grow the ring up to 140 dp and the value to 28 sp, as
     * far as the text beside / under the ring still has room for the value line.
     */
    fun heroSpec(widthDp: Float, heightDp: Float): GoalsHeroSpec {
        val innerW = widthDp - PADDING
        val innerH = heightDp - PADDING - HEADER
        if (heroSideBySide(widthDp)) {
            val bigRing = minOf(innerH - 40f, innerW - 14f - GoalsTier.XLARGE.textMinW, 140f)
            if (innerH >= 200f && bigRing >= 104f) {
                return GoalsHeroSpec(true, bigRing, 26, 16, 19, 28, 16)
            }
            val ring = minOf(heightDp - 50f, innerW * 0.4f).coerceIn(56f, 96f)
            return GoalsHeroSpec(true, ring, if (ring >= 80f) 18 else 15, 13, 15, 22, 13)
        }
        if (innerH >= 280f) {
            val valueSp = minOf(24, (innerW / GoalsTier.VALUE_EM).toInt())
            // language + two caption lines + value + status.
            val textH = (14 + 2 * 16 + valueSp + 14) * GoalsTier.LINE_FACTOR
            val ring = minOf(innerW - 8f, innerH - 4f - textH, 140f).coerceAtLeast(72f)
            return GoalsHeroSpec(false, ring, if (ring >= 100f) 22 else 17, 14, 16, valueSp, 14)
        }
        return GoalsHeroSpec(false, (heightDp - 150f).coerceIn(44f, 72f), 13, 13, 15, 17, 13)
    }

    fun decide(widthDp: Float, heightDp: Float, count: Int): GoalsLayout {
        if (count <= 0) return GoalsLayout(GoalsMode.LIST, 1, 0, 0, 0)
        val innerH = heightDp - PADDING - HEADER
        val columns = columnsFor(widthDp)
        if (count == 1) {
            return if (innerH >= HERO_MIN_H) GoalsLayout(GoalsMode.HERO, 1, 1, 1, 0)
            else GoalsLayout(GoalsMode.LIST, 1, 1, 1, 0)
        }
        val gridRows = rowsFitting(GRID_ROW_H, innerH)
        if (gridRows * columns >= count) {
            val base = GoalsLayout(GoalsMode.GRID, columns, ceilDiv(count, columns), count, 0)
            return scaled(base, widthDp, innerH, count)
        }
        val listRows = rowsFitting(LIST_ROW_H, innerH)
        if (listRows * columns >= count) {
            return GoalsLayout(GoalsMode.LIST, columns, ceilDiv(count, columns), count, 0)
        }
        // Not everything fits: keep a line for "+N more" and show as many as possible.
        val availH = innerH - MORE
        val grid = rowsFitting(GRID_ROW_H, availH)
        val list = rowsFitting(LIST_ROW_H, availH).coerceAtLeast(1)
        return if (grid * columns >= list * columns) {
            val visible = grid * columns
            GoalsLayout(GoalsMode.GRID, columns, grid, visible, count - visible)
        } else {
            val visible = (list * columns).coerceAtMost(count)
            GoalsLayout(GoalsMode.LIST, columns, list, visible, count - visible)
        }
    }

    /** Width of one goal cell (grid or list) for [columns] columns. */
    fun cellWidth(widthDp: Float, columns: Int): Float =
        (widthDp - PADDING - (columns - 1) * COLUMN_GAP) / columns

    /**
     * Conservative text width (dp) of [text] at [sp] (Roboto advance widths rounded up): space 0.28 em,
     * narrow punctuation 0.36, digits / lowercase 0.56, uppercase and other letters 0.68, CJK / Hangul /
     * full-width forms 1 em. Glance cannot measure text, so this decides which status text fits.
     */
    fun estimateTextWidth(text: String, sp: Int): Float {
        var em = 0f
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            em += when {
                cp >= 0x2E80 -> 1f
                cp == ' '.code -> 0.28f
                cp in ".,:;/·|'!()-".map { it.code } -> 0.36f
                Character.isDigit(cp) || Character.isLowerCase(cp) -> 0.56f
                else -> 0.68f
            }
            i += Character.charCount(cp)
        }
        return em * sp
    }

    /**
     * The status line of a goal: daily goals keep [WidgetGoal.status]; weekly / monthly goals show
     * today's share — the full "12 / 20 today · On track" when it fits [availW] dp at [sp], else the
     * short "12 / 20 today" without the pace (computed by the app, never recomputed here).
     */
    fun statusText(goal: WidgetGoal, availW: Float, sp: Int): String {
        if (!goal.splits || goal.todayLine.isEmpty()) return goal.status
        if (estimateTextWidth(goal.todayLine, sp) <= availW) return goal.todayLine
        return goal.todayShort.ifEmpty { goal.todayLine }
    }

    /** "Daily goals" only when every entry is daily (an unknown / missing period counts as daily). */
    fun allDaily(periods: List<String>): Boolean = periods.all { it.isEmpty() || it == "daily" }
}
