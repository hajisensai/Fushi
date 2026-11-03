package app.fushi.reader.widgets

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
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
                if (showGoal) {
                    Gap(2)
                    LinearProgressIndicator(
                        progress = goalFrac,
                        modifier = GlanceModifier.fillMaxWidth(),
                        color = GlanceTheme.colors.primary,
                        backgroundColor = GlanceTheme.colors.secondaryContainer,
                    )
                    if (hasTimeGoal) Label("${(goalFrac * 100).roundToInt()}% · ${s.goalTime}", size = 11)
                }
                Gap(6)
                cats.forEach { CategoryRow(context, it, if (fresh) it.ms else 0L, if (fresh) it.time else zero, total, size.large) }
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
// Daily Learning Goals: one ring per configured goal
// ---------------------------------------------------------------------------

class GoalsWidget : FushiGlanceWidget() {
    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        if (snapshot == null) {
            SetupHint(null, "Open Fushi to set up this widget")
        } else if (snapshot.goals.isEmpty()) {
            SetupHint(snapshot, snapshot.label("noGoals", "Set goals in Fushi"), "fushi://widget/settings/widgets")
        } else {
            GoalsContent(snapshot)
        }
    }
}

@Composable
private fun GoalCell(goal: WidgetGoal, fresh: Boolean, ringSize: Dp, modifier: GlanceModifier) {
    val frac = if (fresh) goal.frac else 0f
    val done = fresh && goal.done
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(contentAlignment = Alignment.Center) {
            Ring(frac, ringSize, if (done) GlanceTheme.colors.tertiary else GlanceTheme.colors.primary)
            Text(
                if (done) "✓" else "${(frac * 100).roundToInt()}%",
                maxLines = 1,
                style = TextStyle(
                    color = GlanceTheme.colors.onSurface,
                    fontSize = if (ringSize >= 64.dp) 14.sp else 11.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
        }
        Gap(2)
        Text(
            goal.label,
            maxLines = 1,
            style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 11.sp, fontWeight = FontWeight.Medium),
        )
        Label(if (fresh) "${goal.value} / ${goal.target}" else "– / ${goal.target}", size = 10)
    }
}

@Composable
private fun GoalsContent(s: WidgetSnapshot) {
    val size = sizeClass()
    val fresh = isFresh(s)
    val perRow = if (size.wide) 4 else 2
    val rows = if (size.tall) 2 else 1
    val ringSize = if (size.wide && size.tall) 64.dp else if (size.wide) 52.dp else 56.dp
    val goals = s.goals.take(perRow * rows)
    WidgetRoot(url = "fushi://widget/stats") {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Label(s.label("goalsTitle", "Daily goals"), GlanceTheme.colors.primary)
            Gap(4)
            goals.chunked(perRow).forEach { chunk ->
                Row(
                    modifier = GlanceModifier.fillMaxWidth().defaultWeight(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    chunk.forEach { GoalCell(it, fresh, ringSize, GlanceModifier.defaultWeight()) }
                    // Keep ring sizes constant on a short last row.
                    repeat(perRow - chunk.size) { Spacer(GlanceModifier.defaultWeight()) }
                }
            }
            if (!fresh) StaleHint(s)
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

/** 5 rows x 7 columns, oldest first (row-major), today is the last cell. */
@Composable
internal fun Heatmap(minutes: List<Int>, cell: Dp, gap: Dp = 3.dp) {
    val data = if (minutes.size >= 35) minutes.takeLast(35) else List(35 - minutes.size) { 0 } + minutes
    val peak = data.maxOrNull() ?: 0
    Column(modifier = GlanceModifier.fillMaxWidth()) {
        for (r in 0 until 5) {
            if (r > 0) Spacer(GlanceModifier.height(gap))
            Row(modifier = GlanceModifier.fillMaxWidth()) {
                for (c in 0 until 7) {
                    if (c > 0) Spacer(GlanceModifier.width(gap))
                    HeatCell(heatLevel(data[r * 7 + c], peak), GlanceModifier.defaultWeight().height(cell))
                }
            }
        }
    }
}

@Composable
private fun StreakContent(s: WidgetSnapshot) {
    val size = sizeClass()
    val days = s.template("streakDays", "{n} days", "n" to "").trim()
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
                        Label(days, modifier = GlanceModifier.padding(bottom = 6.dp))
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
                            Label(days, modifier = GlanceModifier.padding(bottom = 5.dp))
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
                    Heatmap(s.monthMinutes, if (size.wide) 14.dp else 10.dp)
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
                Heatmap(s.monthMinutes, 11.dp, 2.dp)
            }
        }
    }
}

class WeekReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = WeekWidget()
}
