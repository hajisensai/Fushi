package app.fushi.reader.widgets

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
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
import androidx.glance.unit.ColorProvider
import app.fushi.reader.R
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

// All colors come from GlanceTheme.colors: Material You dynamic color on Android 12+,
// the library's static Material 3 palette below that. The app's own custom themes are
// intentionally not mirrored here.

private const val MAIN_ACTIVITY = "app.fushi.reader.MainActivity"

/** Deep link into the app. Same entry as launcher shortcuts: explicit intent to MainActivity. */
private fun openLink(context: Context, url: String): Action = actionStartActivity(
    Intent(Intent.ACTION_VIEW, Uri.parse(url))
        .setClassName(context.packageName, MAIN_ACTIVITY)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
)

private fun mediaUrl(m: WidgetMedia): String =
    Uri.Builder().scheme("fushi").authority("widget").appendPath("continue")
        .appendQueryParameter("kind", m.kind).appendQueryParameter("id", m.id).build().toString()

/**
 * The current snapshot, re-read whenever Flutter stores a new one. Glance does not call
 * `provideGlance` again for a session that is still running, so widgets must observe the
 * store from inside the composition (see [WidgetStore.changes]).
 */
@Composable
private fun rememberSnapshot(context: Context): WidgetSnapshot? {
    val initial = remember { WidgetStore.load(context) }
    val flow = remember { WidgetStore.changes(context) }
    return flow.collectAsState(initial).value
}

private fun todayKey(): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

private fun glyphOf(title: String): String =
    if (title.isEmpty()) "" else String(Character.toChars(title.codePointAt(0)))

@Composable
private fun WidgetRoot(url: String?, content: @Composable () -> Unit) {
    val context = androidx.glance.LocalContext.current
    var modifier = GlanceModifier.fillMaxSize().background(GlanceTheme.colors.widgetBackground)
    modifier = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        modifier.cornerRadius(android.R.dimen.system_app_widget_background_radius)
    } else {
        modifier.cornerRadius(20.dp)
    }
    modifier = modifier.padding(12.dp)
    if (url != null) modifier = modifier.clickable(openLink(context, url))
    Box(modifier = modifier, content = content)
}

@Composable
private fun Label(text: String, color: ColorProvider = GlanceTheme.colors.onSurfaceVariant, modifier: GlanceModifier = GlanceModifier) =
    Text(text, modifier = modifier, maxLines = 1, style = TextStyle(color = color, fontSize = 12.sp))

@Composable
private fun Cover(media: WidgetMedia, bitmap: android.graphics.Bitmap?, modifier: GlanceModifier, glyphSize: Int = 24) {
    if (bitmap != null) {
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
                glyphOf(media.title),
                style = TextStyle(
                    color = GlanceTheme.colors.onPrimaryContainer,
                    fontSize = glyphSize.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
        }
    }
}

@Composable
private fun SetupHint(context: Context, snapshot: WidgetSnapshot?, fallback: String) {
    WidgetRoot(url = "fushi://widget/open") {
        Column(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                snapshot?.label("openToSetUp", fallback) ?: fallback,
                style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 13.sp),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Continue (4x2)
// ---------------------------------------------------------------------------

class ContinueWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Single

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            GlanceTheme {
                val snapshot = rememberSnapshot(context)
                val item = snapshot?.continueItem
                val bitmap = remember(item?.cover) { WidgetBitmaps.load(item?.cover, 320) }
                if (snapshot == null || item == null) {
                    SetupHint(context, snapshot, "Open a book, manga or video in Fushi to continue here")
                } else {
                    ContinueContent(snapshot, item, bitmap)
                }
            }
        }
    }
}

@Composable
private fun ContinueContent(snapshot: WidgetSnapshot, item: WidgetMedia, bitmap: android.graphics.Bitmap?) {
    val kindLabel = snapshot.label(
        "kind_${item.kind}",
        item.kind.replaceFirstChar { it.uppercase() },
    )
    WidgetRoot(url = mediaUrl(item)) {
        Row(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            Cover(item, bitmap, GlanceModifier.width(64.dp).fillMaxHeight(), glyphSize = 28)
            Spacer(GlanceModifier.width(12.dp))
            Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
                Label(kindLabel, GlanceTheme.colors.primary)
                Text(
                    item.title,
                    maxLines = 2,
                    style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 15.sp, fontWeight = FontWeight.Bold),
                )
                if (item.subtitle.isNotEmpty()) Label(item.subtitle)
                Spacer(GlanceModifier.height(8.dp))
                Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    LinearProgressIndicator(
                        progress = item.progress,
                        modifier = GlanceModifier.defaultWeight(),
                        color = GlanceTheme.colors.primary,
                        backgroundColor = GlanceTheme.colors.secondaryContainer,
                    )
                    Spacer(GlanceModifier.width(8.dp))
                    // Rounded, like the Continue cards in the app (dashboard, shelf banner), so
                    // the widget and the app agree. Started but under 1% must not read "0%".
                    val percent = (item.progress * 100).roundToInt().let { if (it == 0 && item.progress > 0f) 1 else it }
                    Label("$percent%")
                }
                Spacer(GlanceModifier.height(4.dp))
                Text(
                    snapshot.label("resume", "Resume"),
                    style = TextStyle(color = GlanceTheme.colors.primary, fontSize = 13.sp, fontWeight = FontWeight.Medium),
                )
            }
        }
    }
}

class ContinueReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ContinueWidget()
}

// ---------------------------------------------------------------------------
// Today (2x2)
// ---------------------------------------------------------------------------

class TodayWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Single

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            GlanceTheme {
                val snapshot = rememberSnapshot(context)
                if (snapshot == null) SetupHint(context, null, "Open Fushi to set up this widget")
                else TodayContent(snapshot)
            }
        }
    }
}

@Composable
private fun TodayContent(snapshot: WidgetSnapshot) {
    // The snapshot is only rewritten while the app runs; after midnight the numbers are
    // yesterday's, so show a dash instead of presenting them as today's.
    val fresh = snapshot.day == todayKey()
    WidgetRoot(url = "fushi://widget/stats") {
        Column(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.Top) {
            Label(snapshot.label("today", "Today"), GlanceTheme.colors.primary)
            Spacer(GlanceModifier.height(2.dp))
            Text(
                if (fresh) snapshot.todayTime else "–",
                style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 26.sp, fontWeight = FontWeight.Bold),
            )
            Label(if (fresh) snapshot.todayChars else "")
            Spacer(GlanceModifier.height(6.dp))
            if (snapshot.todayGoal > 0f && fresh) {
                LinearProgressIndicator(
                    progress = snapshot.todayGoal,
                    modifier = GlanceModifier.fillMaxWidth(),
                    color = GlanceTheme.colors.primary,
                    backgroundColor = GlanceTheme.colors.secondaryContainer,
                )
            }
            Spacer(GlanceModifier.defaultWeight())
            Label(snapshot.label("streak", "Streak") + " " + snapshot.streak)
        }
    }
}

class TodayReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = TodayWidget()
}

// ---------------------------------------------------------------------------
// SRS due (2x2)
// ---------------------------------------------------------------------------

class SrsWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Single

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            GlanceTheme {
                val snapshot = rememberSnapshot(context)
                if (snapshot == null) SetupHint(context, null, "Open Fushi to set up this widget")
                else SrsContent(snapshot)
            }
        }
    }
}

@Composable
private fun SrsContent(snapshot: WidgetSnapshot) {
    WidgetRoot(url = if (snapshot.srsEnabled) "fushi://widget/srs" else "fushi://widget/open") {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Label(snapshot.label("srsDue", "Cards due"), GlanceTheme.colors.primary)
            Spacer(GlanceModifier.defaultWeight())
            when {
                !snapshot.srsEnabled -> Text(
                    snapshot.label("srsOff", "Review is turned off"),
                    style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 13.sp),
                )
                snapshot.srsDue > 0 -> {
                    Text(
                        snapshot.srsDue.toString(),
                        style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 40.sp, fontWeight = FontWeight.Bold),
                    )
                    Spacer(GlanceModifier.height(6.dp))
                    Box(
                        modifier = GlanceModifier.cornerRadius(20.dp).background(GlanceTheme.colors.primary)
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                    ) {
                        Text(
                            snapshot.label("review", "Review"),
                            style = TextStyle(color = GlanceTheme.colors.onPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium),
                        )
                    }
                }
                else -> Text(
                    snapshot.label("srsDone", "All done"),
                    style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 20.sp, fontWeight = FontWeight.Bold),
                )
            }
        }
    }
}

class SrsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SrsWidget()
}

// ---------------------------------------------------------------------------
// Library shelf (4x2)
// ---------------------------------------------------------------------------

class ShelfWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Single

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            GlanceTheme {
                val snapshot = rememberSnapshot(context)
                val covers = remember(snapshot?.shelf) {
                    snapshot?.shelf?.take(4)?.map { it to WidgetBitmaps.load(it.cover, 240) }.orEmpty()
                }
                if (snapshot == null || covers.isEmpty()) {
                    SetupHint(context, snapshot, "Open something in Fushi to fill your shelf")
                } else {
                    ShelfContent(snapshot, covers)
                }
            }
        }
    }
}

@Composable
private fun ShelfContent(snapshot: WidgetSnapshot, covers: List<Pair<WidgetMedia, android.graphics.Bitmap?>>) {
    val context = androidx.glance.LocalContext.current
    WidgetRoot(url = null) {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Label(snapshot.label("recent", "Recently opened"), GlanceTheme.colors.primary)
            Spacer(GlanceModifier.height(6.dp))
            Row(modifier = GlanceModifier.fillMaxWidth().defaultWeight()) {
                covers.forEachIndexed { index, (media, bitmap) ->
                    if (index > 0) Spacer(GlanceModifier.width(8.dp))
                    Column(
                        modifier = GlanceModifier.defaultWeight().fillMaxHeight()
                            .clickable(openLink(context, mediaUrl(media))),
                    ) {
                        Cover(media, bitmap, GlanceModifier.fillMaxWidth().defaultWeight())
                        Spacer(GlanceModifier.height(3.dp))
                        Text(
                            media.title,
                            maxLines = 1,
                            style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 11.sp),
                        )
                    }
                }
                // Keep covers a constant width when fewer than four are available.
                repeat(4 - covers.size) {
                    Spacer(GlanceModifier.width(8.dp))
                    Spacer(GlanceModifier.defaultWeight())
                }
            }
        }
    }
}

class ShelfReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ShelfWidget()
}

// ---------------------------------------------------------------------------
// Weekly activity (4x2)
// ---------------------------------------------------------------------------

class WeekWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Single

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            GlanceTheme {
                val snapshot = rememberSnapshot(context)
                if (snapshot == null || snapshot.weekMinutes.isEmpty()) {
                    SetupHint(context, snapshot, "Open Fushi to set up this widget")
                } else {
                    WeekContent(snapshot)
                }
            }
        }
    }
}

private val BAR_MAX: Dp = 48.dp
private val BAR_MIN: Dp = 4.dp

@Composable
private fun WeekContent(snapshot: WidgetSnapshot) {
    val peak = (snapshot.weekMinutes.maxOrNull() ?: 0).coerceAtLeast(1)
    val last = snapshot.weekMinutes.lastIndex
    WidgetRoot(url = "fushi://widget/stats") {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Label(snapshot.label("weekly", "Study time"), GlanceTheme.colors.primary, GlanceModifier.defaultWeight())
                Label(snapshot.weekTime + "  " + snapshot.weekChars)
            }
            Spacer(GlanceModifier.defaultWeight())
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                snapshot.weekMinutes.forEachIndexed { i, minutes ->
                    val barHeight = BAR_MIN + (BAR_MAX - BAR_MIN) * (minutes.toFloat() / peak)
                    Column(
                        modifier = GlanceModifier.defaultWeight(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box(
                            modifier = GlanceModifier.width(18.dp).height(barHeight).cornerRadius(5.dp).background(
                                if (i == last) GlanceTheme.colors.primary else GlanceTheme.colors.secondaryContainer,
                            ),
                        ) {}
                        Spacer(GlanceModifier.height(3.dp))
                        Text(
                            snapshot.weekDays.getOrElse(i) { "" },
                            style = TextStyle(
                                color = if (i == last) GlanceTheme.colors.onSurface else GlanceTheme.colors.onSurfaceVariant,
                                fontSize = 11.sp,
                            ),
                        )
                    }
                }
            }
        }
    }
}

class WeekReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = WeekWidget()
}

// ---------------------------------------------------------------------------
// Shortcuts (4x1)
// ---------------------------------------------------------------------------

class ShortcutsWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Single

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            GlanceTheme { ShortcutsContent(rememberSnapshot(context)) }
        }
    }
}

private class ShortcutEntry(val id: String, val label: String, val icon: Int)

@Composable
private fun ShortcutsContent(snapshot: WidgetSnapshot?) {
    val context = androidx.glance.LocalContext.current
    // Before the first snapshot arrives every shortcut is shown; afterwards modules the user
    // turned off in Fushi drop out.
    val entries = buildList {
        if (snapshot?.moduleBooks != false) add(ShortcutEntry("books", snapshot?.label("books", "Books") ?: "Books", R.drawable.ic_widget_books))
        if (snapshot?.moduleManga != false) add(ShortcutEntry("manga", snapshot?.label("manga", "Manga") ?: "Manga", R.drawable.ic_widget_manga))
        if (snapshot?.moduleVideo != false) add(ShortcutEntry("video", snapshot?.label("video", "Video") ?: "Video", R.drawable.ic_widget_video))
        if (snapshot?.moduleLookup != false) add(ShortcutEntry("lookup", snapshot?.label("lookup", "Lookup") ?: "Lookup", R.drawable.ic_widget_lookup))
    }
    WidgetRoot(url = null) {
        Row(
            modifier = GlanceModifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            entries.forEach { entry ->
                Column(
                    modifier = GlanceModifier.defaultWeight().fillMaxHeight()
                        .clickable(openLink(context, "fushi://shortcut/${entry.id}")),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = GlanceModifier.size(32.dp).cornerRadius(12.dp)
                            .background(GlanceTheme.colors.secondaryContainer),
                        contentAlignment = Alignment.Center,
                    ) {
                        Image(
                            provider = ImageProvider(entry.icon),
                            contentDescription = entry.label,
                            colorFilter = ColorFilter.tint(GlanceTheme.colors.onSecondaryContainer),
                            modifier = GlanceModifier.size(20.dp),
                        )
                    }
                    Spacer(GlanceModifier.height(2.dp))
                    Text(
                        entry.label,
                        maxLines = 1,
                        style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 10.sp),
                    )
                }
            }
        }
    }
}

class ShortcutsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ShortcutsWidget()
}
