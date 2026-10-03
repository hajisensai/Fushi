package app.fushi.reader

import app.fushi.reader.ScreenOcrLookupEvent.CLOSED
import app.fushi.reader.ScreenOcrLookupEvent.LEFT
import app.fushi.reader.ScreenOcrLookupEvent.SHOWN
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** 截屏识字「选取层 ↔ 查词窗」会话协议（BUG-2901）的两台纯状态机。 */
class ScreenOcrSessionTest {
    // ── 查词窗侧：生命周期 → 回报 ───────────────────────────────────────────────

    private sealed interface Step {
        data class Create(val session: Long) : Step
        data class NewIntent(val session: Long) : Step
        object Resume : Step
        data class Pause(val finishing: Boolean) : Step
        data class Stop(val finishing: Boolean) : Step
    }

    private fun report(vararg steps: Step): List<Pair<ScreenOcrLookupEvent, Long>> {
        val sent = mutableListOf<Pair<ScreenOcrLookupEvent, Long>>()
        val reporter = ScreenOcrLookupReporter { event, session -> sent += event to session }
        for (step in steps) {
            when (step) {
                is Step.Create -> reporter.onCreate(step.session)
                is Step.NewIntent -> reporter.onNewIntent(step.session)
                Step.Resume -> reporter.onResume()
                is Step.Pause -> reporter.onPause(step.finishing)
                is Step.Stop -> reporter.onStop(step.finishing)
            }
        }
        return sent
    }

    private data class ReporterCase(
        val name: String,
        val steps: List<Step>,
        val expected: List<Pair<ScreenOcrLookupEvent, Long>>,
    )

    @Test
    fun reporterTranslatesLifecycleIntoExactlyOneTerminalReport() {
        val cases = listOf(
            ReporterCase(
                "非截屏入口：什么都不报",
                listOf(Step.Create(0), Step.Resume, Step.Pause(true), Step.Stop(true)),
                emptyList(),
            ),
            ReporterCase(
                "正常关窗：onPause(finishing) 报 CLOSED 并清会话，onStop 不重复回报",
                listOf(Step.Create(7), Step.Resume, Step.Pause(true), Step.Stop(true)),
                listOf(SHOWN to 7L, CLOSED to 7L),
            ),
            ReporterCase(
                "被透明窗压到 paused 后再 finish：onPause 不报，onStop(finishing) 补报 CLOSED",
                listOf(Step.Create(7), Step.Resume, Step.Pause(false), Step.Stop(true)),
                listOf(SHOWN to 7L, CLOSED to 7L),
            ),
            ReporterCase(
                "回桌面 / 切 app：没 finish 却不可见了 → LEFT",
                listOf(Step.Create(7), Step.Resume, Step.Pause(false), Step.Stop(false)),
                listOf(SHOWN to 7L, LEFT to 7L),
            ),
            ReporterCase(
                "LEFT 之后再回来不复活旧会话",
                listOf(
                    Step.Create(7), Step.Resume, Step.Pause(false), Step.Stop(false),
                    Step.Resume, Step.Pause(true), Step.Stop(true),
                ),
                listOf(SHOWN to 7L, LEFT to 7L),
            ),
            ReporterCase(
                "别的入口复用本窗：旧会话报 LEFT，新入口不是截屏 → 之后不再报",
                listOf(Step.Create(7), Step.Resume, Step.NewIntent(0), Step.Pause(true), Step.Stop(true)),
                listOf(SHOWN to 7L, LEFT to 7L),
            ),
            ReporterCase(
                "同一选取层再点一个字（新会话）复用本窗：旧会话 LEFT，新会话照常 SHOWN / CLOSED",
                listOf(
                    Step.Create(7), Step.Resume, Step.Pause(false),
                    Step.NewIntent(9), Step.Resume, Step.Pause(true), Step.Stop(true),
                ),
                listOf(SHOWN to 7L, LEFT to 7L, SHOWN to 9L, CLOSED to 9L),
            ),
            ReporterCase(
                "同一会话号的重复 intent 不算离开",
                listOf(Step.Create(7), Step.NewIntent(7), Step.Resume),
                listOf(SHOWN to 7L),
            ),
        )
        for (case in cases) {
            assertEquals(case.expected, report(*case.steps.toTypedArray()), case.name)
        }
    }

    // ── 选取层侧：回报 / 配置变化 → 隐藏、恢复、收尾 ─────────────────────────────

    private val portrait = ScreenOcrSelectionSession.ScreenIdentity(1080, 2400, 0)
    private val landscape = ScreenOcrSelectionSession.ScreenIdentity(2400, 1080, 1)
    private val upsideDown = ScreenOcrSelectionSession.ScreenIdentity(1080, 2400, 2)

    /** 记录副作用调用顺序；finishFlow 照生产实现调 reset。 */
    private class Recorder(var tokenAlive: Boolean = true) :
        ScreenOcrSelectionSession.Effects<String> {
        lateinit var session: ScreenOcrSelectionSession<String>
        val calls = mutableListOf<String>()

        override fun watchLookupToken(token: String): Boolean {
            calls += "watch:$token"
            return tokenAlive
        }

        override fun unwatchLookupToken() {
            calls += "unwatch"
        }

        override fun setSelectionHidden(hidden: Boolean) {
            calls += if (hidden) "hide" else "show"
        }

        override fun finishFlow() {
            calls += "finish"
            session.reset()
        }
    }

    private fun newSession(tokenAlive: Boolean = true): Pair<ScreenOcrSelectionSession<String>, Recorder> {
        val recorder = Recorder(tokenAlive)
        val session = ScreenOcrSelectionSession(recorder)
        recorder.session = session
        session.onCaptureStarted(portrait)
        return session to recorder
    }

    @Test
    fun shownWatchesTokenBeforeHidingAndClosedRestores() {
        val (s, r) = newSession()
        s.onLookupLaunched(7)
        s.onLookupEvent(SHOWN, 7, "tok", portrait)
        assertTrue(s.hidden)
        s.onLookupEvent(CLOSED, 7, null, portrait)
        assertEquals(listOf("watch:tok", "hide", "unwatch", "show"), r.calls)
        assertFalse(s.hidden)
        assertEquals(0L, s.sessionId)
        // 恢复后同一张截图仍可再点：身份还在。
        assertEquals(portrait, s.capturedIdentity)
    }

    @Test
    fun shownWithoutLiveTokenNeverHides() {
        val (s, r) = newSession(tokenAlive = false)
        s.onLookupLaunched(7)
        s.onLookupEvent(SHOWN, 7, null, portrait)
        s.onLookupEvent(SHOWN, 7, "dead", portrait)
        assertEquals(listOf("watch:dead"), r.calls)
        assertFalse(s.hidden)
        // 会话仍挂着：之后的 CLOSED 照常收得到。
        assertEquals(7L, s.sessionId)
    }

    @Test
    fun staleOrZeroSessionReportsAreIgnored() {
        val (s, r) = newSession()
        s.onLookupLaunched(7)
        s.onLookupEvent(SHOWN, 0, "tok", portrait)
        s.onLookupEvent(LEFT, 6, null, portrait)
        s.onLookupEvent(CLOSED, 8, null, portrait)
        assertEquals(emptyList<String>(), r.calls)
        // 再点一个字开新会话后，旧会话迟到的 CLOSED / LEFT 不得动选取层。
        s.onLookupEvent(SHOWN, 7, "tok", portrait)
        s.onLookupLaunched(9)
        s.onLookupEvent(LEFT, 7, null, portrait)
        s.onLookupEvent(CLOSED, 7, null, portrait)
        assertEquals(listOf("watch:tok", "hide"), r.calls)
        // 新会话 9 的 CLOSED 照常生效；生效后号已清零，同号迟到回报一律忽略。
        s.onLookupEvent(CLOSED, 9, null, portrait)
        assertEquals(listOf("watch:tok", "hide", "unwatch", "show"), r.calls)
        s.onLookupEvent(LEFT, 9, null, portrait)
        assertEquals(listOf("watch:tok", "hide", "unwatch", "show"), r.calls)
    }

    @Test
    fun leftFinishesFlow() {
        val (s, r) = newSession()
        s.onLookupLaunched(7)
        s.onLookupEvent(SHOWN, 7, "tok", portrait)
        s.onLookupEvent(LEFT, 7, null, portrait)
        assertEquals(listOf("watch:tok", "hide", "finish"), r.calls)
        assertEquals(0L, s.sessionId)
        assertFalse(s.hidden)
        assertEquals(null, s.capturedIdentity)
    }

    @Test
    fun lookupProcessDeathFinishesFlow() {
        val (s, r) = newSession()
        s.onLookupLaunched(7)
        s.onLookupEvent(SHOWN, 7, "tok", portrait)
        s.onLookupProcessDied()
        assertEquals(listOf("watch:tok", "hide", "finish"), r.calls)
        // 收尾后迟到的 CLOSED 不得把选取层恢复出来。
        s.onLookupEvent(CLOSED, 7, null, portrait)
        assertEquals(listOf("watch:tok", "hide", "finish"), r.calls)
    }

    private data class GeometryCase(val name: String, val current: ScreenOcrSelectionSession.ScreenIdentity, val finishes: Boolean)

    private val geometryCases = listOf(
        GeometryCase("未变", portrait, false),
        GeometryCase("横屏（尺寸与 rotation 都变）", landscape, true),
        GeometryCase("倒置（尺寸相同、rotation 变）", upsideDown, true),
        GeometryCase("只有尺寸变（折叠屏展开）", ScreenOcrSelectionSession.ScreenIdentity(1812, 2176, 0), true),
    )

    @Test
    fun closedAfterGeometryChangeFinishesInsteadOfRestoringStaleFrame() {
        for (case in geometryCases) {
            val (s, r) = newSession()
            s.onLookupLaunched(7)
            s.onLookupEvent(SHOWN, 7, "tok", portrait)
            s.onLookupEvent(CLOSED, 7, null, case.current)
            val expected = if (case.finishes) {
                listOf("watch:tok", "hide", "unwatch", "finish")
            } else {
                listOf("watch:tok", "hide", "unwatch", "show")
            }
            assertEquals(expected, r.calls, case.name)
        }
    }

    @Test
    fun configurationChangeFinishesOnlyWhenGeometryDiffers() {
        for (case in geometryCases) {
            // 选取层隐藏中（查词窗在前）与可见时都一样：几何一变就收尾。
            for (hiddenFirst in listOf(true, false)) {
                val (s, r) = newSession()
                if (hiddenFirst) {
                    s.onLookupLaunched(7)
                    s.onLookupEvent(SHOWN, 7, "tok", portrait)
                }
                r.calls.clear()
                s.onConfigurationChanged(case.current)
                assertEquals(
                    if (case.finishes) listOf("finish") else emptyList<String>(),
                    r.calls,
                    "${case.name} hidden=$hiddenFirst",
                )
            }
        }
    }

    @Test
    fun configurationChangeBeforeCaptureOrAfterFinishIsNoOp() {
        val recorder = Recorder()
        val s = ScreenOcrSelectionSession(recorder)
        recorder.session = s
        s.onConfigurationChanged(landscape)
        assertEquals(emptyList<String>(), recorder.calls)
        s.onCaptureStarted(portrait)
        s.onLookupLaunched(7)
        s.onLookupEvent(LEFT, 7, null, portrait)
        recorder.calls.clear()
        s.onConfigurationChanged(landscape)
        assertEquals(emptyList<String>(), recorder.calls)
    }
}
