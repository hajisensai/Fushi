package app.fushi.reader.feedback

import java.io.File
import java.io.IOException
import kotlin.random.Random
import org.json.JSONObject

/**
 * `<supportRoot>/feedback/poll_state.json` 的读改写，与 Dart `FeedbackReplyStateStore` 用**同一把
 * 锁**：同目录的 `poll_state.json.lock`，以「独占创建」取得（Dart `File.create(exclusive: true)`
 * = O_EXCL；这边 [File.createNewFile] 同样是原子的独占创建），做完删除；锁文件比
 * [STALE_LOCK_MS] 更旧说明持锁方在临界区里被杀了，收走重抢。写走「临时文件 + rename」，
 * 读到的永远是某一份完整内容。
 *
 * 主 isolate（前台检查 / 排程时写 serverUrl、alertTitle）与本 Worker 同进程并发改这个文件，
 * 谁都只改自己负责的字段——[update] 的 [change] 拿锁内现读的最新内容。
 */
class FeedbackReplyStateFile(supportRoot: File) {
    val file: File = File(File(supportRoot, "feedback"), "poll_state.json")
    val lockFile: File = File(file.path + ".lock")

    /** 不存在 / 损坏按空状态。 */
    fun read(): JSONObject =
        FeedbackReplyCheck.parseState(if (file.exists()) file.readText(Charsets.UTF_8) else null)

    /** 锁内读改写，返回 [change] 的附带结果。 */
    fun <T> update(change: (JSONObject) -> Pair<JSONObject, T>): T {
        file.parentFile?.mkdirs()
        acquire()
        try {
            val (next, extra) = change(read())
            val tmp = File(file.path + "." + Random.nextLong().toULong().toString(16) + ".tmp")
            tmp.writeText(next.toString(), Charsets.UTF_8)
            if (!tmp.renameTo(file)) {
                tmp.delete()
                throw IOException("rename ${tmp.path} -> ${file.path} failed")
            }
            return extra
        } finally {
            release()
        }
    }

    private fun acquire() {
        while (true) {
            if (lockFile.createNewFile()) return
            if (isStale()) {
                release()
                continue
            }
            Thread.sleep(LOCK_POLL_MS)
        }
    }

    private fun isStale(): Boolean {
        val modified: Long = lockFile.lastModified()
        // 0 = 刚被持有者删掉：下一轮直接再抢。
        return modified != 0L && System.currentTimeMillis() - modified > STALE_LOCK_MS
    }

    private fun release() {
        lockFile.delete()
    }

    companion object {
        /** 与 Dart `FeedbackReplyStateStore.staleLockAge` 一致。 */
        const val STALE_LOCK_MS: Long = 10_000L

        /** 与 Dart `FeedbackReplyStateStore._lockPoll` 一致。 */
        const val LOCK_POLL_MS: Long = 15L
    }
}
