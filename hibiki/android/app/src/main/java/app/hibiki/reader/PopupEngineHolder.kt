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

    @Volatile
    private var onFinish: (() -> Unit)? = null

    @Volatile
    private var channel: MethodChannel? = null

    fun setPendingText(text: String) {
        pendingText = text
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
                    map["charIndex"] = -1
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
    fun pushProcessText(text: String) {
        if (text.isBlank()) return
        pendingText = text
        val ch = channel ?: return
        val args = HashMap<String, Any>()
        args["text"] = text
        args["charIndex"] = -1
        Handler(Looper.getMainLooper()).post { ch.invokeMethod("onNewProcessText", args) }
    }
}
