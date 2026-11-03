package app.fushi.reader.widgets

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.material3.ColorProviders
import androidx.glance.state.GlanceStateDefinition
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

// All colors come from GlanceTheme.colors: Material You dynamic color on Android 12+,
// the library's static Material 3 palette below that. A per-widget "light" / "dark" choice
// swaps in a fixed scheme (still dynamic on 12+, baseline Material 3 below).

internal const val MAIN_ACTIVITY = "app.fushi.reader.MainActivity"

/** Deep link into the app. Same entry as launcher shortcuts: explicit intent to MainActivity. */
internal fun openLink(context: Context, url: String): Action = actionStartActivity(
    Intent(Intent.ACTION_VIEW, Uri.parse(url))
        .setClassName(context.packageName, MAIN_ACTIVITY)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
)

internal fun mediaUrl(m: WidgetMedia): String =
    Uri.Builder().scheme("fushi").authority("widget").appendPath("continue")
        .appendQueryParameter("kind", m.kind).appendQueryParameter("id", m.id).build().toString()

internal fun lookupUrl(word: String): String =
    Uri.Builder().scheme("fushi").authority("widget").appendPath("lookup")
        .appendQueryParameter("word", word).build().toString()

private val DAY_FORMAT = SimpleDateFormat("yyyy-MM-dd", Locale.US)

private fun dayKey(millis: Long): String = synchronized(DAY_FORMAT) { DAY_FORMAT.format(Date(millis)) }

internal fun todayKey(): String = dayKey(System.currentTimeMillis())

/**
 * Whether the snapshot's "today" numbers still describe today.
 *
 * Dart's stat day key honours the user's day-reset hour, so right after midnight the app's day
 * can legitimately still be yesterday. Rule (deliberately simple): fresh when the day equals the
 * device's local date; or when it equals yesterday, it is before 06:00 and the snapshot is less
 * than 12 h old. Anything else is yesterday's data and is shown as zero + "Open Fushi to refresh".
 */
internal fun isFresh(snapshot: WidgetSnapshot, now: Long = System.currentTimeMillis()): Boolean {
    if (snapshot.day == dayKey(now)) return true
    if (snapshot.day != dayKey(now - 24L * 3600_000L)) return false
    val hour = Calendar.getInstance().apply { timeInMillis = now }.get(Calendar.HOUR_OF_DAY)
    return hour < 6 && snapshot.generatedAt > 0 && now - snapshot.generatedAt < 12L * 3600_000L
}

internal fun glyphOf(title: String): String =
    if (title.isEmpty()) "" else String(Character.toChars(title.codePointAt(0)))

/**
 * "just now" / "5 min ago" / "3 h ago" / "2 d ago": Dart-localized templates from the snapshot
 * (`agoNow` / `agoMinutes` / `agoHours` / `agoDays`), native string resources as fallback.
 */
internal fun ageText(context: Context, s: WidgetSnapshot): String {
    if (s.generatedAt <= 0) return ""
    val minutes = ((System.currentTimeMillis() - s.generatedAt) / 60_000L).coerceAtLeast(0)
    return when {
        minutes < 1 -> s.label("agoNow", context.getString(app.fushi.reader.R.string.widget_age_now))
        minutes < 60 -> s.template("agoMinutes", context.getString(app.fushi.reader.R.string.widget_age_minutes, minutes.toInt()), "n" to minutes.toString())
        minutes < 24 * 60 -> s.template("agoHours", context.getString(app.fushi.reader.R.string.widget_age_hours, (minutes / 60).toInt()), "n" to (minutes / 60).toString())
        else -> s.template("agoDays", context.getString(app.fushi.reader.R.string.widget_age_days, (minutes / (24 * 60)).toInt()), "n" to (minutes / (24 * 60)).toString())
    }
}

// ---------------------------------------------------------------------------
// Per-instance configuration (Glance preferences state, keyed by appWidgetId)
// ---------------------------------------------------------------------------

internal object WidgetPrefs {
    val THEME = stringPreferencesKey("theme") // system | light | dark
    val PRIVACY = stringPreferencesKey("privacy") // follow | show | hide
    val VOCAB_SOURCE = stringPreferencesKey("vocab_source") // all | mined | favorite
    val VOCAB_OFFSET = intPreferencesKey("vocab_offset")
    val VOCAB_OFFSET_DAY = stringPreferencesKey("vocab_offset_day")
}

data class WidgetConfig(
    val theme: String = "system",
    val privacy: String = "follow",
    val vocabSource: String = "all",
    val vocabOffset: Int = 0,
) {
    /** Priority: instance choice > app default (snapshot.privacy) > show. */
    fun hideTitles(s: WidgetSnapshot?): Boolean = when (privacy) {
        "hide" -> true
        "show" -> false
        else -> s?.privacyHideTitles ?: false
    }

    fun hideDefinitions(s: WidgetSnapshot?): Boolean = when (privacy) {
        "hide" -> true
        "show" -> false
        else -> s?.privacyHideDefinitions ?: false
    }

    companion object {
        fun from(p: Preferences): WidgetConfig {
            val today = todayKey()
            return WidgetConfig(
                theme = p[WidgetPrefs.THEME] ?: "system",
                privacy = p[WidgetPrefs.PRIVACY] ?: "follow",
                vocabSource = p[WidgetPrefs.VOCAB_SOURCE] ?: "all",
                // The "next" presses are only meaningful for the day they were made.
                vocabOffset = if (p[WidgetPrefs.VOCAB_OFFSET_DAY] == today) p[WidgetPrefs.VOCAB_OFFSET] ?: 0 else 0,
            )
        }
    }
}

private fun schemeFor(context: Context, dark: Boolean): ColorScheme =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else {
        if (dark) darkColorScheme() else lightColorScheme()
    }

@Composable
internal fun FushiTheme(mode: String, content: @Composable () -> Unit) {
    val context = LocalContext.current
    if (mode == "light" || mode == "dark") {
        val scheme = remember(mode) { schemeFor(context, mode == "dark") }
        GlanceTheme(colors = ColorProviders(light = scheme, dark = scheme), content = content)
    } else {
        GlanceTheme(content = content)
    }
}

// ---------------------------------------------------------------------------
// Sizes
// ---------------------------------------------------------------------------

internal val SIZES_RESPONSIVE: SizeMode = SizeMode.Responsive(
    setOf(
        DpSize(110.dp, 110.dp),
        DpSize(110.dp, 220.dp),
        DpSize(250.dp, 110.dp),
        DpSize(250.dp, 220.dp),
    ),
)

internal class SizeClass(val wide: Boolean, val tall: Boolean) {
    /** Roomy in both directions: show the full layout. */
    val large: Boolean get() = wide && tall
}

@Composable
internal fun sizeClass(): SizeClass {
    val size = LocalSize.current
    return SizeClass(wide = size.width >= 220.dp, tall = size.height >= 190.dp)
}

/**
 * Base for every Fushi widget: Responsive size set, per-instance preferences state,
 * theme override, and the snapshot collected inside the composition.
 */
abstract class FushiGlanceWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SIZES_RESPONSIVE
    override val stateDefinition: GlanceStateDefinition<*> = PreferencesGlanceStateDefinition

    /** Extra work before the first frame (e.g. reading AnkiDroid off the main thread). */
    protected open suspend fun prepare(context: Context) {}

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        prepare(context)
        provideContent {
            val cfg = WidgetConfig.from(currentState<Preferences>())
            FushiTheme(cfg.theme) {
                Content(context, rememberSnapshot(context), cfg)
            }
        }
    }

    @Composable
    abstract fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig)
}

/** Writes per-instance values into the widget's Glance state and re-renders that instance. */
internal suspend fun updateWidgetPrefs(
    context: Context,
    widget: GlanceAppWidget,
    id: GlanceId,
    block: (androidx.datastore.preferences.core.MutablePreferences) -> Unit,
) {
    updateAppWidgetState(context, PreferencesGlanceStateDefinition, id) { prefs ->
        prefs.toMutablePreferences().also(block)
    }
    widget.update(context, id)
}

/**
 * The current snapshot, re-read whenever Flutter stores a new one. Glance does not call
 * `provideGlance` again for a session that is still running, so widgets must observe the
 * store from inside the composition (see [WidgetStore.changes]).
 */
@Composable
internal fun rememberSnapshot(context: Context): WidgetSnapshot? {
    val initial = remember { WidgetStore.load(context) }
    val flow = remember { WidgetStore.changes(context) }
    return flow.collectAsState(initial).value
}

// ---------------------------------------------------------------------------
// Shared building blocks
// ---------------------------------------------------------------------------

@Composable
internal fun WidgetRoot(url: String?, action: Action? = null, content: @Composable () -> Unit) {
    val context = LocalContext.current
    var modifier = GlanceModifier.fillMaxSize().background(GlanceTheme.colors.widgetBackground)
    modifier = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        modifier.cornerRadius(android.R.dimen.system_app_widget_background_radius)
    } else {
        modifier.cornerRadius(20.dp)
    }
    modifier = modifier.padding(12.dp)
    if (action != null) modifier = modifier.clickable(action)
    else if (url != null) modifier = modifier.clickable(openLink(context, url))
    Box(modifier = modifier, content = content)
}

@Composable
internal fun Label(
    text: String,
    color: ColorProvider = GlanceTheme.colors.onSurfaceVariant,
    modifier: GlanceModifier = GlanceModifier,
    size: Int = 12,
) = Text(text, modifier = modifier, maxLines = 1, style = TextStyle(color = color, fontSize = size.sp))

@Composable
internal fun Title(text: String, size: Int = 15, maxLines: Int = 2, modifier: GlanceModifier = GlanceModifier) =
    Text(
        text,
        modifier = modifier,
        maxLines = maxLines,
        style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = size.sp, fontWeight = FontWeight.Bold),
    )

@Composable
internal fun Chip(text: String, modifier: GlanceModifier = GlanceModifier) {
    Box(
        modifier = modifier.cornerRadius(20.dp).background(GlanceTheme.colors.primary)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            maxLines = 1,
            style = TextStyle(color = GlanceTheme.colors.onPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium),
        )
    }
}

@Composable
internal fun Cover(media: WidgetMedia, bitmap: Bitmap?, modifier: GlanceModifier, glyphSize: Int = 24, hidden: Boolean = false) {
    if (bitmap != null && !hidden) {
        Image(
            provider = ImageProvider(bitmap),
            contentDescription = media.title,
            contentScale = ContentScale.Crop,
            modifier = modifier.cornerRadius(10.dp),
        )
    } else {
        Box(
            modifier = modifier.cornerRadius(10.dp).background(GlanceTheme.colors.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (hidden) "" else glyphOf(media.title),
                style = TextStyle(
                    color = GlanceTheme.colors.onPrimaryContainer,
                    fontSize = glyphSize.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
        }
    }
}

/**
 * Generic "open Fushi" hint. With a [snapshot] the localized `openToSetUp` label wins over
 * [fallback]; pass `null` to show a specific (already localized) empty-state message verbatim.
 */
@Composable
internal fun SetupHint(snapshot: WidgetSnapshot?, fallback: String, url: String = "fushi://widget/open") {
    WidgetRoot(url = url) {
        Column(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                snapshot?.label("openToSetUp", fallback) ?: fallback,
                maxLines = 4,
                style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 13.sp),
            )
        }
    }
}

@Composable
internal fun StaleHint(snapshot: WidgetSnapshot) {
    Label(snapshot.label("openToRefresh", "Open Fushi to refresh"), GlanceTheme.colors.error, size = 11)
}

/** A progress ring drawn with Canvas (Glance has no arc primitive), tinted with theme colors. */
@Composable
internal fun Ring(frac: Float, size: Dp, color: ColorProvider, modifier: GlanceModifier = GlanceModifier) {
    val bitmap = remember(frac) { ringBitmap(frac.coerceIn(0f, 1f)) }
    Image(
        provider = ImageProvider(bitmap),
        contentDescription = null,
        colorFilter = ColorFilter.tint(color),
        modifier = modifier.size(size),
    )
}

private const val RING_PX = 128

/** White ring on transparent: faint full track + opaque arc; tinted by the caller. */
private fun ringBitmap(frac: Float): Bitmap {
    val bmp = Bitmap.createBitmap(RING_PX, RING_PX, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    val strokePx = RING_PX * 0.13f
    val inset = strokePx / 2f + 1f
    val rect = RectF(inset, inset, RING_PX - inset, RING_PX - inset)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = strokePx
        strokeCap = Paint.Cap.ROUND
        color = android.graphics.Color.WHITE
    }
    paint.alpha = 64
    canvas.drawArc(rect, 0f, 360f, false, paint)
    if (frac > 0f) {
        paint.alpha = 255
        canvas.drawArc(rect, -90f, 360f * frac, false, paint)
    }
    return bmp
}

/**
 * Heatmap intensity color: 0 = empty cell, 1..4 = primary at rising opacity.
 * Resolved against the current night mode so it follows the widget theme.
 */
@Composable
internal fun heatColor(level: Int): ColorProvider {
    val context = LocalContext.current
    if (level <= 0) return GlanceTheme.colors.surfaceVariant
    val base = GlanceTheme.colors.primary.getColor(context)
    return ColorProvider(base.copy(alpha = (0.25f * level).coerceAtMost(1f)))
}

/** Bucket minutes into 0..4 relative to the busiest day of the series. */
internal fun heatLevel(minutes: Int, peak: Int): Int = when {
    minutes <= 0 -> 0
    peak <= 0 -> 1
    else -> (1 + (minutes.toFloat() / peak * 3.999f).toInt()).coerceIn(1, 4)
}

@Composable
internal fun HeatCell(level: Int, modifier: GlanceModifier) {
    Box(modifier = modifier.cornerRadius(3.dp).background(heatColor(level))) {}
}

@Composable
internal fun Gap(h: Int) = Spacer(GlanceModifier.height(h.dp))

internal val MIN_TOUCH: Dp = 48.dp

/** Every placed widget class, for `refreshAll` and the configuration screen. */
internal object WidgetRegistry {
    val all: List<GlanceAppWidget> = listOf(
        ContinueWidget(), TodayWidget(), SrsWidget(), ShelfWidget(), WeekWidget(), ShortcutsWidget(),
        GoalsWidget(), StreakWidget(), VocabWidget(), NowPlayingWidget(),
    )

    /** Widget instance for an appwidget-provider receiver class name, or null. */
    fun forReceiver(className: String): GlanceAppWidget? = when (className.substringAfterLast('.')) {
        "ContinueReceiver" -> all[0]
        "TodayReceiver" -> all[1]
        "SrsReceiver" -> all[2]
        "ShelfReceiver" -> all[3]
        "WeekReceiver" -> all[4]
        "ShortcutsReceiver" -> all[5]
        "GoalsReceiver" -> all[6]
        "StreakReceiver" -> all[7]
        "VocabReceiver" -> all[8]
        "NowPlayingReceiver" -> all[9]
        else -> null
    }
}
