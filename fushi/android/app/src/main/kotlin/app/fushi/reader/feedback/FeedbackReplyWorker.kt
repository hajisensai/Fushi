package app.fushi.reader.feedback

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import app.fushi.reader.R
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Android 上「反馈有新回复」的周期后台检查（反馈 yjn-3h8B-7；BUG-4271 记下的遗留结构问题）。
 *
 * **不起任何 Flutter 引擎**：旧实现经 workmanager 插件，它的 BackgroundWorker 用
 * `FlutterEngine(applicationContext)` 建后台引擎并自动注册全部插件，audio_service 的
 * `onAttachedToEngine` 在冷进程里 `connect()` → `AudioService.onCreate` 新建主引擎跑 `main()`
 * 停在无界面 gate 常驻，进程级静态 `audioHandlerInterface` 也被绑到后台引擎、随它销毁。
 * 检查本身只是「读两个 JSON → 一次 HTTP POST → 改水位 → 发通知」，这里用原生直接做，
 * 判据与文件格式见 [FeedbackReplyCheck]。
 *
 * 运行环境由主 isolate 经 [FeedbackReplyWorkChannel] 排程时放进 inputData：数据根
 * （[KEY_SUPPORT_ROOT]，Dart `AppPaths.supportRootDirectory()`）与默认服务器
 * （[KEY_DEFAULT_SERVER]，Dart `kLeaderboardDefaultBaseUrl`）；主 isolate 写进 poll_state.json
 * 的 serverUrl / alertTitle 优先。
 *
 * 点通知：PendingIntent 按 flutter_local_notifications 的点击契约构造（action
 * `SELECT_NOTIFICATION` + extras `notificationId` / `payload`，打开启动 Activity），所以点击照常
 * 走 Dart `LocalUpdateNotifier` 的回调 / 冷启动 launch details，进反馈详情——与 Dart 发的
 * 通知完全同一条路。契约常量由 `feedback_reply_background_test.dart` 对照解析到的插件源码钉住。
 */
class FeedbackReplyWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val supportRoot: String = inputData.getString(KEY_SUPPORT_ROOT)
            ?: return@withContext Result.failure()
        val defaultServer: String = inputData.getString(KEY_DEFAULT_SERVER)
            ?: return@withContext Result.failure()
        try {
            val alerts = poll(File(supportRoot), defaultServer, System.currentTimeMillis())
            if (alerts.alerts.isNotEmpty()) post(alerts.title, alerts.alerts)
            Result.success()
        } catch (e: IOException) {
            // 网络 / 服务端错误：这轮记失败，按 WorkManager 退避再来（与旧 Dart 实现返回 false 同义）。
            Log.w(TAG, "feedback reply background check failed", e)
            Result.retry()
        }
    }

    private data class Polled(val title: String, val alerts: List<FeedbackReplyCheck.Alert>)

    /** Dart `pollFeedbackRepliesInBackground` 的同一流程。 */
    private fun poll(supportRoot: File, defaultServer: String, nowMs: Long): Polled {
        val ticketsFile = File(File(supportRoot, "feedback"), "tickets.json")
        val active = FeedbackReplyCheck.pollableTickets(
            if (ticketsFile.exists()) ticketsFile.readText(Charsets.UTF_8) else null,
        )
        if (active.isEmpty()) return Polled(FALLBACK_TITLE, emptyList())

        val store = FeedbackReplyStateFile(supportRoot)
        val state = store.read()
        if (FeedbackReplyCheck.recentlyRefreshed(state, nowMs)) {
            return Polled(FALLBACK_TITLE, emptyList())
        }

        val endpoint = FeedbackReplyCheck.statusEndpoint(
            FeedbackReplyCheck.serverUrl(state, defaultServer),
        )
        val candidates = ArrayList<FeedbackReplyCheck.Alert>()
        for (batch in active.chunked(FeedbackReplyCheck.STATUS_BATCH)) {
            candidates.addAll(fetchStatuses(endpoint, batch))
        }
        if (candidates.isEmpty()) return Polled(FALLBACK_TITLE, emptyList())

        // 水位在锁内按最新状态推进：联网那几秒里主 isolate 改过的字段 / 提醒过的条目都不会被覆盖。
        return store.update { latest ->
            val sel = FeedbackReplyCheck.select(candidates, active, latest)
            sel.nextState to Polled(
                FeedbackReplyCheck.alertTitle(latest, FALLBACK_TITLE),
                sel.toNotify,
            )
        }
    }

    private fun fetchStatuses(
        endpoint: String,
        batch: List<FeedbackReplyCheck.Ticket>,
    ): List<FeedbackReplyCheck.Alert> {
        val request = Request.Builder()
            .url(endpoint)
            .header("Accept", "application/json")
            .post(FeedbackReplyCheck.statusRequestBody(batch).toRequestBody(JSON))
            .build()
        http.newCall(request).execute().use { res ->
            if (!res.isSuccessful) throw IOException("feedback status HTTP ${res.code}")
            val body: String = res.body.string()
            return try {
                FeedbackReplyCheck.parseStatusResponse(body)
            } catch (e: org.json.JSONException) {
                // 与 Dart `_sendJson` 的 bad_response 同义：这轮失败。
                throw IOException("feedback status bad_response", e)
            }
        }
    }

    /**
     * 发系统通知。没授权 / 通知被关 → 什么都不发（水位照样已推进：红点与反馈中心照常显示，
     * 不会因为发不出通知就反复重试同一条），与 Dart `postFeedbackReplyNotifications` 同。
     */
    private fun post(title: String, alerts: List<FeedbackReplyCheck.Alert>) {
        val ctx: Context = applicationContext
        val nm = NotificationManagerCompat.from(ctx)
        if (!nm.areNotificationsEnabled()) return
        ensureChannel(ctx)
        val launch: Intent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: return
        for (a in alerts) {
            val id: Int = FeedbackReplyCheck.notificationId(a.id)
            val intent = Intent(launch)
                .setAction(FLN_SELECT_NOTIFICATION)
                .putExtra(FLN_NOTIFICATION_ID, id)
                .putExtra(FLN_PAYLOAD, FeedbackReplyCheck.notificationPayload(a.id))
            val pending = PendingIntent.getActivity(
                ctx,
                id,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val n = NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_fushi)
                .setContentTitle(title)
                .setContentText(a.title)
                .setWhen(a.devReplyAt)
                .setShowWhen(true)
                .setAutoCancel(true)
                .setContentIntent(pending)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            try {
                nm.notify(id, n)
            } catch (e: SecurityException) {
                // areNotificationsEnabled 与 POST_NOTIFICATIONS 授权之间的竞态（用户刚在设置里撤销）。
                Log.w(TAG, "notification permission revoked mid-run", e)
                return
            }
        }
    }

    /**
     * 与 Dart `LocalUpdateNotifier` 同一个渠道（`kUpdateNotificationChannelId`）。插件已建过就
     * 原样沿用；没建过按插件的同一组参数建（默认重要性、不响铃不震动）。
     */
    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT)
        ch.setSound(null, null)
        ch.enableVibration(false)
        nm.createNotificationChannel(ch)
    }

    companion object {
        private const val TAG = "FeedbackReplyWorker"

        const val KEY_SUPPORT_ROOT = "supportRoot"
        const val KEY_DEFAULT_SERVER = "defaultServer"

        /** 主 isolate 还没写过本地化标题时的兜底（Dart `_kFallbackAlertTitle`）。 */
        private const val FALLBACK_TITLE = "Fushi"

        /** Dart `kUpdateNotificationChannelId`；渠道名 = 插件建渠道时用的 appName。 */
        const val CHANNEL_ID = "fushi_updates"
        private const val CHANNEL_NAME = "Fushi"

        /** flutter_local_notifications 的点击契约（`FlutterLocalNotificationsPlugin.java`）。 */
        const val FLN_SELECT_NOTIFICATION = "SELECT_NOTIFICATION"
        const val FLN_NOTIFICATION_ID = "notificationId"
        const val FLN_PAYLOAD = "payload"

        private val JSON = "application/json".toMediaType()

        private val http: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .callTimeout(60, TimeUnit.SECONDS)
                .build()
        }
    }
}
