package app.fushi.reader

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Java 未捕获异常落盘（反馈 TlyH9HAD9T / E5IZOyVcbm / Z624TCPsBP / fS-G9X36Xc）：
 * ApplicationExitInfo 对 REASON_CRASH 不给 trace，靠链式处理器落盘再按 pid + 时间窗并入报告。
 */
class JavaCrashRecordTest {
    private fun text(sink: JavaCrashRecord.Utf8Sink): String =
        String(sink.buffer(), 0, sink.length(), Charsets.UTF_8)

    private fun tempDir(): File = Files.createTempDirectory("jcrash").toFile()

    @Test
    fun formatWritesHeaderClassMessageFramesAndCauseChain() {
        val root = IllegalStateException("root cause 根因")
        val outer = RuntimeException("outer", root)
        val sink = JavaCrashRecord.Utf8Sink(JavaCrashRecord.MAX_FILE_BYTES)

        JavaCrashRecord.format(sink, outer, "main", 2L, 4242, "app.fushi.reader:popup", 1761550000000L)
        val s = text(sink)

        assertTrue(s.startsWith("java uncaught exception\n"))
        assertTrue(s.contains("process=app.fushi.reader:popup pid=4242 thread=main (id=2)"))
        assertTrue(s.contains("at=1761550000000"))
        assertTrue(s.contains("java.lang.RuntimeException: outer\n"))
        assertTrue(s.contains("\tat app.fushi.reader.JavaCrashRecordTest."))
        assertTrue(s.contains("Caused by: java.lang.IllegalStateException: root cause 根因\n"))
        assertTrue(s.contains(" more\n"), "cause 与外层共有的帧应折叠成 ... N more")
        assertTrue(!s.contains("[truncated]"))
    }

    @Test
    fun formatTruncatesAtCapacityKeepingClassAndTopFrame() {
        val sink = JavaCrashRecord.Utf8Sink(400)
        val error = OutOfMemoryError("Failed to allocate a 268435456 byte allocation")

        JavaCrashRecord.format(sink, error, "worker", 9L, 77, "app.fushi.reader", 1L)
        val s = text(sink)

        assertTrue(sink.length() <= 400)
        assertTrue(s.contains("java.lang.OutOfMemoryError: Failed to allocate"))
        assertTrue(s.contains("\tat "), "截断前至少写出顶部栈帧")
        assertTrue(s.endsWith(JavaCrashRecord.TRUNCATED_MARKER))
    }

    @Test
    fun formatSurvivesCircularCauseChain() {
        val a = RuntimeException("a")
        val b = RuntimeException("b", a)
        a.initCause(b)
        val sink = JavaCrashRecord.Utf8Sink(JavaCrashRecord.MAX_FILE_BYTES)

        JavaCrashRecord.format(sink, a, "main", 1L, 1, "p", 1L)

        assertTrue(text(sink).contains("[CIRCULAR REFERENCE]"))
    }

    @Test
    fun sinkEncodesUtf8AndNumbers() {
        val sink = JavaCrashRecord.Utf8Sink(64)
        sink.append("é漢😀").append(' ').append(-1234L).append(' ').append(Long.MIN_VALUE)
        assertEquals("é漢😀 -1234 ${Long.MIN_VALUE}", text(sink))
    }

    @Test
    fun fileNameRoundTripsAndSanitizesProcessName() {
        val name = JavaCrashRecord.fileName("app.fushi.reader:network_challenge", 31337, 1761550000123L)
        assertEquals("jcrash-1761550000123-31337-app.fushi.reader_network_challenge.txt", name)
        val parsed = assertNotNull(JavaCrashRecord.parseFileName(name))
        assertEquals(1761550000123L, parsed[0])
        assertEquals(31337L, parsed[1])
        assertNull(JavaCrashRecord.parseFileName("tombstone_00"))
        assertNull(JavaCrashRecord.parseFileName("jcrash-x-1-p.txt"))
    }

    @Test
    fun matchesExitRequiresSamePidInsideTimeWindow() {
        val exitTs = 1_000_000L
        assertTrue(JavaCrashRecord.matchesExit(10, exitTs - 200, 10, exitTs))
        assertTrue(JavaCrashRecord.matchesExit(10, exitTs + 1_000, 10, exitTs))
        assertTrue(!JavaCrashRecord.matchesExit(11, exitTs - 200, 10, exitTs), "pid 不同")
        assertTrue(
            !JavaCrashRecord.matchesExit(10, exitTs - JavaCrashRecord.MATCH_BEFORE_EXIT_MS - 1, 10, exitTs),
            "太早：pid 复用的旧记录",
        )
        assertTrue(
            !JavaCrashRecord.matchesExit(10, exitTs + JavaCrashRecord.MATCH_AFTER_EXIT_MS + 1, 10, exitTs),
            "晚于退出：不是这次退出",
        )
    }

    @Test
    fun findMatchPicksClosestRecordForPid() {
        val dir = tempDir()
        val far = File(dir, JavaCrashRecord.fileName("p", 10, 1_000_000L - 30_000)).apply { writeText("far") }
        val near = File(dir, JavaCrashRecord.fileName("p", 10, 1_000_000L - 100)).apply { writeText("near") }
        File(dir, JavaCrashRecord.fileName("p", 11, 1_000_000L - 50)).writeText("other pid")

        assertEquals(near.name, JavaCrashRecord.findMatch(dir.listFiles(), 10, 1_000_000L)?.name)
        assertNull(JavaCrashRecord.findMatch(dir.listFiles(), 12, 1_000_000L))
        assertNull(JavaCrashRecord.findMatch(null, 10, 1_000_000L))
        assertTrue(far.exists())
        dir.deleteRecursively()
    }

    @Test
    fun pruneKeepsNewestRecordsAndIgnoresForeignFiles() {
        val dir = tempDir()
        for (i in 1..5) File(dir, JavaCrashRecord.fileName("p", i, i * 1000L)).writeText("$i")
        val foreign = File(dir, "notes.txt").apply { writeText("x") }

        assertEquals(3, JavaCrashRecord.prune(dir, 2))

        val left = dir.listFiles()!!.map { it.name }.toSet()
        assertEquals(
            setOf(JavaCrashRecord.fileName("p", 4, 4000L), JavaCrashRecord.fileName("p", 5, 5000L), foreign.name),
            left,
        )
        dir.deleteRecursively()
    }

    @Test
    fun summarizeKeepsHeadAndInnermostCause() {
        val head = "java.lang.RuntimeException: outer\n" + "\tat a.B.c(B.java:1)\n".repeat(200)
        val text = head + "Caused by: java.lang.OutOfMemoryError: real root\n\tat x.Y.z(Y.java:9)\n"
        val s = JavaCrashRecord.summarize(text, 1000)

        assertTrue(s.length <= 1000)
        assertTrue(s.startsWith("java.lang.RuntimeException: outer"))
        assertTrue(s.contains("Caused by: java.lang.OutOfMemoryError: real root"))
        assertEquals("short", JavaCrashRecord.summarize("short", 1000))
    }

    @Test
    fun chainedHandlerWritesRecordThenAlwaysDelegates() {
        val dir = tempDir()
        val seen = mutableListOf<Throwable>()
        val handler = JavaCrashRecord.ChainedHandler(dir, "app.fushi.reader", 4242) { _, e -> seen.add(e) }
        val error = IllegalArgumentException("boom")

        handler.uncaughtException(Thread.currentThread(), error)

        assertEquals(listOf<Throwable>(error), seen, "原处理器必须收到同一个异常")
        val files = dir.listFiles()!!
        assertEquals(1, files.size)
        val parsed = assertNotNull(JavaCrashRecord.parseFileName(files[0].name))
        assertEquals(4242L, parsed[1])
        assertTrue(files[0].readText().contains("java.lang.IllegalArgumentException: boom"))
        dir.deleteRecursively()
    }

    @Test
    fun chainedHandlerStillDelegatesWhenRecordingFails() {
        val missing = File(tempDir(), "does/not/exist")
        val seen = mutableListOf<Throwable>()
        val handler = JavaCrashRecord.ChainedHandler(missing, "p", 1) { _, e -> seen.add(e) }
        val error = RuntimeException("x")

        handler.uncaughtException(Thread.currentThread(), error)

        assertEquals(listOf<Throwable>(error), seen, "落盘失败也不能改变崩溃行为")
    }
}
