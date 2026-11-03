package app.fushi.reader.widgets

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import app.fushi.reader.R

// Vocabulary of the Day. The "next" button is an ActionCallback that bumps this instance's
// offset in its own Glance state and re-renders; it works without Flutter running.

class VocabWidget : FushiGlanceWidget() {
    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        val pool = snapshot?.vocab?.filter { cfg.vocabSource == "all" || it.origin == cfg.vocabSource }.orEmpty()
        if (snapshot == null || pool.isEmpty()) {
            SetupHint(
                snapshot,
                snapshot?.label("noVocab", "Save words in Fushi to see them here") ?: "Save words in Fushi to see them here",
                "fushi://widget/vocab",
            )
        } else {
            // Stable per day by default (epoch day), advanced by the instance's "next" presses.
            val epochDay = java.util.Calendar.getInstance().let {
                (it.timeInMillis + it.get(java.util.Calendar.ZONE_OFFSET) + it.get(java.util.Calendar.DST_OFFSET)) / 86_400_000L
            }
            val index = Math.floorMod(epochDay + cfg.vocabOffset, pool.size.toLong()).toInt()
            VocabContent(context, snapshot, pool[index], cfg.hideDefinitions(snapshot), pool.size > 1)
        }
    }
}

@Composable
private fun VocabContent(context: Context, s: WidgetSnapshot, v: WidgetVocab, hideDef: Boolean, canCycle: Boolean) {
    val size = sizeClass()
    WidgetRoot(url = lookupUrl(v.term)) {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Label(s.label("vocabTitle", "Word of the day"), GlanceTheme.colors.primary, GlanceModifier.defaultWeight())
                if (canCycle) {
                    // 48dp touch target around a 24dp glyph.
                    Box(
                        modifier = GlanceModifier.size(MIN_TOUCH).clickable(actionRunCallback<VocabNextAction>(actionParametersOf())),
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(
                            modifier = GlanceModifier.size(32.dp).cornerRadius(16.dp).background(GlanceTheme.colors.secondaryContainer),
                            contentAlignment = Alignment.Center,
                        ) {
                            Image(
                                provider = ImageProvider(R.drawable.ic_widget_next),
                                contentDescription = s.label("nextWord", context.getString(R.string.widget_vocab_next)),
                                colorFilter = ColorFilter.tint(GlanceTheme.colors.onSecondaryContainer),
                                modifier = GlanceModifier.size(22.dp),
                            )
                        }
                    }
                }
            }
            Text(
                v.term,
                maxLines = 1,
                style = TextStyle(
                    color = GlanceTheme.colors.onSurface,
                    fontSize = if (size.large) 34.sp else if (size.wide) 30.sp else 24.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
            if (v.reading.isNotEmpty()) Label(v.reading, GlanceTheme.colors.primary, size = 13)
            if (!hideDef) {
                if (v.definition.isNotEmpty()) {
                    Gap(4)
                    Text(
                        v.definition,
                        maxLines = if (size.tall) 4 else 2,
                        modifier = GlanceModifier.fillMaxWidth(),
                        style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 13.sp),
                    )
                }
                if (v.sentence.isNotEmpty() && size.tall) {
                    Gap(6)
                    Text(
                        v.sentence,
                        maxLines = 3,
                        modifier = GlanceModifier.fillMaxWidth(),
                        style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 12.sp),
                    )
                }
            }
            Spacer(GlanceModifier.defaultWeight())
            if (v.source.isNotEmpty() && (size.wide || size.tall) && !hideDef) {
                Label(v.source, size = 11)
            }
        }
    }
}

/** Advances this instance's word by one; resets automatically on the next day (see [WidgetConfig.from]). */
class VocabNextAction : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: androidx.glance.action.ActionParameters,
    ) {
        updateWidgetPrefs(context, VocabWidget(), glanceId) { p ->
            val today = todayKey()
            val current = if (p[WidgetPrefs.VOCAB_OFFSET_DAY] == today) p[WidgetPrefs.VOCAB_OFFSET] ?: 0 else 0
            p[WidgetPrefs.VOCAB_OFFSET] = current + 1
            p[WidgetPrefs.VOCAB_OFFSET_DAY] = today
        }
    }
}

class VocabReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = VocabWidget()
}
