package app.fushi.reader.widgets

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider

// Widgets in this file: Downloads and On deck (media-server items). Both only render the snapshot
// Flutter pushes (`downloads` / `onDeck` blocks, docs/agent/android-widgets.md).

private const val DOWNLOADS_URL = "fushi://widget/downloads"

/** While tasks run the app pushes every ~5 s; a snapshot older than this is shown "as of <age>". */
private const val DOWNLOADS_STALE_MS = 90_000L

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

class DownloadsWidget : FushiGlanceWidget() {
    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        val d = snapshot?.downloads
        if (snapshot == null || d == null || d.count <= 0) {
            SetupHint(null, snapshot?.label("noDownloads", "No active downloads") ?: "No active downloads", DOWNLOADS_URL)
        } else {
            DownloadsContent(context, snapshot, d, cfg.hideTitles(snapshot))
        }
    }
}

@Composable
private fun DownloadsContent(context: Context, s: WidgetSnapshot, d: WidgetDownloads, hide: Boolean) {
    val size = sizeClass()
    // The app stops pushing when it dies: running tasks with an old snapshot show its age instead
    // of a speed that is no longer true.
    val stale = d.running > 0 && s.generatedAt > 0 && System.currentTimeMillis() - s.generatedAt > DOWNLOADS_STALE_MS
    val title = s.label("downloadsTitle", "Downloads")
    val rows = if (size.tall) d.tasks else emptyList()
    WidgetRoot(url = DOWNLOADS_URL) {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Label(title, GlanceTheme.colors.primary, GlanceModifier.defaultWeight())
                Label(
                    if (d.running > 0) s.template("downloadsActive", "{n} active", "n" to d.running.toString()) else "${d.count}",
                    size = 11,
                )
            }
            Gap(4)
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    d.percent?.let { "$it%" } ?: "…",
                    style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 22.sp, fontWeight = FontWeight.Bold),
                )
                Spacer(GlanceModifier.width(10.dp))
                if (d.percent != null) {
                    LinearProgressIndicator(
                        progress = d.percent / 100f,
                        modifier = GlanceModifier.defaultWeight().semantics { contentDescription = "$title ${d.percent}%" },
                        color = GlanceTheme.colors.primary,
                        backgroundColor = GlanceTheme.colors.secondaryContainer,
                    )
                } else {
                    Spacer(GlanceModifier.defaultWeight())
                }
            }
            val sub = when {
                stale -> s.template("updatedAgo", "Updated {age}", "age" to ageText(context, s))
                d.speed.isNotEmpty() -> d.speed
                else -> ""
            }
            if (sub.isNotEmpty()) Label(sub, if (stale) GlanceTheme.colors.error else GlanceTheme.colors.onSurfaceVariant, size = 11)
            if (rows.isNotEmpty()) {
                Gap(8)
                rows.forEachIndexed { index, task ->
                    if (index > 0) Gap(6)
                    DownloadRow(s, task, index + 1, hide, stale)
                }
            }
        }
    }
}

@Composable
private fun DownloadRow(s: WidgetSnapshot, task: WidgetDownloadTask, number: Int, hide: Boolean, stale: Boolean) {
    val stateLabel = when (task.state) {
        "queued" -> s.label("downloadQueued", "Queued")
        "paused" -> s.label("downloadPaused", "Paused")
        "failed" -> s.label("downloadFailed", "Failed")
        else -> if (stale) "" else task.speed
    }
    val name = if (hide) "${s.label("downloadsTitle", "Downloads")} $number" else task.title
    val color: ColorProvider = if (task.state == "failed") GlanceTheme.colors.error else GlanceTheme.colors.onSurface
    Column(modifier = GlanceModifier.fillMaxWidth()) {
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                name,
                maxLines = 1,
                modifier = GlanceModifier.defaultWeight(),
                style = TextStyle(color = color, fontSize = 12.sp),
            )
            Spacer(GlanceModifier.width(6.dp))
            Label(
                listOfNotNull(task.percent?.let { "$it%" }, stateLabel.ifEmpty { null }).joinToString(" · "),
                size = 11,
            )
        }
        if (task.percent != null && task.state != "failed") {
            Spacer(GlanceModifier.height(2.dp))
            LinearProgressIndicator(
                progress = task.percent / 100f,
                modifier = GlanceModifier.fillMaxWidth().semantics {
                    contentDescription = "$name ${task.percent}%"
                },
                color = if (task.state == "paused") GlanceTheme.colors.outline else GlanceTheme.colors.primary,
                backgroundColor = GlanceTheme.colors.secondaryContainer,
            )
        }
    }
}

class DownloadsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = DownloadsWidget()
}

// ---------------------------------------------------------------------------
// On deck (media servers)
// ---------------------------------------------------------------------------

class OnDeckWidget : FushiGlanceWidget() {
    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        val deck = snapshot?.onDeck
        val hide = cfg.hideTitles(snapshot)
        val items = deck?.items.orEmpty().take(4)
        val covers = remember(items, hide) { items.map { it to (if (hide) null else WidgetBitmaps.load(it.cover, 240)) } }
        if (snapshot == null || deck == null || deck.state != "ok" || items.isEmpty()) {
            val message = when (deck?.state) {
                "off" -> snapshot?.label("onDeckOff", "Server items are off: enable them in the media server settings")
                    ?: "Server items are off"
                "ok" -> snapshot?.label("onDeckEmpty", "Nothing in progress") ?: "Nothing in progress"
                else -> snapshot?.label("onDeckNoServers", "No media servers") ?: "No media servers"
            }
            SetupHint(null, message)
        } else {
            OnDeckContent(context, snapshot, covers, hide)
        }
    }
}

@Composable
private fun OnDeckContent(
    context: Context,
    s: WidgetSnapshot,
    items: List<Pair<WidgetOnDeckItem, android.graphics.Bitmap?>>,
    hide: Boolean,
) {
    val size = sizeClass()
    val header = s.label("onDeckTitle", "On deck")
    WidgetRoot(url = null) {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Label(header, GlanceTheme.colors.primary)
            Gap(6)
            if (size.tall) {
                // List layout: one row per item with a small cover, progress and server name.
                val rows = items.take(if (size.wide) 4 else 3)
                Column(modifier = GlanceModifier.fillMaxWidth().defaultWeight()) {
                    rows.forEachIndexed { index, (item, bitmap) ->
                        if (index > 0) Gap(6)
                        OnDeckRow(context, s, item, bitmap, hide)
                    }
                }
            } else {
                // Compact layout: covers side by side (fewer on a narrow widget), title underneath.
                val shown = if (size.wide) items else items.take(2)
                Row(modifier = GlanceModifier.fillMaxWidth().defaultWeight()) {
                    shown.forEachIndexed { index, (item, bitmap) ->
                        if (index > 0) Spacer(GlanceModifier.width(8.dp))
                        Column(
                            modifier = GlanceModifier.defaultWeight().fillMaxHeight()
                                .clickable(openLink(context, item.link)),
                        ) {
                            Cover(item.asMedia(), bitmap, GlanceModifier.fillMaxWidth().defaultWeight(), hidden = hide)
                            Spacer(GlanceModifier.height(3.dp))
                            Text(
                                if (hide) s.label("kind_${item.kind}", item.kind) else item.title,
                                maxLines = 1,
                                style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 11.sp),
                            )
                        }
                    }
                    // Keep covers a constant width when fewer than the target are available.
                    val target = if (size.wide) 4 else 2
                    repeat((target - shown.size).coerceAtLeast(0)) {
                        Spacer(GlanceModifier.width(8.dp))
                        Spacer(GlanceModifier.defaultWeight())
                    }
                }
            }
        }
    }
}

@Composable
private fun OnDeckRow(
    context: Context,
    s: WidgetSnapshot,
    item: WidgetOnDeckItem,
    bitmap: android.graphics.Bitmap?,
    hide: Boolean,
) {
    val kind = s.label("kind_${item.kind}", item.kind)
    val title = if (hide) kind else item.title
    val detail = if (hide) "" else listOf(item.subtitle, item.server).filter { it.isNotEmpty() }.joinToString(" · ")
    Row(
        modifier = GlanceModifier.fillMaxWidth().padding(vertical = 1.dp).clickable(openLink(context, item.link)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Cover(item.asMedia(), bitmap, GlanceModifier.width(34.dp).height(46.dp), glyphSize = 16, hidden = hide)
        Spacer(GlanceModifier.width(10.dp))
        Column(modifier = GlanceModifier.defaultWeight()) {
            Text(
                title,
                maxLines = 1,
                style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 13.sp, fontWeight = FontWeight.Medium),
            )
            if (detail.isNotEmpty()) Label(detail, size = 11)
            if (item.progress > 0f) {
                Spacer(GlanceModifier.height(3.dp))
                Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    LinearProgressIndicator(
                        progress = item.progress,
                        modifier = GlanceModifier.defaultWeight().semantics {
                            contentDescription = "$title ${item.position}"
                        },
                        color = GlanceTheme.colors.primary,
                        backgroundColor = GlanceTheme.colors.secondaryContainer,
                    )
                    Spacer(GlanceModifier.width(6.dp))
                    Label(item.position, size = 11)
                }
            }
        }
    }
}

class OnDeckReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = OnDeckWidget()
}
