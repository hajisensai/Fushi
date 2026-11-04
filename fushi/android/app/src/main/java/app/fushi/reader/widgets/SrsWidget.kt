package app.fushi.reader.widgets

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.produceState
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.Action
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import app.fushi.reader.AnkiDroidTarget
import app.fushi.reader.R
import com.ichi2.anki.FlashCardsContract
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// ---------------------------------------------------------------------------
// AnkiDroid due counts, read live and natively (no Flutter involved)
// ---------------------------------------------------------------------------

internal data class AnkiDue(
    val status: Status,
    val learn: Int = 0,
    val review: Int = 0,
    val new: Int = 0,
    val packageName: String = "",
) {
    enum class Status { OK, NOT_INSTALLED, NO_PERMISSION, ERROR }

    val total: Int get() = learn + review + new

    companion object {
        /**
         * Reads AnkiDroid's deck list (`content://<authority>/decks`) and sums the
         * `deck_count` column ([FlashCardsContract.Deck.DECK_COUNTS]), a JSON array
         * `[learn, review, new]`, over top-level decks only: a parent deck's counts already
         * include its children ("A" contains "A::B"). Must run off the main thread.
         *
         * The provider authority / permission are resolved like [app.fushi.reader.DirectAnkiProvider]
         * does (AnkiDroidTarget): parallel builds carry a package suffix in both. [hint] is the
         * package Dart reported; it wins when its provider is installed.
         */
        fun read(context: Context, hint: String): AnkiDue {
            return try {
                val pm = context.packageManager
                val pkg = hint.takeIf {
                    it.isNotEmpty() && pm.resolveContentProvider(AnkiDroidTarget.authorityFor(it), 0) != null
                } ?: AnkiDroidTarget.resolve(context)?.packageName
                ?: return AnkiDue(Status.NOT_INSTALLED)
                val permission = AnkiDroidTarget.permissionFor(pkg)
                if (context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                    return AnkiDue(Status.NO_PERMISSION, packageName = pkg)
                }
                val uri = FlashCardsContract.Deck.CONTENT_ALL_URI.buildUpon()
                    .authority(AnkiDroidTarget.authorityFor(pkg)).build()
                var learn = 0
                var review = 0
                var new = 0
                val cursor = context.contentResolver.query(uri, null, null, null, null)
                    ?: return AnkiDue(Status.ERROR, packageName = pkg)
                cursor.use { c ->
                    val nameIdx = c.getColumnIndex(FlashCardsContract.Deck.DECK_NAME)
                    val countIdx = c.getColumnIndex(FlashCardsContract.Deck.DECK_COUNTS)
                    if (nameIdx < 0 || countIdx < 0) return AnkiDue(Status.ERROR, packageName = pkg)
                    while (c.moveToNext()) {
                        if (c.getString(nameIdx).orEmpty().contains("::")) continue
                        val counts = org.json.JSONArray(c.getString(countIdx) ?: continue)
                        learn += counts.optInt(0)
                        review += counts.optInt(1)
                        new += counts.optInt(2)
                    }
                }
                AnkiDue(Status.OK, learn, review, new, pkg)
            } catch (_: SecurityException) {
                AnkiDue(Status.NO_PERMISSION)
            } catch (_: Throwable) {
                AnkiDue(Status.ERROR)
            }
        }
    }
}

/** Launch intent for the installed AnkiDroid, or null (handled natively, not via Flutter). */
private fun ankiLaunchAction(context: Context, packageName: String): Action? {
    if (packageName.isEmpty()) return null
    val intent = context.packageManager.getLaunchIntentForPackage(packageName) ?: return null
    return actionStartActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** Action for a "review" entry given the snapshot's provider; null = no sensible action. */
internal fun reviewAction(context: Context, s: WidgetSnapshot?): Action = when (s?.srsProvider) {
    "fushi" -> openLink(context, "fushi://widget/srs")
    "anki" -> ankiLaunchAction(context, s.ankiPackage.ifEmpty { AnkiDroidTarget.resolve(context)?.packageName.orEmpty() })
        ?: openLink(context, "fushi://widget/settings/cards")
    else -> openLink(context, "fushi://widget/settings/cards")
}

// ---------------------------------------------------------------------------
// Spaced-Repetition Dashboard (keeps SrsWidget / SrsReceiver)
// ---------------------------------------------------------------------------

class SrsWidget : FushiGlanceWidget() {
    private var initialAnki: AnkiDue? = null

    override suspend fun prepare(context: Context) {
        val s = WidgetStore.load(context)
        initialAnki = if (s?.srsProvider == "anki") {
            withContext(Dispatchers.IO) { AnkiDue.read(context, s.ankiPackage) }
        } else {
            null
        }
    }

    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        if (snapshot == null) {
            SetupHint(null, "Open Fushi to set up this widget")
            return
        }
        val first = initialAnki
        when (snapshot.srsProvider) {
            "fushi" -> FushiSrs(context, snapshot)
            "anki" -> {
                // Re-read whenever Flutter pushes a new snapshot (e.g. the package changed);
                // the first frame uses the value read in prepare().
                val anki = produceState(first, snapshot.generatedAt, snapshot.ankiPackage) {
                    value = withContext(Dispatchers.IO) { AnkiDue.read(context, snapshot.ankiPackage) }
                }.value
                AnkiSrs(context, snapshot, anki)
            }
            else -> NoneSrs(snapshot)
        }
    }
}

@Composable
private fun BigNumber(value: Int, large: Boolean) = Text(
    value.toString(),
    maxLines = 1,
    style = TextStyle(
        color = GlanceTheme.colors.onSurface,
        fontSize = if (large) 48.sp else 40.sp,
        fontWeight = FontWeight.Bold,
    ),
)

@Composable
private fun StatRow(label: String, value: Int, accent: Boolean = false) {
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            label,
            maxLines = 1,
            modifier = GlanceModifier.defaultWeight(),
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 12.sp),
        )
        Text(
            value.toString(),
            maxLines = 1,
            style = TextStyle(
                color = if (accent) GlanceTheme.colors.primary else GlanceTheme.colors.onSurface,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
            ),
        )
    }
}

@Composable
private fun CaughtUp(s: WidgetSnapshot?) = Text(
    s?.label("srsDone", "All caught up") ?: "All caught up",
    maxLines = 2,
    style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 18.sp, fontWeight = FontWeight.Bold),
)

@Composable
private fun FushiSrs(context: Context, s: WidgetSnapshot) {
    val size = sizeClass()
    val due = s.srsDue
    val updated = ageText(context, s)
    WidgetRoot(url = "fushi://widget/srs") {
        Row(modifier = GlanceModifier.fillMaxSize()) {
            Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight()) {
                Label(s.withProfile(s.srsLabel.ifEmpty { s.label("srsDue", "Cards due") }), GlanceTheme.colors.primary)
                Spacer(GlanceModifier.defaultWeight())
                if (due > 0) {
                    BigNumber(due, size.large)
                    Label(s.label("srsDue", "Cards due"), size = 11)
                    Gap(6)
                    Chip(s.label("reviewNow", "Review now"))
                } else {
                    CaughtUp(s)
                }
                if (size.tall && updated.isNotEmpty() && !size.wide) {
                    Gap(4)
                    Label(s.template("updatedAgo", "Updated {age}", "age" to updated), size = 10)
                }
            }
            if (size.wide) {
                Spacer(GlanceModifier.width(14.dp))
                Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
                    StatRow(s.label("srsNew", "New"), s.srsNew)
                    StatRow(s.label("srsLearn", "Learning"), s.srsLearn)
                    StatRow(s.label("srsDue", "Review"), s.srsReview)
                    Gap(4)
                    StatRow(s.label("reviewedToday", "Reviewed today"), s.srsReviewedToday, accent = true)
                    if (size.tall) StatRow(s.label("dueTomorrow", "Due tomorrow"), s.srsDueTomorrow)
                    if (updated.isNotEmpty() && size.tall) {
                        Gap(4)
                        Label(s.template("updatedAgo", "Updated {age}", "age" to updated), size = 10)
                    }
                }
            }
        }
    }
}

@Composable
private fun AnkiSrs(context: Context, s: WidgetSnapshot, anki: AnkiDue?) {
    val size = sizeClass()
    val title = s.withProfile(s.srsLabel.ifEmpty { "AnkiDroid" })
    when (anki?.status) {
        AnkiDue.Status.OK -> {
            val launch = ankiLaunchAction(context, anki.packageName)
            // Launching is handled natively; with no launch intent the tap opens card settings.
            WidgetRootAction(launch ?: openLink(context, "fushi://widget/settings/cards")) {
                Row(modifier = GlanceModifier.fillMaxSize()) {
                    Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight()) {
                        Label(title, GlanceTheme.colors.primary)
                        Spacer(GlanceModifier.defaultWeight())
                        if (anki.total > 0) {
                            BigNumber(anki.total, size.large)
                            Label(s.label("srsDue", "Cards due"), size = 11)
                            Gap(6)
                            Chip(s.label("openAnki", context.getString(R.string.widget_anki_open)))
                        } else {
                            CaughtUp(s)
                        }
                    }
                    if (size.wide) {
                        Spacer(GlanceModifier.width(14.dp))
                        Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
                            StatRow(s.label("srsLearn", "Learning"), anki.learn)
                            StatRow(s.label("srsDue", "Review"), anki.review)
                            StatRow(s.label("srsNew", "New"), anki.new)
                        }
                    }
                }
            }
        }
        AnkiDue.Status.NOT_INSTALLED -> MessageState(title, context.getString(R.string.widget_anki_missing), null, "fushi://widget/settings/cards", context)
        AnkiDue.Status.NO_PERMISSION -> MessageState(
            title,
            s.label("ankiPermission", context.getString(R.string.widget_anki_permission)),
            null,
            "fushi://widget/settings/cards",
            context,
        )
        else -> MessageState(title, context.getString(R.string.widget_anki_unavailable), null, "fushi://widget/settings/cards", context)
    }
}

@Composable
private fun NoneSrs(s: WidgetSnapshot) {
    val context = androidx.glance.LocalContext.current
    MessageState(
        s.label("srsDue", "Cards due"),
        s.label("srsSetup", "Choose a review app"),
        null,
        "fushi://widget/settings/cards",
        context,
    )
}

@Composable
private fun MessageState(title: String, message: String, action: Action?, url: String, context: Context) {
    WidgetRootAction(action ?: openLink(context, url)) {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Label(title, GlanceTheme.colors.primary)
            Spacer(GlanceModifier.defaultWeight())
            Text(
                message,
                maxLines = 4,
                modifier = GlanceModifier.fillMaxWidth(),
                style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 14.sp, fontWeight = FontWeight.Medium),
            )
            Spacer(GlanceModifier.defaultWeight())
        }
    }
}

/** [WidgetRoot] variant whose click is an arbitrary [Action] (e.g. a native launch intent). */
@Composable
internal fun WidgetRootAction(action: Action?, content: @Composable () -> Unit) {
    WidgetRoot(url = null, action = action, content = content)
}

class SrsReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = SrsWidget()
}
