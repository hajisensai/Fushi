package app.hibiki.reader

import android.content.Context
import android.os.Handler
import android.os.Looper
import app.hibiki.reader.constants.ChannelNames
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Builds and caches one warm FlutterEngine running the `popupMain` Dart
 * entrypoint inside the :popup process. External dictionary lookups
 * (PROCESS_TEXT / SEND / TRANSLATE / hibiki://lookup) reuse this engine so
 * the nested-capable Flutter popup (PopupDictionaryPage) replaces the old
 * native WebView popup.
 *
 * The `/popup` channel handler is registered BEFORE the Dart entrypoint is
 * executed because Dart's PopupChannel.init polls `getInitialProcessText` as
 * soon as the engine boots; registering after the entrypoint runs would lose
 * the first word.
 */
object PopupEngineHolder {
    const val ENGINE_ID: String = "hibiki_popup_engine"
    private const val ENTRYPOINT: String = "popupMain"

    @Volatile
    private var pendingText: String = ""

    /**
     * Character index of the tapped word inside [pendingText], or -1 when the
     * caller has no per-character hit (e.g. a whole-sentence PROCESS_TEXT from
     * the system text-selection menu). The floating lyric/subtitle strip taps a
     * specific glyph and ships its index here so the Dart popup can segment the
     * tapped word instead of always searching from the sentence head.
     */
    @Volatile
    private var pendingCharIndex: Int = -1

    /**
     * On-screen rectangle (physical px: left, top, right, bottom) of the tapped
     * glyph, or null when the caller supplied no anchor (TODO-872). Only the
     * floating lyric/subtitle strip ships an anchor; system PROCESS_TEXT /
     * hibiki://lookup leave it null so the Dart popup keeps its default
     * top-center placement.
     */
    @Volatile
    private var pendingAnchor: IntArray? = null

    /**
     * On-screen rectangle (physical px: left, top, right, bottom) of the whole
     * subtitle window, or null when the caller supplied none (TODO-708 P1). Only
     * the floating lyric/subtitle strip ships it; the Dart popup avoids this
     * superset so the card never covers any glyph in the strip.
     */
    @Volatile
    private var pendingSubtitle: IntArray? = null

    @Volatile
    private var onFinish: (() -> Unit)? = null

    @Volatile
    private var channel: MethodChannel? = null

    fun setPendingText(
        text: String,
        charIndex: Int = -1,
        anchor: IntArray? = null,
        subtitle: IntArray? = null,
    ) {
        pendingText = text
        pendingCharIndex = charIndex
        pendingAnchor = anchor
        pendingSubtitle = subtitle
    }

    fun setOnFinish(callback: (() -> Unit)?) {
        onFinish = callback
    }

    /** Returns true when the engine had to be created now (cold start). */
    @Synchronized
    fun ensureEngine(context: Context): Boolean {
        val cache = FlutterEngineCache.getInstance()
        if (cache.get(ENGINE_ID) != null) return false

        val engine = FlutterEngine(context.applicationContext, null, false)
        FloatingDictPluginRegistrant.registerWith(engine)

        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, ChannelNames.POPUP)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialProcessText" -> {
                    val map = HashMap<String, Any>()
                    map["text"] = pendingText
                    map["charIndex"] = pendingCharIndex
                    putAnchor(map, pendingAnchor)
                    putSubtitle(map, pendingSubtitle)
                    result.success(map)
                }
                "finishPopup" -> {
                    result.success(null)
                    onFinish?.invoke()
                }
                else -> result.notImplemented()
            }
        }
        channel = ch

        val bundlePath = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(bundlePath, ENTRYPOINT)
        )
        cache.put(ENGINE_ID, engine)
        return true
    }

    /** Warm-reuse / onNewIntent path: push a new term into the running Dart app. */
    fun pushProcessText(
        text: String,
        charIndex: Int = -1,
        anchor: IntArray? = null,
        subtitle: IntArray? = null,
    ) {
        if (text.isBlank()) return
        pendingText = text
        pendingCharIndex = charIndex
        pendingAnchor = anchor
        pendingSubtitle = subtitle
        val ch = channel ?: return
        val args = HashMap<String, Any>()
        args["text"] = text
        args["charIndex"] = charIndex
        putAnchor(args, anchor)
        putSubtitle(args, subtitle)
        Handler(Looper.getMainLooper()).post { ch.invokeMethod("onNewProcessText", args) }
    }

    /**
     * Encode the tapped-glyph anchor rectangle (physical px) into the channel
     * payload as a 4-element [left, top, right, bottom] int list, or omit the
     * key entirely when there is no anchor — the Dart side reads a missing
     * "anchor" as null and keeps the default top-center placement (TODO-872).
     */
    private fun putAnchor(map: HashMap<String, Any>, anchor: IntArray?) {
        if (anchor == null || anchor.size != 4) return
        map["anchor"] = listOf(anchor[0], anchor[1], anchor[2], anchor[3])
    }

    /**
     * Encode the whole subtitle-window rectangle (physical px) into the channel
     * payload as a 4-element [left, top, right, bottom] int list, or omit the key
     * entirely when there is none - the Dart side reads a missing "subtitle" as
     * null and avoids only the tapped glyph (TODO-708 P1).
     */
    private fun putSubtitle(map: HashMap<String, Any>, subtitle: IntArray?) {
        if (subtitle == null || subtitle.size != 4) return
        map["subtitle"] = listOf(subtitle[0], subtitle[1], subtitle[2], subtitle[3])
    }
}
