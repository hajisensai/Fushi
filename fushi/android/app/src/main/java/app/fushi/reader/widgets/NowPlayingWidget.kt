package app.fushi.reader.widgets

import android.content.Context
import android.content.Intent
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
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
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.media.MediaBrowserServiceCompat
import app.fushi.reader.R

// "Now playing": cover, title, artist/author, progress and transport controls for the current (or
// last played) song or audiobook.
//
// Controls talk to the live MediaSession that audio_service publishes (one shared handler serves
// music and audiobooks, see AudioController), natively and without Flutter in the loop:
// [NowPlayingControl]. When the session is not alive the buttons open the app instead (the snapshot
// link) rather than cold-starting audio_service's foreground service.

private val CMD = ActionParameters.Key<String>("cmd")
private val LINK = ActionParameters.Key<String>("link")

private const val CMD_TOGGLE = "toggle"
private const val CMD_NEXT = "next"
private const val CMD_PREVIOUS = "previous"

/** A snapshot older than this that claims "playing" with no live session is treated as paused. */
private const val STALE_PLAYING_MS = 15_000L

/**
 * Widths x heights this widget lays out for. Glance picks the largest entry that fits the real
 * size, so the thresholds in [NowPlayingContent] are these numbers: a row of controls only (2x1),
 * a one-line card (4x1) and a card with progress (4x2).
 */
private val NOW_PLAYING_SIZES: SizeMode = SizeMode.Responsive(
    setOf(
        DpSize(120.dp, 40.dp),
        DpSize(170.dp, 40.dp),
        DpSize(260.dp, 40.dp),
        DpSize(320.dp, 40.dp),
        DpSize(170.dp, 110.dp),
        DpSize(260.dp, 110.dp),
        DpSize(320.dp, 110.dp),
    ),
)

class NowPlayingWidget : FushiGlanceWidget() {
    override val sizeMode: SizeMode = NOW_PLAYING_SIZES

    @Composable
    override fun Content(context: Context, snapshot: WidgetSnapshot?, cfg: WidgetConfig) {
        val np = snapshot?.nowPlaying
        if (snapshot == null || np == null) {
            NowPlayingEmpty(snapshot)
            return
        }
        val hide = cfg.hideTitles(snapshot)
        val bitmap = remember(np.cover, hide) { if (hide) null else WidgetBitmaps.load(np.cover, 256) }
        // Decide once per render: the session either answers (controls run natively) or not (open app).
        val live = remember(snapshot.generatedAt, np.updatedAt, np.playing) { NowPlayingControl.isAvailable(context) }
        NowPlayingContent(snapshot, np, bitmap, hide, live)
    }
}

@Composable
private fun NowPlayingEmpty(snapshot: WidgetSnapshot?) {
    val size = LocalSize.current
    val title = snapshot?.label("nowPlaying", "Now playing") ?: "Now playing"
    val empty = snapshot?.label("nothingPlaying", "Nothing playing") ?: "Nothing playing"
    WidgetRoot(url = "fushi://widget/tab/music") {
        if (size.height < 100.dp) {
            Row(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                Image(
                    provider = ImageProvider(R.drawable.ic_widget_play),
                    contentDescription = title,
                    colorFilter = ColorFilter.tint(GlanceTheme.colors.primary),
                    modifier = GlanceModifier.size(24.dp),
                )
                if (size.width >= 170.dp) {
                    Spacer(GlanceModifier.width(8.dp))
                    Text(
                        empty,
                        maxLines = 1,
                        style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 13.sp),
                    )
                }
            }
        } else {
            Column(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                Label(title, GlanceTheme.colors.primary)
                Spacer(GlanceModifier.height(4.dp))
                Text(
                    empty,
                    maxLines = 2,
                    style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 15.sp, fontWeight = FontWeight.Bold),
                )
            }
        }
    }
}

@Composable
private fun NowPlayingContent(
    snapshot: WidgetSnapshot,
    np: WidgetNowPlaying,
    bitmap: android.graphics.Bitmap?,
    hide: Boolean,
    live: Boolean,
) {
    val context = androidx.glance.LocalContext.current
    val size = LocalSize.current
    val now = System.currentTimeMillis()
    // Only trust a "playing" flag that a live session (or a fresh sample) backs up: after the app
    // is killed mid-song the stored snapshot would otherwise show a ticking progress forever.
    val playing = np.playing && (live || now - np.updatedAt < STALE_PLAYING_MS)
    val shown = shownPosition(np, playing, now)
    val kindLabel = snapshot.label("kind_${np.kind}", np.kind.replaceFirstChar { it.uppercase() })
    // Privacy: the kind label stands in for the title; artist / author and cover are hidden.
    val title = if (hide) kindLabel else np.title
    val subtitle = if (hide) "" else np.subtitle
    val media = WidgetMedia(np.kind, "", np.title, np.subtitle, 0f, np.cover)
    val controls = controlsFor(context, snapshot, np, playing, live)
    val body: Action = openLink(context, np.link)

    WidgetRoot(url = null, action = body) {
        if (size.height < 100.dp) {
            if (size.width < 200.dp) {
                // 2x1: controls only.
                Row(
                    modifier = GlanceModifier.fillMaxSize(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    ControlsRow(controls, if (size.width < 150.dp) 2 else 3)
                }
            } else {
                // 4x1: cover, text, controls.
                Row(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                    Cover(media, bitmap, GlanceModifier.size(44.dp), glyphSize = 20, hidden = hide)
                    Spacer(GlanceModifier.width(8.dp))
                    Column(modifier = GlanceModifier.defaultWeight(), verticalAlignment = Alignment.CenterVertically) {
                        Title(title, size = 13, maxLines = 1)
                        if (subtitle.isNotEmpty()) Label(subtitle, size = 11)
                    }
                    ControlsRow(controls, if (size.width < 300.dp) 2 else 3)
                }
            }
        } else {
            // 4x2: header, progress, controls (3 children).
            Column(modifier = GlanceModifier.fillMaxSize()) {
                Row(modifier = GlanceModifier.fillMaxWidth().defaultWeight(), verticalAlignment = Alignment.CenterVertically) {
                    if (size.width >= 250.dp) {
                        Cover(media, bitmap, GlanceModifier.size(56.dp), glyphSize = 24, hidden = hide)
                        Spacer(GlanceModifier.width(10.dp))
                    }
                    Column(modifier = GlanceModifier.defaultWeight(), verticalAlignment = Alignment.CenterVertically) {
                        Label(snapshot.label("nowPlaying", "Now playing"), GlanceTheme.colors.primary, size = 11)
                        Title(title, size = 15, maxLines = 1)
                        if (subtitle.isNotEmpty()) Label(subtitle, size = 12)
                    }
                }
                ProgressRow(shown, np.durationMs)
                Row(
                    modifier = GlanceModifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    ControlsRow(controls, 3)
                }
            }
        }
    }
}

/** Elapsed - bar - remaining. The bar is omitted while the duration is unknown. */
@Composable
private fun ProgressRow(positionMs: Long, durationMs: Long) {
    Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Label(formatClock(positionMs), size = 11)
        Spacer(GlanceModifier.width(6.dp))
        if (durationMs > 0) {
            LinearProgressIndicator(
                progress = (positionMs.toFloat() / durationMs).coerceIn(0f, 1f),
                modifier = GlanceModifier.defaultWeight(),
                color = GlanceTheme.colors.primary,
                backgroundColor = GlanceTheme.colors.secondaryContainer,
            )
            Spacer(GlanceModifier.width(6.dp))
            Label("-" + formatClock((durationMs - positionMs).coerceAtLeast(0L)), size = 11)
        } else {
            Spacer(GlanceModifier.defaultWeight())
        }
    }
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

private class Control(
    val icon: Int?,
    /** Short text drawn instead of an icon ("-30" / "+30" for second-based audiobook skips). */
    val text: String?,
    val description: String,
    val action: Action,
    val primary: Boolean = false,
)

/**
 * The buttons for this state, most important first: `[play]`, `[play, next]`, `[prev, play, next]`
 * is what [ControlsRow] picks from by available slots. Music offers previous / next only when the
 * queue has them; audiobooks always offer back / forward (seconds when the reader's skip interval
 * is set, otherwise sentences).
 */
private fun controlsFor(
    context: Context,
    s: WidgetSnapshot,
    np: WidgetNowPlaying,
    playing: Boolean,
    live: Boolean,
): List<Control> {
    // Live session: run the command natively. Otherwise open the app (explicit intent, no service start).
    fun act(cmd: String): Action =
        if (live) {
            actionRunCallback<NowPlayingActionCallback>(actionParametersOf(CMD to cmd, LINK to np.link))
        } else {
            openLink(context, np.link)
        }

    val play = Control(
        icon = if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
        text = null,
        description = if (playing) s.label("pause", "Pause") else s.label("play", "Play"),
        action = act(CMD_TOGGLE),
        primary = true,
    )
    val audiobook = np.kind == "audiobook"
    val showSkips = audiobook || np.canSkipTrack
    if (!showSkips) return listOf(play)
    val n = np.skipSeconds
    val back = if (audiobook && n > 0) {
        Control(null, "-$n", s.template("skipBack", "Back {n} s", "n" to n.toString()), act(CMD_PREVIOUS))
    } else {
        Control(R.drawable.ic_widget_skip_previous, null, s.label("previous", "Previous"), act(CMD_PREVIOUS))
    }
    val forward = if (audiobook && n > 0) {
        Control(null, "+$n", s.template("skipForward", "Forward {n} s", "n" to n.toString()), act(CMD_NEXT))
    } else {
        Control(R.drawable.ic_widget_skip_next, null, s.label("next", "Next"), act(CMD_NEXT))
    }
    return listOf(back, play, forward)
}

/** Lays out up to [slots] of [controls] (play always kept), each with a 48dp touch target. */
@Composable
private fun ControlsRow(controls: List<Control>, slots: Int) {
    val play = controls.first { it.primary }
    val visible = when {
        controls.size == 1 || slots <= 1 -> listOf(play)
        slots == 2 -> listOf(play, controls.last())
        else -> controls
    }
    // Row child budget (Glance caps at 10): at most 3 buttons here.
    visible.forEach { ControlButton(it) }
}

@Composable
private fun ControlButton(c: Control) {
    Box(
        modifier = GlanceModifier.size(MIN_TOUCH).clickable(c.action),
        contentAlignment = Alignment.Center,
    ) {
        val bg = if (c.primary) GlanceTheme.colors.primary else GlanceTheme.colors.secondaryContainer
        val fg = if (c.primary) GlanceTheme.colors.onPrimary else GlanceTheme.colors.onSecondaryContainer
        Box(
            modifier = GlanceModifier.size(if (c.primary) 40.dp else 34.dp)
                .cornerRadius(if (c.primary) 20.dp else 17.dp)
                .background(bg),
            contentAlignment = Alignment.Center,
        ) {
            if (c.icon != null) {
                Image(
                    provider = ImageProvider(c.icon),
                    contentDescription = c.description,
                    colorFilter = ColorFilter.tint(fg),
                    modifier = GlanceModifier.size(if (c.primary) 24.dp else 20.dp),
                )
            } else {
                Text(
                    c.text.orEmpty(),
                    maxLines = 1,
                    style = TextStyle(color = fg, fontSize = 11.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center),
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------

/** Position to draw: the sample plus the time since it when playing, clamped to the duration. */
internal fun shownPosition(np: WidgetNowPlaying, playing: Boolean, now: Long): Long {
    var pos = np.positionMs
    if (playing && np.updatedAt > 0) pos += (now - np.updatedAt).coerceAtLeast(0L)
    if (np.durationMs > 0) pos = pos.coerceAtMost(np.durationMs)
    return pos.coerceAtLeast(0L)
}

internal fun formatClock(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0L)
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, s)
    else String.format(java.util.Locale.US, "%d:%02d", m, s)
}

// ---------------------------------------------------------------------------
// Native control of the live MediaSession
// ---------------------------------------------------------------------------

/**
 * Sends transport commands to the MediaSession of audio_service's `AudioService` in this process.
 *
 * Why not `ACTION_MEDIA_BUTTON` to `MediaButtonReceiver`: that receiver cold-starts the service
 * (foreground-service start from the background, and a session whose Dart handler is not attached
 * yet drops the key), and PLAY_PAUSE is a blind toggle. Reading the live session instead lets the
 * toggle be directional and lets us refuse (and open the app) when nothing is attached.
 *
 * `AudioService.instance` is package-private, so that one field is read by reflection (the class
 * is kept by proguard-rules.pro); the token is then taken through the typed
 * `MediaBrowserServiceCompat.getSessionToken()` (androidx.media, declared in app/build.gradle at
 * the plugin's version). The widget runs in the app process, so the service instance
 * exists exactly while audio_service is up. The platform [MediaController] is built directly: the
 * compat one needs a Looper, which a widget callback thread does not have.
 *
 * Compatibility layer for an external limit: audio_service exposes neither the service instance
 * nor the token, and hardcodes `AudioService.class` (so no app subclass can publish it). Connecting
 * through MediaBrowserCompat instead would BIND_AUTO_CREATE the service on every render. Impact if
 * the plugin changes the field: [controller] returns null and the buttons fall back to opening the
 * app. test/platform/now_playing_audio_service_contract_test.dart pins the field and the keep rule
 * so a plugin upgrade fails there instead. Remove this when audio_service exposes the token.
 */
internal object NowPlayingControl {
    private const val TAG = "NowPlayingControl"
    private const val SERVICE = "com.ryanheise.audioservice.AudioService"

    private fun controller(context: Context): MediaController? = try {
        val field = Class.forName(SERVICE).getDeclaredField("instance").apply { isAccessible = true }
        // Only the package-private field is read by name. Everything after it is a typed call, so
        // R8 rewrites the call sites along with any rename or inlining (a by-name getMethod on
        // MediaSessionCompat.Token.getToken() broke in release: R8 inlines and drops that method).
        val service = field.get(null) as? MediaBrowserServiceCompat
        val token = service?.sessionToken?.token as? MediaSession.Token
        if (token != null) MediaController(context.applicationContext, token) else null
    } catch (t: Throwable) {
        Log.w(TAG, "no live media session", t)
        null
    }

    private fun PlaybackState?.isAttached(): Boolean =
        this != null && state != PlaybackState.STATE_NONE

    /** True when a media session is up and has published a playback state (Dart handler attached). */
    fun isAvailable(context: Context): Boolean = controller(context)?.playbackState.isAttached()

    /** Runs [cmd]; false = nothing to send it to (caller opens the app instead). */
    fun send(context: Context, cmd: String): Boolean {
        val c = controller(context) ?: return false
        val state = c.playbackState
        if (!state.isAttached()) return false
        val t = c.transportControls
        when (cmd) {
            CMD_TOGGLE -> when (state?.state) {
                PlaybackState.STATE_PLAYING, PlaybackState.STATE_BUFFERING, PlaybackState.STATE_FAST_FORWARDING,
                PlaybackState.STATE_REWINDING -> t.pause()
                else -> t.play()
            }
            CMD_NEXT -> t.skipToNext()
            CMD_PREVIOUS -> t.skipToPrevious()
            else -> return false
        }
        return true
    }
}

class NowPlayingActionCallback : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val cmd = parameters[CMD] ?: return
        if (NowPlayingControl.send(context, cmd)) return
        // The session went away between render and tap (process restarted, playback stopped):
        // fall back to opening the app on the player.
        val link = parameters[LINK] ?: "fushi://widget/open"
        try {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(link))
                    .setClassName(context.packageName, MAIN_ACTIVITY)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (t: Throwable) {
            Log.w("NowPlayingControl", "could not open the app from the widget", t)
        }
    }
}

class NowPlayingReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = NowPlayingWidget()
}
