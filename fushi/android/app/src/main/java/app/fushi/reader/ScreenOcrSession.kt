package app.fushi.reader

/**
 * 截屏识字「选取层 ↔ 查词窗」会话协议的纯状态机（BUG-2901）。
 *
 * 两端各一台：
 * - [ScreenOcrLookupReporter]：查词窗（:popup 进程的 PopupDictFlutterActivity）侧，
 *   把 Activity 生命周期翻译成要回报的 [ScreenOcrLookupEvent]。
 * - [ScreenOcrSelectionSession]：选取层（主进程的 ScreenOcrService）侧，收到回报 /
 *   配置变化后决定隐藏、恢复还是收尾。
 *
 * 刻意不碰任何 android.* 类型：决定全在这里，Android 组件只负责接线（广播、Binder、
 * WindowManager），这样 ScreenOcrSessionTest 能在 host JVM 上表驱动地钉住协议。
 */
enum class ScreenOcrLookupEvent {
    /** 查词窗已在前台：选取层这时才隐藏。 */
    SHOWN,

    /** 用户关掉了查词窗：恢复选取层，同一张截图接着点。 */
    CLOSED,

    /** 用户离开了（回桌面 / 切 app / 别的入口复用了查词窗）：整条流程收尾。 */
    LEFT,
}

/** 查词窗侧：生命周期 → 回报。所有方法在主线程调用。 */
class ScreenOcrLookupReporter(private val sink: Sink) {
    /** 实际发出回报（定向广播）。[session] 是这条回报所属的会话号，恒非 0。 */
    fun interface Sink {
        fun report(event: ScreenOcrLookupEvent, session: Long)
    }

    /** 当前挂着的会话号；0 = 本窗不是从截屏选取层打开的（或会话已结束）。 */
    var session: Long = 0L
        private set

    fun onCreate(intentSession: Long) {
        session = intentSession
    }

    /** 本窗被复用：换了会话（含换成「不是截屏入口」）时，原来那张截图的会话到此为止。 */
    fun onNewIntent(intentSession: Long) {
        if (session != 0L && intentSession != session) sink.report(ScreenOcrLookupEvent.LEFT, session)
        session = intentSession
    }

    fun onResume() {
        if (session != 0L) sink.report(ScreenOcrLookupEvent.SHOWN, session)
    }

    /** 关窗（finish）先走 onPause：在这里报 CLOSED 并清会话，onStop 就不会再报一次。 */
    fun onPause(isFinishing: Boolean) {
        if (!isFinishing || session == 0L) return
        sink.report(ScreenOcrLookupEvent.CLOSED, session)
        session = 0L
    }

    /**
     * 被别的透明窗压到 paused 后再 finish 不会重走 onPause：在这里补报 CLOSED。
     * 没关窗却不可见了：截图已过时，报 LEFT。
     */
    fun onStop(isFinishing: Boolean) {
        if (session == 0L) return
        sink.report(if (isFinishing) ScreenOcrLookupEvent.CLOSED else ScreenOcrLookupEvent.LEFT, session)
        session = 0L
    }
}

/** 选取层侧：回报 / 配置变化 → 隐藏、恢复或收尾。所有方法在主线程调用。 */
/**
 * [T] 是查词窗的存活令牌类型（生产里是 IBinder；单测用任意对象），状态机只转交不解读。
 */
class ScreenOcrSelectionSession<T : Any>(private val effects: Effects<T>) {
    /**
     * 一张截图的屏幕身份：截屏时屏幕的物理像素尺寸 + display rotation。选取层的
     * 定格帧与行框都按这个几何算，身份一变就不能再拿出来用（不尝试映射旧框）。
     */
    data class ScreenIdentity(val width: Int, val height: Int, val rotation: Int)

    interface Effects<T : Any> {
        /** 盯住查词窗进程（linkToDeath）；令牌已死返回 false。 */
        fun watchLookupToken(token: T): Boolean

        fun unwatchLookupToken()

        fun setSelectionHidden(hidden: Boolean)

        /** 整条流程收尾；实现方须随后调 [reset]。 */
        fun finishFlow()
    }

    /** 当前查词会话号；0 = 没有查词窗挂在这张截图上。 */
    var sessionId: Long = 0L
        private set

    var hidden: Boolean = false
        private set

    /** 这张截图的屏幕身份；null = 还没截屏（或流程已收尾）。 */
    var capturedIdentity: ScreenIdentity? = null
        private set

    fun onCaptureStarted(identity: ScreenIdentity) {
        capturedIdentity = identity
    }

    /** 点字拉起查词窗：开一个新会话（旧会话的迟到回报从此一律忽略）。 */
    fun onLookupLaunched(newSessionId: Long) {
        sessionId = newSessionId
    }

    /** [token] 只有 SHOWN 用得上；[current] 是此刻的屏幕身份，只有 CLOSED 用得上。 */
    fun onLookupEvent(
        event: ScreenOcrLookupEvent,
        session: Long,
        token: T?,
        current: ScreenIdentity,
    ) {
        if (session == 0L || session != sessionId) return
        when (event) {
            ScreenOcrLookupEvent.SHOWN -> {
                // 先盯住令牌再隐藏：没有死亡通知就宁可不藏（查词窗压在选取层下面），
                // 也不藏起来回不来。
                if (token == null || !effects.watchLookupToken(token)) return
                setHidden(true)
            }
            ScreenOcrLookupEvent.CLOSED -> {
                sessionId = 0L
                effects.unwatchLookupToken()
                // 关窗期间屏幕转过 / 尺寸变了：旧定格帧与当前几何对不上，收尾。
                if (!matchesCapture(current)) {
                    effects.finishFlow()
                    return
                }
                setHidden(false)
            }
            ScreenOcrLookupEvent.LEFT -> {
                sessionId = 0L
                effects.finishFlow()
            }
        }
    }

    /** Service.onConfigurationChanged：截图之后屏幕几何变了就收尾。 */
    fun onConfigurationChanged(current: ScreenIdentity) {
        if (!matchesCapture(current)) effects.finishFlow()
    }

    /** 查词窗所在进程死了：选取层不能永远藏着，收尾。 */
    fun onLookupProcessDied() {
        effects.finishFlow()
    }

    /** finishFlow 里调用：清空全部会话状态。 */
    fun reset() {
        sessionId = 0L
        hidden = false
        capturedIdentity = null
    }

    private fun matchesCapture(current: ScreenIdentity): Boolean {
        val captured = capturedIdentity ?: return true
        return captured == current
    }

    private fun setHidden(value: Boolean) {
        hidden = value
        effects.setSelectionHidden(value)
    }
}
