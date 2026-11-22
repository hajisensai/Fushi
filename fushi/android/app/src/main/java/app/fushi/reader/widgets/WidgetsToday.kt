package app.fushi.reader.widgets

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.unit.ColorProvider
import androidx.glance.appwidget.SizeMode
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import kotlin.math.roundToInt

// Immersion dashboard (Today), daily goals, streak + calendar, weekly progress.

// ---------------------------------------------------------------------------
// Daily Immersion Dashboard (keeps the TodayWidget / TodayReceiver class names so already
// placed widgets survive the upgrade)
// ---------------------------------------------------------------------------

class TodayWidget : FushiGlanceWidget() {
    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        if (snapshot == null) SetupHint(null, "Open Fushi to set up this widget")
        else TodayContent(context, snapshot)
    }
}

private fun categoryVisible(s: WidgetSnapshot, id: String): Boolean = when (id) {
    "reading" -> s.moduleBooks || s.moduleManga
    "listening" -> s.moduleMusic
    "watching" -> s.moduleVideo
    "games" -> s.moduleGames
    else -> true
}

@Composable
private fun CategoryRow(context: Context, cat: WidgetCategory, ms: Long, time: String, total: Long, withBar: Boolean) {
    var modifier = GlanceModifier.fillMaxWidth().padding(vertical = 3.dp)
    if (cat.link.isNotEmpty()) modifier = modifier.clickable(openLink(context, cat.link))
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        Text(
            cat.label,
            maxLines = 1,
            modifier = GlanceModifier.defaultWeight(),
            style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 12.sp),
        )
        if (withBar) {
            LinearProgressIndicator(
                progress = if (total > 0) (ms.toFloat() / total).coerceIn(0f, 1f) else 0f,
                modifier = GlanceModifier.width(56.dp),
                color = GlanceTheme.colors.primary,
                backgroundColor = GlanceTheme.colors.secondaryContainer,
            )
            Spacer(GlanceModifier.width(8.dp))
        }
        Text(
            time,
            maxLines = 1,
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 12.sp, fontWeight = FontWeight.Medium),
        )
    }
}

@Composable
private fun TodayContent(context: Context, s: WidgetSnapshot) {
    val size = sizeClass()
    val fresh = isFresh(s)
    val zero = s.label("zeroTime", "0m")
    val total = if (fresh) s.todayTotalMs else 0L
    val totalText = if (fresh) s.todayTime.ifEmpty { zero } else zero
    val hasTimeGoal = s.goalMs > 0
    val goalFrac = if (!fresh) 0f else if (hasTimeGoal) s.goalFrac else s.todayGoal
    val showGoal = hasTimeGoal || s.todayGoal > 0f
    val all = s.categories.filter { categoryVisible(s, it.id) }
    // Compact (narrow) widgets hide zero categories and cap the list so the total stays readable.
    val cats = if (size.wide) all else all.filter { fresh && it.ms > 0 }.take(if (size.tall) 4 else 2)
    val streakText = s.label("streak", "Streak") + " " + s.streak

    WidgetRoot(url = "fushi://widget/stats") {
        if (size.wide && !size.tall) {
            Row(modifier = GlanceModifier.fillMaxSize()) {
                Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight()) {
                    Label(s.withProfile(s.label("today", "Today")), GlanceTheme.colors.primary)
                    Text(
                        totalText,
                        maxLines = 1,
                        style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 28.sp, fontWeight = FontWeight.Bold),
                    )
                    if (showGoal) {
                        Gap(2)
                        LinearProgressIndicator(
                            progress = goalFrac,
                            modifier = GlanceModifier.fillMaxWidth(),
                            color = GlanceTheme.colors.primary,
                            backgroundColor = GlanceTheme.colors.secondaryContainer,
                        )
                        if (hasTimeGoal) Label("${s.goalTime}", size = 11)
                    }
                    Spacer(GlanceModifier.defaultWeight())
                    if (!fresh) StaleHint(s) else Label(streakText, size = 11)
                }
                Spacer(GlanceModifier.width(14.dp))
                Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
                    cats.forEach { CategoryRow(context, it, if (fresh) it.ms else 0L, if (fresh) it.time else zero, total, false) }
                }
            }
        } else {
            Column(modifier = GlanceModifier.fillMaxSize()) {
                Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Label(s.withProfile(s.label("today", "Today")), GlanceTheme.colors.primary, GlanceModifier.defaultWeight())
                    if (size.wide) Label(streakText)
                }
                Text(
                    totalText,
                    maxLines = 1,
                    style = TextStyle(
                        color = GlanceTheme.colors.onSurface,
                        fontSize = if (size.large) 36.sp else 26.sp,
                        fontWeight = FontWeight.Bold,
                    ),
                )
                // Nested columns keep the outer Column under Glance's 10-children cap.
                if (showGoal) {
                    Column(modifier = GlanceModifier.fillMaxWidth().padding(top = 2.dp)) {
                        LinearProgressIndicator(
                            progress = goalFrac,
                            modifier = GlanceModifier.fillMaxWidth(),
                            color = GlanceTheme.colors.primary,
                            backgroundColor = GlanceTheme.colors.secondaryContainer,
                        )
                        if (hasTimeGoal) Label("${(goalFrac * 100).roundToInt()}% · ${s.goalTime}", size = 11)
                    }
                }
                Column(modifier = GlanceModifier.fillMaxWidth().padding(top = 6.dp)) {
                    cats.forEach { CategoryRow(context, it, if (fresh) it.ms else 0L, if (fresh) it.time else zero, total, size.large) }
                }
                Spacer(GlanceModifier.defaultWeight())
                if (!fresh) StaleHint(s) else if (!size.wide) Label(streakText, size = 11)
            }
        }
    }
}

class TodayReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = TodayWidget()
}

// ---------------------------------------------------------------------------
// Learning goals: layout adapts to the widget's real size (GoalsLayoutPolicy)
// ---------------------------------------------------------------------------

class GoalsWidget : FushiGlanceWidget() {
    /** Exact size: the column / row decision needs the real launcher size, not 4 buckets. */
    override val sizeMode: SizeMode = SizeMode.Exact

    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        if (snapshot == null) {
            SetupHint(null, "Open Fushi to set up this widget")
        } else if (snapshot.goals.isEmpty()) {
            SetupHint(null, snapshot.label("noGoals", "Set goals in Fushi"), "fushi://widget/settings/widgets")
        } else {
            GoalsContent(snapshot)
        }
    }
}

/** Ring tint: reached = tertiary, rest day = muted, otherwise primary. */
@Composable
private fun goalRingColor(goal: WidgetGoal, fresh: Boolean): ColorProvider = when {
    fresh && goal.reached -> GlanceTheme.colors.tertiary
    fresh && goal.restDay -> GlanceTheme.colors.outline
    else -> GlanceTheme.colors.primary
}

@Composable
private fun goalStatusColor(goal: WidgetGoal): ColorProvider =
    if (goal.reached) GlanceTheme.colors.tertiary else GlanceTheme.colors.onSurfaceVariant

/** Ring capped at 100 %, a check mark once reached, otherwise the floored percent. */
@Composable
private fun GoalRing(goal: WidgetGoal, fresh: Boolean, size: Dp, textSp: Int, px: Int = RING_PX) {
    val reached = fresh && goal.reached
    Box(contentAlignment = Alignment.Center) {
        Ring(if (fresh) goal.frac else 0f, size, goalRingColor(goal, fresh), px = px)
        Text(
            if (reached) "✓" else "${if (fresh) goal.pct else 0}%",
            maxLines = 1,
            style = TextStyle(
                color = if (fresh && goal.restDay) GlanceTheme.colors.onSurfaceVariant else GlanceTheme.colors.onSurface,
                fontSize = (if (reached) textSp + 3 else textSp).sp,
                fontWeight = FontWeight.Bold,
            ),
        )
    }
}

private fun goalCompact(goal: WidgetGoal, fresh: Boolean): String =
    if (fresh) goal.compact else "– / ${goal.targetShort}"

/**
 * Language; metric · period; value / target; status, sized by the caller. Weekly / monthly goals put
 * today's share in the status line ("12 / 20 today · On track", [GoalsLayoutPolicy.statusText]),
 * picked to fit [textW] (dp available for the lines). Same four lines, so row heights are unchanged.
 */
@Composable
private fun GoalLines(
    goal: WidgetGoal,
    fresh: Boolean,
    align: TextAlign,
    languageSp: Int,
    captionSp: Int,
    captionLines: Int,
    valueSp: Int,
    statusSp: Int,
    textW: Float,
) {
    val line = if (align == TextAlign.Center) GlanceModifier.fillMaxWidth() else GlanceModifier
    if (goal.language.isNotEmpty()) {
        Text(
            goal.language,
            modifier = line,
            maxLines = 1,
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = languageSp.sp, textAlign = align),
        )
    }
    Text(
        goal.caption,
        modifier = line,
        maxLines = captionLines,
        style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = captionSp.sp, fontWeight = FontWeight.Medium, textAlign = align),
    )
    Text(
        goalCompact(goal, fresh),
        modifier = line,
        maxLines = 1,
        style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = valueSp.sp, fontWeight = FontWeight.Bold, textAlign = align),
    )
    val status = GoalsLayoutPolicy.statusText(goal, textW, statusSp)
    if (fresh && status.isNotEmpty()) {
        Text(
            status,
            modifier = line,
            maxLines = 1,
            style = TextStyle(color = goalStatusColor(goal), fontSize = statusSp.sp, textAlign = align),
        )
    }
}

/** Big ring + large text for a single goal, sized by [GoalsLayoutPolicy.heroSpec]. */
@Composable
private fun GoalHero(goal: WidgetGoal, fresh: Boolean, spec: GoalsHeroSpec, innerW: Float) {
    if (spec.sideBySide) {
        Row(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            GoalRing(goal, fresh, spec.ring.dp, spec.ringSp, spec.ringPx)
            Spacer(GlanceModifier.width(14.dp))
            Column(modifier = GlanceModifier.defaultWeight()) {
                GoalLines(
                    goal, fresh, TextAlign.Start, spec.languageSp, spec.captionSp, 2, spec.valueSp, spec.statusSp,
                    innerW - spec.ring - 14f,
                )
            }
        }
    } else {
        Column(
            modifier = GlanceModifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GoalRing(goal, fresh, spec.ring.dp, spec.ringSp, spec.ringPx)
            Gap(4)
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                GoalLines(
                    goal, fresh, TextAlign.Center, spec.languageSp, spec.captionSp, 2, spec.valueSp, spec.statusSp,
                    innerW,
                )
            }
        }
    }
}

/**
 * Grid cell sized by [tier]: ring left of language; metric · period; value / target; status. When
 * [stacked] (tall, narrow cell) the ring sits above the centred lines.
 */
@Composable
private fun GoalGridCell(
    goal: WidgetGoal,
    fresh: Boolean,
    tier: GoalsTier,
    stacked: Boolean,
    cellW: Float,
    modifier: GlanceModifier,
) {
    if (stacked) {
        Column(
            modifier = modifier,
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GoalRing(goal, fresh, tier.ring.dp, tier.ringSp, tier.ringPx)
            Gap(GoalsTier.STACK_GAP.toInt())
            GoalLines(
                goal, fresh, TextAlign.Center, tier.languageSp, tier.captionSp, 1, tier.valueSp, tier.statusSp, cellW,
            )
        }
        return
    }
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        GoalRing(goal, fresh, tier.ring.dp, tier.ringSp, tier.ringPx)
        Spacer(GlanceModifier.width(GoalsTier.RING_GAP.dp))
        Column(modifier = GlanceModifier.defaultWeight()) {
            GoalLines(
                goal, fresh, TextAlign.Start, tier.languageSp, tier.captionSp, 1, tier.valueSp, tier.statusSp,
                cellW - tier.ring - GoalsTier.RING_GAP,
            )
        }
    }
}

/** Compact row: small ring; language; metric · period; "value / target  status" on one line. */
@Composable
private fun GoalListRow(
    goal: WidgetGoal,
    fresh: Boolean,
    showReachedStatus: Boolean,
    textW: Float,
    modifier: GlanceModifier,
) {
    val compact = goalCompact(goal, fresh)
    // Today's share sits after the value on the same line: only the width left of it counts.
    val status = GoalsLayoutPolicy.statusText(
        goal,
        textW - GoalsLayoutPolicy.estimateTextWidth(compact, 12) - 6f,
        11,
    )
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        GoalRing(goal, fresh, 32.dp, 9)
        Spacer(GlanceModifier.width(8.dp))
        Column(modifier = GlanceModifier.defaultWeight()) {
            if (goal.language.isNotEmpty()) Label(goal.language, size = 11)
            Text(
                goal.caption,
                maxLines = 1,
                style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 12.sp, fontWeight = FontWeight.Medium),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    compact,
                    maxLines = 1,
                    style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 12.sp, fontWeight = FontWeight.Bold),
                )
                if (fresh && status.isNotEmpty() && (goal.splits || showReachedStatus || !goal.reached)) {
                    Spacer(GlanceModifier.width(6.dp))
                    Label(status, goalStatusColor(goal), size = 11)
                }
            }
        }
    }
}

@Composable
private fun GoalsContent(s: WidgetSnapshot) {
    val size = LocalSize.current
    val fresh = isFresh(s)
    val layout = GoalsLayoutPolicy.decide(size.width.value, size.height.value, s.goals.size)
    val goals = s.goals.take(layout.visible)
    val reachedStatus = GoalsLayoutPolicy.listShowsReachedStatus(size.width.value, layout.columns)
    val cellW = GoalsLayoutPolicy.cellWidth(size.width.value, layout.columns)
    val listTextW = GoalsLayoutPolicy.listTextWidth(size.width.value, layout.columns)
    val title = if (GoalsLayoutPolicy.allDaily(s.goals.map { it.period })) {
        s.label("goalsTitle", "Daily goals")
    } else {
        s.label("goalsTitleMixed", "Goals")
    }
    WidgetRoot(url = "fushi://widget/stats") {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Label(title, GlanceTheme.colors.primary, GlanceModifier.defaultWeight())
                if (!fresh) StaleHint(s)
            }
            Gap(6)
            when (layout.mode) {
                GoalsMode.HERO -> {
                    val spec = GoalsLayoutPolicy.heroSpec(size.width.value, size.height.value)
                    Box(modifier = GlanceModifier.fillMaxWidth().defaultWeight()) {
                        GoalHero(goals.first(), fresh, spec, size.width.value - GoalsLayoutPolicy.PADDING)
                    }
                }
                GoalsMode.GRID, GoalsMode.LIST -> {
                    // Compact rows on a tall widget stay centred; bigger tiers share the height evenly.
                    val fill = layout.tier != GoalsTier.COMPACT
                    Column(
                        modifier = GlanceModifier.fillMaxWidth().defaultWeight(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        goals.chunked(layout.columns).forEachIndexed { i, chunk ->
                            // Row gap as padding, not Spacer siblings: Glance caps a Column at 10 children.
                            val gap = if (i > 0) GoalsLayoutPolicy.ROW_GAP.dp else 0.dp
                            val rowModifier = GlanceModifier.fillMaxWidth().padding(top = gap)
                            Row(
                                modifier = if (fill) rowModifier.defaultWeight() else rowModifier,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                chunk.forEachIndexed { j, goal ->
                                    if (j > 0) Spacer(GlanceModifier.width(GoalsLayoutPolicy.COLUMN_GAP.dp))
                                    val cell = GlanceModifier.defaultWeight()
                                    if (layout.mode == GoalsMode.GRID) {
                                        GoalGridCell(goal, fresh, layout.tier, layout.stacked, cellW, cell)
                                    } else {
                                        GoalListRow(goal, fresh, reachedStatus, listTextW, cell)
                                    }
                                }
                                // Keep cell widths constant on a short last row.
                                repeat(layout.columns - chunk.size) {
                                    Spacer(GlanceModifier.width(GoalsLayoutPolicy.COLUMN_GAP.dp))
                                    Spacer(GlanceModifier.defaultWeight())
                                }
                            }
                        }
                    }
                }
            }
            if (layout.more > 0) {
                Label(
                    s.template("goalsMore", "+{n} more", "n" to layout.more.toString()),
                    GlanceTheme.colors.primary,
                    GlanceModifier.fillMaxWidth(),
                    11,
                )
            }
        }
    }
}

class GoalsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = GoalsWidget()
}

// ---------------------------------------------------------------------------
// Learning Streak & Activity Calendar
// ---------------------------------------------------------------------------

class StreakWidget : FushiGlanceWidget() {
    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        if (snapshot == null) SetupHint(null, "Open Fushi to set up this widget")
        else StreakContent(snapshot)
    }
}

@Composable
private fun WeekDots(s: WidgetSnapshot, dot: Dp) {
    val week = s.streakWeek
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        for (i in 0 until 7) {
            val active = week.getOrElse(i) { false }
            val isToday = i == 6
            Column(modifier = GlanceModifier.defaultWeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    modifier = GlanceModifier.size(dot).cornerRadius(dot / 2).background(
                        if (active) GlanceTheme.colors.primary else GlanceTheme.colors.surfaceVariant,
                    ),
                ) {}
                Text(
                    s.weekDays.getOrElse(i) { "" },
                    maxLines = 1,
                    style = TextStyle(
                        color = if (isToday) GlanceTheme.colors.onSurface else GlanceTheme.colors.onSurfaceVariant,
                        fontSize = 10.sp,
                        fontWeight = if (isToday) FontWeight.Bold else FontWeight.Normal,
                    ),
                )
            }
        }
    }
}

/**
 * 5 rows x 7 columns, one row per week (oldest first), columns start on the user's week start
 * day. Today sits in the last row at [todayColumn] (`WidgetSnapshot.monthTodayColumn`); the
 * cells after it are this week's remaining days and stay empty.
 */
@Composable
internal fun Heatmap(minutes: List<Int>, cell: Dp, gap: Dp = 3.dp, todayColumn: Int = 6) {
    val data = if (minutes.size >= 35) minutes.takeLast(35) else List(35 - minutes.size) { 0 } + minutes
    val todayCell = 28 + todayColumn.coerceIn(0, 6)
    val peak = data.maxOrNull() ?: 0
    Column(modifier = GlanceModifier.fillMaxWidth()) {
        for (r in 0 until 5) {
            if (r > 0) Spacer(GlanceModifier.height(gap))
            // Glance caps a Row / Column at 10 children: the gaps are padding on a wrapper
            // box, not Spacer siblings (7 cells + 6 spacers would be silently truncated).
            Row(modifier = GlanceModifier.fillMaxWidth()) {
                for (c in 0 until 7) {
                    Box(modifier = GlanceModifier.defaultWeight().padding(start = if (c > 0) gap else 0.dp)) {
                        // Grid cell -> days before today; future days of this week stay blank.
                        val ago = todayCell - (r * 7 + c)
                        if (ago >= 0) {
                            HeatCell(heatLevel(data[34 - ago], peak), GlanceModifier.fillMaxWidth().height(cell))
                        } else {
                            Spacer(GlanceModifier.fillMaxWidth().height(cell))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StreakContent(s: WidgetSnapshot) {
    val size = sizeClass()
    val longest = s.label("longest", "Longest") + " " + s.streakLongest
    val srs = s.streakSrsCurrent?.let { s.label("streakSrs", "Reviews") + " " + it }
    WidgetRoot(url = "fushi://widget/stats") {
        if (size.wide && !size.tall) {
            Row(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = GlanceModifier.defaultWeight()) {
                    Label(s.label("streak", "Streak"), GlanceTheme.colors.primary)
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            s.streak.toString(),
                            style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 36.sp, fontWeight = FontWeight.Bold),
                        )
                        Spacer(GlanceModifier.width(4.dp))
                    }
                    Label(longest, size = 11)
                    if (srs != null) Label(srs, size = 11)
                }
                Spacer(GlanceModifier.width(12.dp))
                Column(modifier = GlanceModifier.defaultWeight()) { WeekDots(s, 14.dp) }
            }
        } else {
            Column(modifier = GlanceModifier.fillMaxSize()) {
                Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                    Column(modifier = GlanceModifier.defaultWeight()) {
                        Label(s.label("streak", "Streak"), GlanceTheme.colors.primary)
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(
                                s.streak.toString(),
                                style = TextStyle(
                                    color = GlanceTheme.colors.onSurface,
                                    fontSize = if (size.large) 36.sp else 30.sp,
                                    fontWeight = FontWeight.Bold,
                                ),
                            )
                            Spacer(GlanceModifier.width(4.dp))
                        }
                    }
                    if (size.wide) {
                        Column(horizontalAlignment = Alignment.End) {
                            Label(longest, size = 11)
                            if (srs != null) Label(srs, size = 11)
                        }
                    }
                }
                if (!size.wide) {
                    Label(longest, size = 11)
                    if (srs != null) Label(srs, size = 11)
                }
                Gap(6)
                WeekDots(s, if (size.wide) 16.dp else 10.dp)
                if (size.tall && s.monthMinutes.isNotEmpty()) {
                    Gap(8)
                    Heatmap(s.monthMinutes, if (size.wide) 14.dp else 10.dp, todayColumn = s.monthTodayColumn)
                }
            }
        }
    }
}

class StreakReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = StreakWidget()
}

// ---------------------------------------------------------------------------
// Weekly & Monthly Progress (keeps WeekWidget / WeekReceiver)
// ---------------------------------------------------------------------------

class WeekWidget : FushiGlanceWidget() {
    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        if (snapshot == null || snapshot.weekMinutes.isEmpty()) SetupHint(snapshot, "Open Fushi to set up this widget")
        else WeekContent(snapshot)
    }
}

@Composable
private fun DeltaText(s: WidgetSnapshot) {
    val d = s.weekDeltaPct ?: return
    val text = (if (d > 0) "+" else "") + d + "%"
    Text(
        text,
        maxLines = 1,
        style = TextStyle(
            color = if (d >= 0) GlanceTheme.colors.primary else GlanceTheme.colors.error,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
        ),
    )
}

@Composable
private fun WeekContent(s: WidgetSnapshot) {
    val size = sizeClass()
    val peak = (s.weekMinutes.maxOrNull() ?: 0).coerceAtLeast(1)
    val last = s.weekMinutes.lastIndex
    val barMax = if (size.large) 64.dp else if (size.wide) 44.dp else 36.dp
    val barMin = 4.dp
    val extras = buildList {
        s.weekGoalDays?.let { add(s.label("weekGoalDays", "Goal days") + " " + it + "/7") }
        s.weekReviews?.let { add(s.label("weekReviews", "Reviews") + " " + it) }
    }
    WidgetRoot(url = "fushi://widget/stats") {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = GlanceModifier.defaultWeight()) {
                    Label(s.label("weekly", "Study time"), GlanceTheme.colors.primary)
                    Text(
                        s.weekTime,
                        maxLines = 1,
                        style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = if (size.wide) 22.sp else 18.sp, fontWeight = FontWeight.Bold),
                    )
                }
                Column(horizontalAlignment = Alignment.End) {
                    DeltaText(s)
                    if (size.wide && s.weekPrevTime.isNotEmpty()) {
                        Label(s.label("vsLastWeek", "vs") + " " + s.weekPrevTime, size = 11)
                    }
                }
            }
            if (size.wide && extras.isNotEmpty()) Label(extras.joinToString("  ·  "), size = 11)
            Spacer(GlanceModifier.defaultWeight())
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                s.weekMinutes.forEachIndexed { i, minutes ->
                    val barHeight = barMin + (barMax - barMin) * (minutes.toFloat() / peak)
                    Column(
                        modifier = GlanceModifier.defaultWeight(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box(modifier = GlanceModifier.fillMaxWidth().padding(horizontal = 2.dp)) {
                            Box(
                                modifier = GlanceModifier.fillMaxWidth().height(barHeight).cornerRadius(5.dp).background(
                                    if (i == last) GlanceTheme.colors.primary else GlanceTheme.colors.secondaryContainer,
                                ),
                            ) {}
                        }
                        Spacer(GlanceModifier.height(3.dp))
                        Text(
                            s.weekDays.getOrElse(i) { "" },
                            maxLines = 1,
                            style = TextStyle(
                                color = if (i == last) GlanceTheme.colors.onSurface else GlanceTheme.colors.onSurfaceVariant,
                                fontSize = 11.sp,
                            ),
                        )
                    }
                }
            }
            if (size.large && s.monthMinutes.isNotEmpty()) {
                Gap(8)
                Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Label(s.label("recentDays", "Last 35 days"), GlanceTheme.colors.onSurfaceVariant, GlanceModifier.defaultWeight(), 11)
                    if (s.monthTime.isNotEmpty()) Label(s.monthTime, size = 11)
                }
                Gap(3)
                Heatmap(s.monthMinutes, 11.dp, 2.dp, todayColumn = s.monthTodayColumn)
            }
        }
    }
}

class WeekReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = WeekWidget()
}
