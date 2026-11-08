package app.fushi.reader

import java.io.ByteArrayOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * #MdVKlfPOWD：旧摘要只抽 tombstone proto 前 64 KB 的可打印串，线程表顺序与崩溃线程无关，
 * 报告里只剩几条无关线程的帧。这里按 tombstone.proto 线格式手搓一份：崩溃线程排在一百多条
 * 线程之后、前面的线程各带大块栈内存，摘要必须点名崩溃线程并列出它的帧。
 */
class TombstoneSummaryTest {
    private class Proto {
        val out = ByteArrayOutputStream()
        fun varint(v: Long): Proto {
            var x = v
            while (true) {
                if ((x and 0x7fL.inv()) == 0L) { out.write(x.toInt()); return this }
                out.write(((x and 0x7f) or 0x80).toInt())
                x = x ushr 7
            }
        }
        fun tag(field: Int, wire: Int) = varint(((field shl 3) or wire).toLong())
        fun int(field: Int, v: Long) = tag(field, 0).varint(v)
        fun bytes(field: Int, b: ByteArray): Proto { tag(field, 2).varint(b.size.toLong()); out.write(b); return this }
        fun str(field: Int, s: String) = bytes(field, s.toByteArray())
        fun msg(field: Int, m: Proto) = bytes(field, m.out.toByteArray())
        fun fixed64(field: Int, v: Long): Proto { tag(field, 1); repeat(8) { out.write(((v ushr (8 * it)) and 0xff).toInt()) }; return this }
        fun toBytes(): ByteArray = out.toByteArray()
    }

    private fun frame(relPc: Long, file: String, fn: String = "", off: Long = 0, mapOffset: Long = 0, buildId: String = "") =
        Proto().int(1, relPc).int(2, relPc + 0x7000000000L).str(4, fn).int(5, off).str(6, file)
            .int(7, mapOffset).str(8, buildId)

    private fun thread(id: Int, name: String, frames: List<Proto>, memoryBytes: Int = 0): Proto {
        val t = Proto().int(1, id.toLong()).str(2, name)
        // registers（field 3）与栈内存片段（field 5）：摘要不要，但要能跳过。
        t.msg(3, Proto().str(1, "x0").int(2, 0xdeadbeefL))
        frames.forEach { t.msg(4, it) }
        if (memoryBytes > 0) t.msg(5, Proto().str(1, "sp").bytes(3, ByteArray(memoryBytes)))
        return t
    }

    private fun tombstone(crashTid: Int): ByteArray {
        val p = Proto()
        p.int(1, 3) // arch
        p.str(2, "Redmi/duchamp/duchamp:15/AP3A.240905.015.A2/OS2.0.210.0.VNLCNXM:user/release-keys")
        p.str(3, "0").str(4, "2026-11-07 08:05:17.867725926+0800")
        p.int(5, 14489).int(6, crashTid.toLong()).int(7, 10123)
        p.str(8, "u:r:untrusted_app:s0:c58,c259,c512,c768").str(9, "app.fushi.reader")
        p.msg(10, Proto().int(1, 6).str(2, "SIGABRT").int(3, -1L).str(4, "SI_QUEUE").int(5, 1).int(6, 10123).int(7, 14489))
        p.str(14, "FORTIFY: pthread_mutex_lock called on a destroyed mutex (0xb400007b25adc2f0)")
        p.msg(15, Proto().str(1, "fixture cause"))
        // 一百多条线程，崩溃线程放在最后；前面的线程各带 4 KB 栈内存，总量远超旧的 64 KB 读取上限。
        for (i in 0 until 107) {
            val id = 20000 + i
            val entry = Proto().int(1, id.toLong()).msg(2, thread(id, "hwuiTask$i",
                listOf(frame(0x5823c, "/apex/com.android.runtime/lib64/bionic/libc.so", "syscall", 28)), 4096))
            p.msg(16, entry)
        }
        val crash = thread(crashTid, "DartWorker", listOf(
            frame(0x5823c, "/apex/com.android.runtime/lib64/bionic/libc.so", "abort", 164, buildId = "bc5c61ed852b3f4266cdfdd25499ef95"),
            frame(0x9dfeb0, "/data/app/~~8vRz8sK8_Lv2MCdxuTqLXQ==/app.fushi.reader-Lht3OZfG6NGgrNtfJYHmag==/base.apk", mapOffset = 0x8378000, buildId = "3042c18dd243797671f94adc831f8ada24daec26"),
        ))
        p.msg(16, Proto().int(1, crashTid.toLong()).msg(2, crash))
        p.msg(16, Proto().int(1, 14489).msg(2, thread(14489, "app.fushi.reader",
            listOf(frame(0x8d9b0, "/apex/com.android.runtime/lib64/bionic/libc.so", "pthread_cond_wait", 76)))))
        p.msg(17, Proto().str(1, "/system/lib64/libc++.so")) // memory_mappings：跳过
        p.fixed64(99, 42) // 未知字段（fixed64）也要能跳过
        p.int(20, 97)
        return p.toBytes()
    }

    @Test
    fun crashingThreadIsNamedAndListedEvenWhenItComesLast() {
        val bytes = tombstone(crashTid = 14600)
        assertTrue(bytes.size > 64 * 1024, "fixture must exceed the old 64 KB read cap")
        val s = TombstoneSummary.summarize(bytes, 3400)
        val lines = s.lines()
        assertEquals("signal 6 (SIGABRT), code -1 (SI_QUEUE), fault addr --------", lines[0])
        assertEquals("Abort message: 'FORTIFY: pthread_mutex_lock called on a destroyed mutex (0xb400007b25adc2f0)'", lines[1])
        assertEquals("Cause: fixture cause", lines[2])
        assertEquals("pid=14489 tid=14600 threads=109 uptime=97s", lines[3])
        assertEquals("crashing thread \"DartWorker\" (tid 14600):", lines[4])
        assertEquals("  #00 pc 0005823c  /apex/com.android.runtime/lib64/bionic/libc.so (abort+164) (BuildId: bc5c61ed852b3f4266cdfdd25499ef95)", lines[5])
        assertEquals("  #01 pc 009dfeb0  base.apk (offset 0x8378000) (BuildId: 3042c18dd243797671f94adc831f8ada24daec26)", lines[6])
        assertEquals("main thread \"app.fushi.reader\" (tid 14489):", lines[7])
        assertTrue(lines[8].contains("(pthread_cond_wait+76)"))
        assertFalse(s.contains("hwuiTask"), "unrelated threads must not crowd out the crash")
    }

    @Test
    fun crashOnMainThreadListsItOnce() {
        val s = TombstoneSummary.summarize(tombstone(crashTid = 14489), 3400)
        assertTrue(s.contains("crashing thread \"app.fushi.reader\" (tid 14489):"))
        assertFalse(s.contains("main thread"))
    }

    @Test
    fun outputIsCutOnWholeLines() {
        val s = TombstoneSummary.summarize(tombstone(crashTid = 14600), 200)
        assertTrue(s.length <= 200 + 32)
        assertTrue(s.endsWith("lines cut]"))
    }

    @Test
    fun truncatedProtoIsRejectedNotMisread() {
        val bytes = tombstone(crashTid = 14600)
        assertFailsWith<IllegalArgumentException> {
            TombstoneSummary.summarize(bytes.copyOf(bytes.size - 15), 3400)
        }
    }
}
