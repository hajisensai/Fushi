package app.fushi.reader

import android.content.Context
import android.os.Handler
import android.os.Looper
import app.fushi.reader.constants.ChannelNames
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Builds and caches one warm FlutterEngine running the `popupMain` Dart
 * entrypoint inside the :popup process. External dictionary lookups
 * (PROCESS_TEXT / SEND / TRANSLATE / fushi://lookup) reuse this engine so
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
     * fushi://lookup leave it null so the Dart popup keeps its default
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

    /**
     * BUG-1757：关闭回调必须记住**是谁注册的**。
     *
     * 本 holder 是 object 单例，而 [PopupDictFlutterActivity] 会被反复创建/销毁。旧实现
     * 是裸的 `onFinish` 字段 + `setOnFinish(null)`，任何实例都能清掉任何实例注册的回调。
     * Android 的生命周期顺序是「新实例 onCreate → 旧实例 onDestroy」，于是「关掉一个查词
     * 窗、紧接着查下一个词」这条最常见的连续查词路径必然踩中：新窗在 onCreate 里注册了
     * 自己的 finish，旧窗随后在 onDestroy 里把它清成 null。此后新窗调 finishPopup 时
     * `onFinish` 是 null、静默什么都不做，而 Dart 侧 `_close()` 已经把 `_isClosing` 锁死
     * ——窗口留在屏幕上、外观毫无变化、X / 点外面 / 横滑 / 系统返回全部静默早退，
     * 用户侧就是「查词弹窗关不掉」，里面的原生 WebView 还活着所以内容仍能滚一点。
     *
     * owner 与 callback 合成**一个**字段而不是两个 `@Volatile`：两个字段无法原子更新，
     * 读到「新 owner + 旧 callback」的撕裂状态同样会关错窗。
     */
    private class FinishHandler(val owner: Any, val callback: () -> Unit)

    @Volatile
    private var finishHandler: FinishHandler? = null

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

    /**
     * 注册「关闭当前查词窗」回调。[owner] 是注册方（Activity 实例），[clearOnFinish]
     * 据它判断该不该注销。
     */
    fun setOnFinish(owner: Any, callback: () -> Unit) {
        finishHandler = FinishHandler(owner, callback)
    }

    /**
     * 注销 [owner] 注册的回调——**当前回调不属于它就什么都不做**（BUG-1757：旧 Activity
     * 的 onDestroy 晚于新 Activity 的 onCreate，绝不能清掉新窗刚注册的那个）。
     *
     * 没有「无条件清空」的入口是有意的：那个入口存在多久，这个竞态就存在多久。
     */
    fun clearOnFinish(owner: Any) {
        if (finishHandler?.owner !== owner) return
        finishHandler = null
    }

    /** Returns true when the engine had to be created now (cold start). */
    @Synchronized
    fun ensureEngine(context: Context): Boolean {
        val cache = FlutterEngineCache.getInstance()
        if (cache.get(ENGINE_ID) != null) return false

        val engine = FlutterEngine(context.applicationContext, null, false)
        // BUG-865：传 applicationContext 让 registrant 也注册 anki channel，使 popupMain
        // 副 engine 上的 app 外查词面制卡不再抛 MissingPluginException。
        FloatingDictPluginRegistrant.registerWith(engine, context.applicationContext)
        SelectionActionChannel.registerWith(engine, context.applicationContext)

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
                    // BUG-1757：把「有没有人真的接下这次关闭」回给 Dart。没人接时 Dart
                    // 侧必须解开 _isClosing，否则窗口留在屏上而所有关闭入口永久早退。
                    val handler = finishHandler
                    result.success(handler != null)
                    handler?.callback?.invoke()
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
