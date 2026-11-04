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
    /** Reading position text ("45%"), empty when unknown (v2). */
    val position: String = "",
    /** Relative "last active" text ("2 h ago"), empty when unknown (v2). */
    val lastActive: String = "",
    /** Pre-formatted time to finish ("≈2h 10m left"), empty when it cannot be estimated. */
    val remaining: String = "",
)

/** One task row of the Downloads widget. [state] is active | queued | paused | failed. */
data class WidgetDownloadTask(
    val id: String,
    val title: String,
    val state: String,
    /** 0..100, null = unknown. */
    val percent: Int?,
    val speed: String,
)

/** The `downloads` block: counts, overall percent / speed and the top tasks. */
data class WidgetDownloads(
    /** Unfinished tasks (running, queued, paused, failed). */
    val count: Int = 0,
    /** Active + queued: the app keeps pushing while this is > 0. */
    val running: Int = 0,
    val percent: Int? = null,
    val speed: String = "",
    val tasks: List<WidgetDownloadTask> = emptyList(),
)

/** One in-progress media-server item of the On deck widget. */
data class WidgetOnDeckItem(
    /** `video` or `audiobook`. */
    val kind: String,
    val title: String,
    val subtitle: String,
    val server: String,
    val progress: Float,
    val position: String,
    val cover: String?,
    val lastActive: String,
    /** `fushi://widget/server?...` deep link built by Dart. */
    val link: String,
) {
    /** Adapter for the shared [Cover] composable. */
    fun asMedia() = WidgetMedia(kind = kind, id = link, title = title, subtitle = subtitle, progress = progress, cover = cover)
}

/** `state` is none (no media server) | off (servers exist, opt-in off) | ok. */
data class WidgetOnDeck(val state: String = "none", val items: List<WidgetOnDeckItem> = emptyList())

/** One immersion category row (reading / listening / watching / games) of `today.categories`. */
data class WidgetCategory(val id: String, val label: String, val ms: Long, val time: String, val link: String)

/** One configured daily goal of `goals`. */
data class WidgetGoal(
    val id: String,
    val label: String,
    val value: String,
    val target: String,
    val frac: Float,
    val done: Boolean,
)

/** One vocabulary card of `vocab`. [origin] is `mined` or `favorite`. */
data class WidgetVocab(
    val term: String,
    val reading: String,
    val definition: String,
    val sentence: String,
    val source: String,
    val origin: String,
)

/**
 * The `nowPlaying` block: current (or last played) song / audiobook. Position is a sample taken at
 * [updatedAt]; while [playing] the widget extrapolates `positionMs + (now - updatedAt)` at render time.
 * [kind] is `music` or `audiobook`; [skipSeconds] (audiobook) is 0 for sentence skipping.
 */
data class WidgetNowPlaying(
    val kind: String,
    val title: String,
    val subtitle: String,
    val cover: String?,
    val positionMs: Long,
    val durationMs: Long,
    val playing: Boolean,
    val updatedAt: Long,
    val link: String,
    val canSkipTrack: Boolean,
    val skipSeconds: Int,
)

data class WidgetSnapshot(
    /** Stat day key (yyyy-MM-dd) the today numbers were computed for. */
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
    // ---- v2 (all optional; missing -> default / null / empty) ----
    val generatedAt: Long = 0L,
    val moduleSrs: Boolean = true,
    val moduleMusic: Boolean = true,
    val moduleGames: Boolean = true,
    val privacyHideTitles: Boolean = false,
    val privacyHideDefinitions: Boolean = false,
    val privacyHideProfile: Boolean = false,
    /** Active profile name; shown only when the user has more than one profile. */
    val profileName: String = "",
    val profileMulti: Boolean = false,
    val todayTotalMs: Long = 0L,
    val categories: List<WidgetCategory> = emptyList(),
    /** 0 = no time goal configured. */
    val goalMs: Long = 0L,
    val goalTime: String = "",
    val goalFrac: Float = 0f,
    val goals: List<WidgetGoal> = emptyList(),
    val weekPrevTime: String = "",
    val weekDeltaPct: Int? = null,
    val weekReviews: Int? = null,
    val weekGoalDays: Int? = null,
    val monthMinutes: List<Int> = emptyList(),
    val monthTime: String = "",
    val monthActiveDays: Int = 0,
    val streakLongest: Int = 0,
    val streakSrsCurrent: Int? = null,
    val streakSrsLongest: Int? = null,
    val streakWeek: List<Boolean> = emptyList(),
    /** `fushi`, `anki` or `none`. */
    val srsProvider: String = "none",
    val srsLabel: String = "",
    val srsNew: Int = 0,
    val srsLearn: Int = 0,
    val srsReview: Int = 0,
    val srsReviewedToday: Int = 0,
    val srsDueTomorrow: Int = 0,
    val ankiPackage: String = "",
    val vocab: List<WidgetVocab> = emptyList(),
    val nowPlaying: WidgetNowPlaying? = null,
    val downloads: WidgetDownloads = WidgetDownloads(),
    val onDeck: WidgetOnDeck = WidgetOnDeck(),
) {
    fun label(key: String, fallback: String): String = labels[key]?.takeIf { it.isNotEmpty() } ?: fallback

    /**
     * "[title] · <profile>" when the user has several profiles (so numbers can't be mistaken for
     * another profile's) unless the app-level "hide profile name" privacy setting is on.
     */
    fun withProfile(title: String): String =
        if (profileMulti && !privacyHideProfile && profileName.isNotBlank()) "$title · $profileName" else title

    /** A Dart-localized template label (`{n}` / `{age}` placeholders) filled at display time. */
    fun template(key: String, fallback: String, vararg values: Pair<String, String>): String {
        var text = label(key, fallback)
        for ((name, value) in values) text = text.replace("{$name}", value)
        return text
    }
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

    private fun JSONObject.ints(key: String): List<Int> {
        val a = optJSONArray(key) ?: return emptyList()
        return List(a.length()) { a.optInt(it) }
    }

    private fun JSONObject.intOrNull(key: String): Int? = if (has(key) && !isNull(key)) optInt(key) else null

    private fun parse(o: JSONObject): WidgetSnapshot {
        val labels = HashMap<String, String>()
        o.optJSONObject("labels")?.let { l -> l.keys().forEach { k -> labels[k] = l.optString(k) } }
        val modules = o.optJSONObject("modules")
        val privacy = o.optJSONObject("privacy")
        val today = o.optJSONObject("today")
        val week = o.optJSONObject("week")
        val month = o.optJSONObject("month")
        val streak = o.optJSONObject("streak")
        val srs = o.optJSONObject("srs")
        val shelf = ArrayList<WidgetMedia>()
        o.optJSONArray("shelf")?.let { a ->
            for (i in 0 until a.length()) a.optJSONObject(i)?.let { shelf.add(media(it)) }
        }
        val days = ArrayList<String>()
        week?.optJSONArray("days")?.let { a -> for (i in 0 until a.length()) days.add(a.optString(i)) }
        val categories = ArrayList<WidgetCategory>()
        today?.optJSONArray("categories")?.let { a ->
            for (i in 0 until a.length()) a.optJSONObject(i)?.let {
                categories.add(
                    WidgetCategory(
                        id = it.optString("id"),
                        label = it.optString("label"),
                        ms = it.optLong("ms", 0L).coerceAtLeast(0L),
                        time = it.optString("time"),
                        link = it.optString("link"),
                    ),
                )
            }
        }
        val goals = ArrayList<WidgetGoal>()
        o.optJSONArray("goals")?.let { a ->
            for (i in 0 until a.length()) a.optJSONObject(i)?.let {
                goals.add(
                    WidgetGoal(
                        id = it.optString("id"),
                        label = it.optString("label"),
                        value = it.optString("value"),
                        target = it.optString("target"),
                        frac = it.optDouble("frac", 0.0).toFloat().coerceIn(0f, 1f),
                        done = it.optBoolean("done", false),
                    ),
                )
            }
        }
        val streakWeek = ArrayList<Boolean>()
        streak?.optJSONArray("week")?.let { a -> for (i in 0 until a.length()) streakWeek.add(a.optBoolean(i)) }
        val vocab = ArrayList<WidgetVocab>()
        o.optJSONArray("vocab")?.let { a ->
            for (i in 0 until a.length()) a.optJSONObject(i)?.let {
                val term = it.optString("term")
                if (term.isNotEmpty()) {
                    vocab.add(
                        WidgetVocab(
                            term = term,
                            reading = it.optString("reading"),
                            definition = it.optString("definition"),
                            sentence = it.optString("sentence"),
                            source = it.optString("source"),
                            origin = it.optString("origin"),
                        ),
                    )
                }
            }
        }
        val srsEnabled = srs?.optBoolean("enabled", false) ?: false
        val downloads = o.optJSONObject("downloads")?.let { d ->
            val tasks = ArrayList<WidgetDownloadTask>()
            d.optJSONArray("tasks")?.let { a ->
                for (i in 0 until a.length()) a.optJSONObject(i)?.let {
                    tasks.add(
                        WidgetDownloadTask(
                            id = it.optString("id"),
                            title = it.optString("title"),
                            state = it.optString("state"),
                            percent = it.intOrNull("percent")?.coerceIn(0, 100),
                            speed = it.optString("speed"),
                        ),
                    )
                }
            }
            WidgetDownloads(
                count = d.optInt("count", 0),
                running = d.optInt("running", 0),
                percent = d.intOrNull("percent")?.coerceIn(0, 100),
                speed = d.optString("speed"),
                tasks = tasks,
            )
        } ?: WidgetDownloads()
        val onDeck = o.optJSONObject("onDeck")?.let { d ->
            val items = ArrayList<WidgetOnDeckItem>()
            d.optJSONArray("items")?.let { a ->
                for (i in 0 until a.length()) a.optJSONObject(i)?.let {
                    items.add(
                        WidgetOnDeckItem(
                            kind = it.optString("kind"),
                            title = it.optString("title"),
                            subtitle = it.optString("subtitle"),
                            server = it.optString("server"),
                            progress = it.optDouble("progress", 0.0).toFloat().coerceIn(0f, 1f),
                            position = it.optString("position"),
                            cover = it.optString("cover").takeIf { c -> c.isNotEmpty() },
                            lastActive = it.optString("lastActive"),
                            link = it.optString("link"),
                        ),
                    )
                }
            }
            WidgetOnDeck(state = d.optString("state").ifEmpty { "none" }, items = items)
        } ?: WidgetOnDeck()
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
            streak = today?.optInt("streak", 0) ?: streak?.optInt("current", 0) ?: 0,
            weekMinutes = week?.ints("minutes").orEmpty(),
            weekDays = days,
            srsEnabled = srsEnabled,
            srsDue = srs?.optInt("due", 0) ?: 0,
            generatedAt = o.optLong("generatedAt", 0L),
            moduleSrs = modules?.optBoolean("srs", true) ?: true,
            moduleMusic = modules?.optBoolean("music", true) ?: true,
            moduleGames = modules?.optBoolean("games", true) ?: true,
            privacyHideTitles = privacy?.optBoolean("hideTitles", false) ?: false,
            privacyHideDefinitions = privacy?.optBoolean("hideDefinitions", false) ?: false,
            privacyHideProfile = privacy?.optBoolean("hideProfile", false) ?: false,
            profileName = o.optJSONObject("profile")?.optString("name").orEmpty(),
            profileMulti = o.optJSONObject("profile")?.optBoolean("multi", false) ?: false,
            todayTotalMs = today?.optLong("totalMs", 0L)?.coerceAtLeast(0L) ?: 0L,
            categories = categories,
            goalMs = today?.optLong("goalMs", 0L)?.coerceAtLeast(0L) ?: 0L,
            goalTime = today?.optString("goalTime").orEmpty(),
            goalFrac = (today?.optDouble("goalFrac", 0.0) ?: 0.0).toFloat().coerceIn(0f, 1f),
            goals = goals,
            weekPrevTime = week?.optString("prevTime").orEmpty(),
            weekDeltaPct = week?.intOrNull("deltaPct"),
            weekReviews = week?.intOrNull("reviews"),
            weekGoalDays = week?.intOrNull("goalDays"),
            monthMinutes = month?.ints("minutes").orEmpty(),
            monthTime = month?.optString("time").orEmpty(),
            monthActiveDays = month?.optInt("activeDays", 0) ?: 0,
            streakLongest = streak?.optInt("longest", 0) ?: 0,
            streakSrsCurrent = streak?.intOrNull("srsCurrent"),
            streakSrsLongest = streak?.intOrNull("srsLongest"),
            streakWeek = streakWeek,
            // v1 snapshots carry no provider: derive it from the legacy enabled flag.
            srsProvider = srs?.optString("provider")?.takeIf { it.isNotEmpty() }
                ?: if (srsEnabled) "fushi" else "none",
            srsLabel = srs?.optString("label").orEmpty(),
            srsNew = srs?.optInt("new", 0) ?: 0,
            srsLearn = srs?.optInt("learn", 0) ?: 0,
            srsReview = srs?.optInt("review", 0) ?: 0,
            srsReviewedToday = srs?.optInt("reviewedToday", 0) ?: 0,
            srsDueTomorrow = srs?.optInt("dueTomorrow", 0) ?: 0,
            ankiPackage = srs?.optString("ankiPackage").orEmpty(),
            vocab = vocab,
            downloads = downloads,
            onDeck = onDeck,
            nowPlaying = o.optJSONObject("nowPlaying")?.let { nowPlaying(it) },
        )
    }

    private fun nowPlaying(o: JSONObject): WidgetNowPlaying? {
        val title = o.optString("title")
        if (title.isEmpty()) return null
        return WidgetNowPlaying(
            kind = o.optString("kind", "music"),
            title = title,
            subtitle = o.optString("subtitle"),
            cover = o.optString("cover").takeIf { it.isNotEmpty() },
            positionMs = o.optLong("positionMs", 0L).coerceAtLeast(0L),
            durationMs = o.optLong("durationMs", 0L).coerceAtLeast(0L),
            playing = o.optBoolean("playing", false),
            updatedAt = o.optLong("updatedAt", 0L),
            link = o.optString("link").ifEmpty { "fushi://widget/open" },
            canSkipTrack = o.optBoolean("canSkipTrack", false),
            skipSeconds = o.optInt("skipSeconds", 0).coerceAtLeast(0),
        )
    }

    private fun media(o: JSONObject) = WidgetMedia(
        kind = o.optString("kind"),
        id = o.optString("id"),
        title = o.optString("title"),
        subtitle = o.optString("subtitle"),
        progress = o.optDouble("progress", 0.0).toFloat().coerceIn(0f, 1f),
        cover = o.optString("cover").takeIf { it.isNotEmpty() },
        position = o.optString("position"),
        lastActive = o.optString("lastActive"),
        remaining = o.optString("remaining"),
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
