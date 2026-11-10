package app.fushi.reader.feedback

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * 反馈回复后台检查的纯逻辑（无 Android 依赖，JVM 单测直接测）。
 *
 * 这是 Dart `fushi/lib/src/feedback/feedback_reply_state.dart` 里
 * `pollFeedbackRepliesInBackground` 的原生实现：Android 的周期检查改由
 * [FeedbackReplyWorker]（纯 Kotlin，不起 Flutter 引擎）执行（反馈 yjn-3h8B-7 / BUG-4271
 * 遗留：workmanager 插件的 BackgroundWorker 起的后台引擎会自动注册全部插件，audio_service
 * 附着时另起一个跑 `main()` 的主引擎常驻）。
 *
 * 读写的是与 Dart 共用的两个文件（`<supportRoot>/feedback/` 下），格式以 Dart 为准：
 * - `tickets.json`：本机回执清单 `{items: [{id, ticket, status, seenAt, missing, ...}]}`，**只读**；
 * - `poll_state.json`：提醒水位与主 isolate 写下的运行环境（serverUrl / alertTitle），只改
 *   `notified` 一个字段，其余字段原样保留。
 * 判据与 Dart 逐条一致；改任何一边都要同步另一边（`feedback_reply_background_test.dart`
 * 里有核对两边常量的守卫）。
 */
object FeedbackReplyCheck {
    /** 与 Dart `kFeedbackReplyPollInterval` 一致：主 isolate 刚刷新过就不查。 */
    const val POLL_INTERVAL_MS: Long = 15L * 60L * 1000L

    /** 与 Dart `FeedbackLimits.statusBatch` 一致：一次状态请求最多带的条数。 */
    const val STATUS_BATCH: Int = 50

    /** 与 Dart `encodeFeedbackNotificationPayload` 的前缀一致。 */
    const val PAYLOAD_PREFIX: String = "fushi-feedback:"

    /** 状态请求的路径（Dart `LeaderboardClient.feedbackStatuses`）。 */
    const val STATUS_PATH: String = "/v1/feedback/status"

    /** 已结案状态的 wire 值（Dart `FeedbackStatus.isClosed`；未知值按 open 处理）。 */
    private val CLOSED_STATUSES: Set<String> = setOf("resolved", "wont_fix", "duplicate", "closed")

    /** 后台能查的一条本机回执。 */
    data class Ticket(val id: String, val ticket: String, val seenAt: Long)

    /** 一条需要提醒的新回复。 */
    data class Alert(val id: String, val title: String, val devReplyAt: Long)

    /** 在锁内挑选的结果：要写回的状态，和要发通知的条目（已去掉远程推送覆盖的）。 */
    data class Selection(val nextState: JSONObject, val toNotify: List<Alert>)

    /**
     * 从 tickets.json 原文里挑出后台查得了的未结案回执（Dart `feedbackBackgroundPollable`：
     * 有 ticket、非结案、服务端没标 missing）。原文坏了返回空——修复 / 留档是主 isolate 的事，
     * 后台绝不写 tickets.json。
     */
    fun pollableTickets(ticketsJson: String?): List<Ticket> {
        if (ticketsJson == null) return emptyList()
        val items: JSONArray = try {
            JSONObject(ticketsJson).optJSONArray("items") ?: return emptyList()
        } catch (e: JSONException) {
            return emptyList()
        }
        val out = ArrayList<Ticket>()
        for (i in 0 until items.length()) {
            val o: JSONObject = items.optJSONObject(i) ?: continue
            val id: String = o.optString("id", "")
            val ticket: String = o.optString("ticket", "")
            if (id.isEmpty() || ticket.isEmpty()) continue
            if (CLOSED_STATUSES.contains(o.optString("status", "open"))) continue
            if (o.optBoolean("missing", false)) continue
            out.add(Ticket(id = id, ticket = ticket, seenAt = o.optLong("seenAt", 0L)))
        }
        return out
    }

    /** 读 poll_state.json 原文；不存在 / 损坏按空状态（与 Dart `FeedbackReplyStateStore.read` 同）。 */
    fun parseState(stateJson: String?): JSONObject {
        if (stateJson == null) return JSONObject()
        return try {
            JSONObject(stateJson)
        } catch (e: JSONException) {
            JSONObject()
        }
    }

    /** 主 isolate [POLL_INTERVAL_MS] 内刚成功刷新过（时钟回拨的未来时刻不算）。 */
    fun recentlyRefreshed(state: JSONObject, nowMs: Long): Boolean {
        val last: Long = state.optLong("lastRefreshAt", 0L)
        return last <= nowMs && nowMs - last < POLL_INTERVAL_MS
    }

    /** 主 isolate 写下的服务器；没写过用 [defaultServer]。 */
    fun serverUrl(state: JSONObject, defaultServer: String): String {
        val s: String? = optStringOrNull(state, "serverUrl")
        return if (s.isNullOrEmpty()) defaultServer else s
    }

    /** 通知标题（主 isolate 写下的本地化文案），没有就用 [fallback]。 */
    fun alertTitle(state: JSONObject, fallback: String): String {
        val s: String? = optStringOrNull(state, "alertTitle")
        return if (s.isNullOrEmpty()) fallback else s
    }

    /** 与 Dart `LeaderboardClient._join` 一致：去掉 base 末尾的 `/` 再接路径。 */
    fun statusEndpoint(server: String): String = server.trimEnd('/') + STATUS_PATH

    /** 一批状态请求的 body（`{items: [{id, ticket}]}`）。 */
    fun statusRequestBody(batch: List<Ticket>): String {
        val items = JSONArray()
        for (t in batch) items.put(JSONObject().put("id", t.id).put("ticket", t.ticket))
        return JSONObject().put("items", items).toString()
    }

    /**
     * 状态响应里带开发者回复时刻的条目（Dart `FeedbackSummary.fromJson` 的 id / title /
     * devReplyAt）。响应不是预期形状时抛 [JSONException]（Dart 侧同样当失败处理）。
     */
    fun parseStatusResponse(body: String): List<Alert> {
        val items: JSONArray = JSONObject(body).optJSONArray("items") ?: return emptyList()
        val out = ArrayList<Alert>()
        for (i in 0 until items.length()) {
            val o: JSONObject = items.getJSONObject(i)
            if (!o.has("devReplyAt") || o.isNull("devReplyAt")) continue
            out.add(
                Alert(
                    id = o.getString("id"),
                    title = optStringOrNull(o, "title") ?: "",
                    devReplyAt = o.getLong("devReplyAt"),
                ),
            )
        }
        return out
    }

    /**
     * 在锁内用**最新**状态挑选（Dart `selectNewReplies` + `withNotified` + `withoutPushCovered`）：
     * 比用户看过的新、且比该条已提醒水位新的回复推进水位；通知只发没被远程推送覆盖的。
     * 返回的 [Selection.nextState] 是 [latest] 的副本，只改了 `notified`。
     */
    fun select(candidates: List<Alert>, tickets: List<Ticket>, latest: JSONObject): Selection {
        val seenAt: Map<String, Long> = tickets.associate { it.id to it.seenAt }
        val legacy: Long = latest.optLong("notifiedReplyAt", 0L)
        val notified: JSONObject = latest.optJSONObject("notified") ?: JSONObject()
        fun notifiedAt(id: String): Long =
            if (notified.has(id) && !notified.isNull(id)) notified.optLong(id, legacy) else legacy

        val fresh: List<Alert> = candidates.filter {
            it.devReplyAt > (seenAt[it.id] ?: 0L) && it.devReplyAt > notifiedAt(it.id)
        }
        val next = JSONObject(latest.toString())
        if (fresh.isNotEmpty()) {
            val nextNotified = JSONObject(notified.toString())
            for (a in fresh) nextNotified.put(a.id, maxOf(a.devReplyAt, notifiedAt(a.id)))
            next.put("notified", nextNotified)
        }
        val covered: Set<String> = pushCovered(latest)
        return Selection(nextState = next, toNotify = fresh.filterNot { covered.contains(it.id) })
    }

    /**
     * 由服务端远程推送提醒的反馈（Dart `FeedbackReplyState.pushCovered`，含旧版
     * `pushRegistered` + `pushDelivering` 的迁移读法）。没有 pushToken 就是空。
     */
    fun pushCovered(state: JSONObject): Set<String> {
        if (optStringOrNull(state, "pushToken") == null) return emptySet()
        val regs: JSONObject? = state.optJSONObject("pushRegistrations")
        if (regs != null) {
            val out = HashSet<String>()
            for (key in regs.keys()) {
                val r: JSONObject = regs.optJSONObject(key) ?: continue
                if (r.optBoolean("delivering", false)) out.add(key)
            }
            return out
        }
        if (!state.optBoolean("pushDelivering", false)) return emptySet()
        val legacy: JSONArray = state.optJSONArray("pushRegistered") ?: return emptySet()
        val out = HashSet<String>()
        for (i in 0 until legacy.length()) {
            val id: Any? = legacy.opt(i)
            if (id is String) out.add(id)
        }
        return out
    }

    /** 与 Dart `encodeFeedbackNotificationPayload` 一致。 */
    fun notificationPayload(feedbackId: String): String = PAYLOAD_PREFIX + feedbackId

    /**
     * 与 Dart `feedbackNotificationId` 一致：按 UTF-16 码元 `h = (h * 31 + c) & 0x3fffffff`，
     * 再落到 2^30 以上的区间（同一条反馈再有回复 = 替换同一条通知）。
     */
    fun notificationId(feedbackId: String): Int {
        var h = 0L
        for (c in feedbackId) h = (h * 31L + c.code.toLong()) and 0x3fffffffL
        return (0x40000000L or h).toInt()
    }

    private fun optStringOrNull(o: JSONObject, key: String): String? =
        if (o.has(key) && !o.isNull(key)) o.optString(key) else null
}
