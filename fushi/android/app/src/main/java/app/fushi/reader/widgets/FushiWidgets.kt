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
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import kotlin.math.roundToInt

// Widgets in this file: Continue learning and Library shelf. Shared helpers live in
// WidgetCommon.kt; the other widgets are in WidgetsToday.kt / SrsWidget.kt / VocabWidget.kt /
// ShortcutsWidget.kt.

// ---------------------------------------------------------------------------
// Continue learning
// ---------------------------------------------------------------------------

class ContinueWidget : FushiGlanceWidget() {
    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        val item = snapshot?.continueItem
        val hide = cfg.hideTitles(snapshot)
        val bitmap = remember(item?.cover, hide) { if (hide) null else WidgetBitmaps.load(item?.cover, 320) }
        if (snapshot == null || item == null) {
            SetupHint(snapshot, "Open a book, manga or video in Fushi to continue here")
        } else {
            ContinueContent(snapshot, item, bitmap, hide)
        }
    }
}

@Composable
private fun ContinueContent(snapshot: WidgetSnapshot, item: WidgetMedia, bitmap: android.graphics.Bitmap?, hide: Boolean) {
    val size = sizeClass()
    val kindLabel = snapshot.label("kind_${item.kind}", item.kind.replaceFirstChar { it.uppercase() })
    // Privacy: the kind label stands in for the title, and there is no cover.
    val title = if (hide) kindLabel else item.title
    val percent = (item.progress * 100).roundToInt().let { if (it == 0 && item.progress > 0f) 1 else it }
    WidgetRoot(url = mediaUrl(item)) {
        Row(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            if (size.wide || size.tall) {
                Cover(item, bitmap, GlanceModifier.width(if (size.wide) 64.dp else 56.dp).fillMaxHeight(), glyphSize = 28, hidden = hide)
                Spacer(GlanceModifier.width(12.dp))
            }
            Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
                Label(if (hide) snapshot.label("resume", "Continue") else kindLabel, GlanceTheme.colors.primary)
                Title(title, maxLines = if (size.tall) 3 else 2)
                if (!hide && item.subtitle.isNotEmpty()) Label(item.subtitle)
                Spacer(GlanceModifier.height(8.dp))
                Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    LinearProgressIndicator(
                        progress = item.progress,
                        modifier = GlanceModifier.defaultWeight(),
                        color = GlanceTheme.colors.primary,
                        backgroundColor = GlanceTheme.colors.secondaryContainer,
                    )
                    Spacer(GlanceModifier.width(8.dp))
                    // Rounded, like the Continue cards in the app, so the widget and the app
                    // agree. Started but under 1% must not read "0%".
                    Label("${item.position.ifEmpty { "$percent%" }}")
                }
                // Time to finish: only present when Dart could estimate it honestly.
                if (item.remaining.isNotEmpty()) {
                    Spacer(GlanceModifier.height(2.dp))
                    Label(item.remaining, GlanceTheme.colors.onSurface, size = 12)
                }
                if (item.lastActive.isNotEmpty() && (size.wide || size.tall)) {
                    Spacer(GlanceModifier.height(2.dp))
                    Label(item.lastActive, size = 11)
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
    override val glanceAppWidget = ContinueWidget()
}

// ---------------------------------------------------------------------------
// Library shelf
// ---------------------------------------------------------------------------

class ShelfWidget : FushiGlanceWidget() {
    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        val hide = cfg.hideTitles(snapshot)
        val covers = remember(snapshot?.shelf, hide) {
            snapshot?.shelf?.take(4)?.map { it to (if (hide) null else WidgetBitmaps.load(it.cover, 240)) }.orEmpty()
        }
        if (snapshot == null || covers.isEmpty()) {
            SetupHint(snapshot, "Open something in Fushi to fill your shelf")
        } else {
            ShelfContent(context, snapshot, covers, hide)
        }
    }
}

@Composable
private fun ShelfContent(
    context: Context,
    snapshot: WidgetSnapshot,
    covers: List<Pair<WidgetMedia, android.graphics.Bitmap?>>,
    hide: Boolean,
) {
    val size = sizeClass()
    // Narrow widgets show fewer covers instead of squeezing four into 110dp.
    val shown = if (size.wide) covers else covers.take(2)
    WidgetRoot(url = null) {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Label(snapshot.label("recent", "Recently opened"), GlanceTheme.colors.primary)
            Spacer(GlanceModifier.height(6.dp))
            Row(modifier = GlanceModifier.fillMaxWidth().defaultWeight()) {
                shown.forEachIndexed { index, (media, bitmap) ->
                    if (index > 0) Spacer(GlanceModifier.width(8.dp))
                    Column(
                        modifier = GlanceModifier.defaultWeight().fillMaxHeight()
                            .clickable(openLink(context, mediaUrl(media))),
                    ) {
                        Cover(media, bitmap, GlanceModifier.fillMaxWidth().defaultWeight(), hidden = hide)
                        Spacer(GlanceModifier.height(3.dp))
                        Text(
                            if (hide) snapshot.label("kind_${media.kind}", media.kind) else media.title,
                            maxLines = 1,
                            style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 11.sp),
                        )
                        // Large size only: a second line under the cover with the time left.
                        if (size.large && !hide && media.remaining.isNotEmpty()) {
                            Label(media.remaining, size = 10)
                        }
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

class ShelfReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = ShelfWidget()
}
