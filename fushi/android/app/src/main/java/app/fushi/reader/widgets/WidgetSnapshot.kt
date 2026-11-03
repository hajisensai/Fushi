package app.fushi.reader.widgets

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import org.json.JSONObject
import java.io.File

/**
 * One media entry shown by the Continue and Shelf widgets.
 *
 * [kind] is `book`, `manga` or `video`; [id] is the Dart-side stable id the
 * `fushi://widget/continue` deep link carries back.
 */
data class WidgetMedia(
    val kind: String,
    val id: String,
    val title: String,
    val subtitle: String,
    val progress: Float,
    val cover: String?,
)

data class WidgetSnapshot(
    /** Local date (yyyy-MM-dd) the Today numbers were computed for. */
    val day: String,
    val labels: Map<String, String>,
    val moduleBooks: Boolean,
    val moduleManga: Boolean,
    val moduleVideo: Boolean,
    val moduleLookup: Boolean,
    val continueItem: WidgetMedia?,
    val shelf: List<WidgetMedia>,
    val todayTime: String,
    val todayChars: String,
    val todayGoal: Float,
    val weekTime: String,
    val weekChars: String,
    val streak: Int,
    val weekMinutes: List<Int>,
    /** Single-letter weekday labels for [weekMinutes], oldest first. */
    val weekDays: List<String>,
    val srsEnabled: Boolean,
    val srsDue: Int,
) {
    fun label(key: String, fallback: String): String = labels[key]?.takeIf { it.isNotEmpty() } ?: fallback
}

/**
 * Persists the snapshot Flutter pushes through [WidgetChannel] and parses it for
 * the Glance widgets. The widgets run in the app process, so they read the same
 * app-private files (covers) Flutter wrote; only a small JSON blob is stored here.
 */
object WidgetStore {
    private const val PREFS = "fushi_widget_snapshot"
    private const val KEY = "snapshot"

    fun save(context: Context, json: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, json).apply()
    }

    fun load(context: Context): WidgetSnapshot? {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: return null
        return try {
            parse(JSONObject(raw))
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Emits the parsed snapshot every time Flutter stores a new one. The widgets collect this
     * inside their composition: Glance keeps a session (and its composition) alive after an
     * update and does not call `provideGlance` again for it, so data read once in
     * `provideGlance` would stay stale until the session ends.
     */
    fun changes(context: Context): Flow<WidgetSnapshot?> = callbackFlow {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == KEY) trySend(load(context))
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        awaitClose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }.distinctUntilChanged()

    private fun parse(o: JSONObject): WidgetSnapshot {
        val labels = HashMap<String, String>()
        o.optJSONObject("labels")?.let { l -> l.keys().forEach { k -> labels[k] = l.optString(k) } }
        val modules = o.optJSONObject("modules")
        val today = o.optJSONObject("today")
        val week = o.optJSONObject("week")
        val srs = o.optJSONObject("srs")
        val shelf = ArrayList<WidgetMedia>()
        o.optJSONArray("shelf")?.let { a ->
            for (i in 0 until a.length()) a.optJSONObject(i)?.let { shelf.add(media(it)) }
        }
        val minutes = ArrayList<Int>()
        week?.optJSONArray("minutes")?.let { a -> for (i in 0 until a.length()) minutes.add(a.optInt(i)) }
        val days = ArrayList<String>()
        week?.optJSONArray("days")?.let { a -> for (i in 0 until a.length()) days.add(a.optString(i)) }
        return WidgetSnapshot(
            day = o.optString("day"),
            labels = labels,
            moduleBooks = modules?.optBoolean("books", true) ?: true,
            moduleManga = modules?.optBoolean("manga", true) ?: true,
            moduleVideo = modules?.optBoolean("video", true) ?: true,
            moduleLookup = modules?.optBoolean("lookup", true) ?: true,
            continueItem = o.optJSONObject("continue")?.let { media(it) },
            shelf = shelf,
            todayTime = today?.optString("time").orEmpty(),
            todayChars = today?.optString("chars").orEmpty(),
            todayGoal = (today?.optDouble("goal", 0.0) ?: 0.0).toFloat().coerceIn(0f, 1f),
            weekTime = week?.optString("time").orEmpty(),
            weekChars = week?.optString("chars").orEmpty(),
            streak = today?.optInt("streak", 0) ?: 0,
            weekMinutes = minutes,
            weekDays = days,
            srsEnabled = srs?.optBoolean("enabled", false) ?: false,
            srsDue = srs?.optInt("due", 0) ?: 0,
        )
    }

    private fun media(o: JSONObject) = WidgetMedia(
        kind = o.optString("kind"),
        id = o.optString("id"),
        title = o.optString("title"),
        subtitle = o.optString("subtitle"),
        progress = o.optDouble("progress", 0.0).toFloat().coerceIn(0f, 1f),
        cover = o.optString("cover").takeIf { it.isNotEmpty() },
    )
}

/** Loads a cover file down-sampled so the RemoteViews bitmap stays far below the binder limit. */
object WidgetBitmaps {
    fun load(path: String?, maxEdge: Int): Bitmap? {
        if (path.isNullOrEmpty()) return null
        return try {
            val file = File(path)
            if (!file.isFile) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= maxEdge && bounds.outHeight / (sample * 2) >= maxEdge) {
                sample *= 2
            }
            BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
        } catch (_: Throwable) {
            null
        }
    }
}
