package app.fushi.reader.widgets

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
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
import androidx.glance.layout.size
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import app.fushi.reader.R

// Quick Actions grid (keeps ShortcutsWidget / ShortcutsReceiver).

class ShortcutsWidget : FushiGlanceWidget() {
    // Adds a one-row size so a 4x1 placement still gets a layout that fits.
    override val sizeMode: SizeMode = SizeMode.Responsive(
        setOf(
            DpSize(110.dp, 110.dp),
            DpSize(110.dp, 220.dp),
            DpSize(250.dp, 50.dp),
            DpSize(250.dp, 110.dp),
            DpSize(250.dp, 220.dp),
        ),
    )

    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        ShortcutsContent(context, snapshot)
    }
}

private class ShortcutEntry(val label: String, val icon: Int, val action: Action)

@Composable
private fun ShortcutsContent(context: Context, s: WidgetSnapshot?) {
    val size = LocalSize.current
    val wide = size.width >= 220.dp
    // Before the first snapshot arrives every action is shown; afterwards modules the user
    // turned off in Fushi drop out. Order = priority when the widget is too small for all.
    val entries = buildList {
        if (s == null || s.moduleSrs || s.srsProvider == "anki") {
            add(ShortcutEntry(s?.label("review", "Review") ?: "Review", R.drawable.ic_widget_review, reviewAction(context, s)))
        }
        if (s?.moduleBooks != false) add(ShortcutEntry(s?.label("books", "Books") ?: "Books", R.drawable.ic_widget_books, openLink(context, "fushi://widget/tab/books")))
        if (s?.moduleVideo != false) add(ShortcutEntry(s?.label("video", "Video") ?: "Video", R.drawable.ic_widget_video, openLink(context, "fushi://widget/tab/video")))
        if (s?.moduleLookup != false) {
            add(ShortcutEntry(s?.label("lookup", "Dictionary") ?: "Dictionary", R.drawable.ic_widget_lookup, openLink(context, "fushi://widget/tab/dictionaries")))
            add(ShortcutEntry(s?.label("vocab", "Vocabulary") ?: "Vocabulary", R.drawable.ic_widget_vocab, openLink(context, "fushi://widget/vocab")))
        }
        add(ShortcutEntry(s?.label("stats", "Statistics") ?: "Statistics", R.drawable.ic_widget_stats, openLink(context, "fushi://widget/stats")))
        add(ShortcutEntry(s?.label("settings", "Settings") ?: "Settings", R.drawable.ic_widget_settings, openLink(context, "fushi://widget/settings/widgets")))
    }
    val cols = if (wide) (if (size.height < 90.dp) 5 else 4) else 2
    val rows = when {
        size.height < 90.dp -> 1
        size.height < 190.dp -> 2
        else -> if (wide) 3 else 4
    }
    // Labels under the icons only where each row is tall enough to hold them.
    val labels = size.height >= 190.dp
    val shown = entries.take(cols * rows)
    WidgetRoot(url = null) {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            shown.chunked(cols).forEach { chunk ->
                Row(modifier = GlanceModifier.fillMaxWidth().defaultWeight(), verticalAlignment = Alignment.CenterVertically) {
                    chunk.forEach { entry ->
                        Column(
                            modifier = GlanceModifier.defaultWeight().fillMaxHeight().clickable(entry.action),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(
                                modifier = GlanceModifier.size(34.dp).cornerRadius(12.dp)
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
                            if (labels) {
                                Spacer(GlanceModifier.height(2.dp))
                                Text(
                                    entry.label,
                                    maxLines = 1,
                                    style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 10.sp),
                                )
                            }
                        }
                    }
                    repeat(cols - chunk.size) { Spacer(GlanceModifier.defaultWeight()) }
                }
            }
        }
    }
}

class ShortcutsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = ShortcutsWidget()
}
