package app.fushi.reader.feedback

import androidx.work.ExistingPeriodicWorkPolicy
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.json.JSONObject

/**
 * 反馈 yjn-3h8B-7：Android 反馈回复后台检查改为纯原生 Worker 之后，判据必须与 Dart
 * `pollFeedbackRepliesInBackground`（feedback_reply_state.dart）逐条一致，文件锁与 Dart
 * `FeedbackReplyStateStore` 互通。
 */
class FeedbackReplyCheckTest {
    private fun tickets(vararg items: String): String = """{"items":[${items.joinToString(",")}]}"""

    @Test
    fun pollableTicketsSkipsClosedMissingAndAccountEntries() {
        val json = tickets(
            """{"id":"open1","ticket":"t1","status":"open","seenAt":7}""",
            """{"id":"prog","ticket":"t2","status":"in_progress"}""",
            """{"id":"unknown","ticket":"t3","status":"something_new"}""",
            """{"id":"done","ticket":"t4","status":"resolved"}""",
            """{"id":"wont","ticket":"t5","status":"wont_fix"}""",
            """{"id":"dup","ticket":"t6","status":"duplicate"}""",
            """{"id":"closed","ticket":"t7","status":"closed"}""",
            """{"id":"gone","ticket":"t8","status":"open","missing":true}""",
            """{"id":"acct","ticket":"","status":"open"}""",
        )
        assertEquals(
            listOf(
                FeedbackReplyCheck.Ticket("open1", "t1", 7L),
                FeedbackReplyCheck.Ticket("prog", "t2", 0L),
                // 未知状态与 Dart FeedbackStatus.fromWire 一样按 open 处理。
                FeedbackReplyCheck.Ticket("unknown", "t3", 0L),
            ),
            FeedbackReplyCheck.pollableTickets(json),
        )
    }

    @Test
    fun corruptOrMissingTicketsMeanNothingToPoll() {
        assertEquals(emptyList(), FeedbackReplyCheck.pollableTickets(null))
        assertEquals(emptyList(), FeedbackReplyCheck.pollableTickets("{not json"))
        assertEquals(emptyList(), FeedbackReplyCheck.pollableTickets("""{"other":1}"""))
    }

    @Test
    fun recentlyRefreshedWithinFifteenMinutesOnly() {
        val now = 100_000_000L
        val minute = 60_000L
        fun state(at: Long) = JSONObject().put("lastRefreshAt", at)
        assertTrue(FeedbackReplyCheck.recentlyRefreshed(state(now - 5 * minute), now))
        assertFalse(FeedbackReplyCheck.recentlyRefreshed(state(now - 15 * minute), now))
        // 时钟回拨留下的未来时刻不算「刚刷新过」。
        assertFalse(FeedbackReplyCheck.recentlyRefreshed(state(now + minute), now))
        assertFalse(FeedbackReplyCheck.recentlyRefreshed(JSONObject(), now))
    }

    @Test
    fun serverAndTitleFallBackWhenMainIsolateNeverWroteThem() {
        val empty = JSONObject()
        assertEquals("https://rank.fushi.moe", FeedbackReplyCheck.serverUrl(empty, "https://rank.fushi.moe"))
        assertEquals("Fushi", FeedbackReplyCheck.alertTitle(empty, "Fushi"))
        val written = JSONObject().put("serverUrl", "https://self.host/api/").put("alertTitle", "开发者回复了你的反馈")
        assertEquals("https://self.host/api/", FeedbackReplyCheck.serverUrl(written, "x"))
        assertEquals("开发者回复了你的反馈", FeedbackReplyCheck.alertTitle(written, "Fushi"))
        // 与 Dart LeaderboardClient._join 一致：base 末尾的 / 去掉再接路径。
        assertEquals(
            "https://self.host/api/v1/feedback/status",
            FeedbackReplyCheck.statusEndpoint("https://self.host/api/"),
        )
    }

    @Test
    fun statusRequestAndResponseMatchTheServerContract() {
        val body = JSONObject(
            FeedbackReplyCheck.statusRequestBody(listOf(FeedbackReplyCheck.Ticket("a", "ta", 0L))),
        )
        val item = body.getJSONArray("items").getJSONObject(0)
        assertEquals("a", item.getString("id"))
        assertEquals("ta", item.getString("ticket"))

        val alerts = FeedbackReplyCheck.parseStatusResponse(
            """{"items":[
                {"id":"a","title":"标题","devReplyAt":500,"status":"open"},
                {"id":"b","title":"no reply","devReplyAt":null},
                {"id":"c","title":"absent"}
            ]}""",
        )
        assertEquals(listOf(FeedbackReplyCheck.Alert("a", "标题", 500L)), alerts)
    }

    @Test
    fun selectNotifiesOnlyUnseenAndNotYetNotifiedRepliesAndKeepsOtherFields() {
        val active = listOf(
            FeedbackReplyCheck.Ticket("seen", "t", 900L),
            FeedbackReplyCheck.Ticket("old", "t", 0L),
            FeedbackReplyCheck.Ticket("fresh", "t", 0L),
            FeedbackReplyCheck.Ticket("legacy", "t", 0L),
        )
        val latest = JSONObject()
            .put("lastRefreshAt", 1L)
            .put("serverUrl", "https://s")
            .put("alertTitle", "T")
            .put("permissionAsked", true)
            .put("notifiedReplyAt", 300L)
            .put("notified", JSONObject().put("old", 800L))
        val sel = FeedbackReplyCheck.select(
            listOf(
                FeedbackReplyCheck.Alert("seen", "s", 900L), // 用户看过（seenAt ≥ devReplyAt）
                FeedbackReplyCheck.Alert("old", "o", 800L), // 该条已提醒到 800
                FeedbackReplyCheck.Alert("fresh", "f", 1000L),
                FeedbackReplyCheck.Alert("legacy", "l", 200L), // 不晚于旧版全局水位 300
            ),
            active,
            latest,
        )
        assertEquals(listOf(FeedbackReplyCheck.Alert("fresh", "f", 1000L)), sel.toNotify)
        val next = sel.nextState
        assertEquals(1000L, next.getJSONObject("notified").getLong("fresh"))
        assertEquals(800L, next.getJSONObject("notified").getLong("old"))
        // 其余字段原样保留（主 isolate 负责的字段后台不碰）。
        assertEquals("https://s", next.getString("serverUrl"))
        assertEquals("T", next.getString("alertTitle"))
        assertTrue(next.getBoolean("permissionAsked"))
        assertEquals(300L, next.getLong("notifiedReplyAt"))
        assertEquals(1L, next.getLong("lastRefreshAt"))
    }

    @Test
    fun pushCoveredRepliesAdvanceWatermarkButAreNotNotified() {
        val active = listOf(FeedbackReplyCheck.Ticket("p", "t", 0L), FeedbackReplyCheck.Ticket("q", "t", 0L))
        val latest = JSONObject()
            .put("pushToken", "abcd")
            .put(
                "pushRegistrations",
                JSONObject()
                    .put("p", JSONObject().put("delivering", true).put("at", 1L))
                    .put("q", JSONObject().put("delivering", false).put("at", 1L)),
            )
        val sel = FeedbackReplyCheck.select(
            listOf(FeedbackReplyCheck.Alert("p", "P", 10L), FeedbackReplyCheck.Alert("q", "Q", 10L)),
            active,
            latest,
        )
        assertEquals(listOf(FeedbackReplyCheck.Alert("q", "Q", 10L)), sel.toNotify)
        assertEquals(10L, sel.nextState.getJSONObject("notified").getLong("p"))
        assertEquals(10L, sel.nextState.getJSONObject("notified").getLong("q"))
    }

    @Test
    fun pushCoveredReadsLegacyFormatAndNeedsToken() {
        val legacy = JSONObject()
            .put("pushToken", "abcd")
            .put("pushDelivering", true)
            .put("pushRegistered", org.json.JSONArray().put("x"))
        assertEquals(setOf("x"), FeedbackReplyCheck.pushCovered(legacy))
        legacy.remove("pushToken")
        assertEquals(emptySet(), FeedbackReplyCheck.pushCovered(legacy))
    }

    @Test
    fun notificationIdAndPayloadMatchDart() {
        // 与 Dart feedbackNotificationId('yjn-3h8B-7') / ('aaaaaaaaaa') 的值相同
        // （feedback_reply_background_test.dart 钉着同两个数）。
        assertEquals(1730234009, FeedbackReplyCheck.notificationId("yjn-3h8B-7"))
        assertEquals(1348136096, FeedbackReplyCheck.notificationId("aaaaaaaaaa"))
        assertEquals("fushi-feedback:abc", FeedbackReplyCheck.notificationPayload("abc"))
    }

    @Test
    fun stateFileCollectsStaleLockAndReleasesItsOwn() {
        val root: File = Files.createTempDirectory("fb-reply").toFile()
        try {
            val store = FeedbackReplyStateFile(root)
            store.file.parentFile!!.mkdirs()
            // 持锁方在临界区里被杀留下的过期锁。
            store.lockFile.writeText("")
            assertTrue(store.lockFile.setLastModified(System.currentTimeMillis() - 60_000L))
            val got: String = store.update { cur -> cur.put("notified", JSONObject().put("a", 5L)) to "done" }
            assertEquals("done", got)
            assertFalse(store.lockFile.exists())
            assertEquals(5L, store.read().getJSONObject("notified").getLong("a"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun legacyPluginWorkerIsReplacedOwnWorkerKeepsCadence() {
        assertEquals(
            ExistingPeriodicWorkPolicy.CANCEL_AND_REENQUEUE,
            FeedbackReplyWorkPolicy.policyFor(setOf(FeedbackReplyWorkPolicy.LEGACY_WORKER_TAG)),
        )
        assertEquals(
            ExistingPeriodicWorkPolicy.UPDATE,
            FeedbackReplyWorkPolicy.policyFor(setOf(FeedbackReplyWorker::class.java.name)),
        )
        assertEquals(ExistingPeriodicWorkPolicy.UPDATE, FeedbackReplyWorkPolicy.policyFor(emptySet()))
        // WorkRequest 自动带 Worker 类全名作 tag：常量必须与插件里真实的类名一致。
        assertEquals(
            dev.fluttercommunity.workmanager.BackgroundWorker::class.java.name,
            FeedbackReplyWorkPolicy.LEGACY_WORKER_TAG,
        )
    }
}
