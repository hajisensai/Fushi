package app.fushi.reader.feedback

import android.content.Context
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import app.fushi.reader.constants.ChannelNames
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

/**
 * 反馈回复后台检查的排 / 撤（主引擎上；Dart 门面 `AndroidFeedbackReplyScheduler`，
 * `fushi/lib/src/feedback/feedback_reply_background.dart`）。
 *
 * 排的是纯原生的 [FeedbackReplyWorker]，不再经 workmanager 插件（反馈 yjn-3h8B-7）。唯一任务名、
 * 周期、数据根、默认服务器都由 Dart 传入（任务名 `kFeedbackReplyTaskName` 发布后冻结），
 * 这边不另存一份。
 */
object FeedbackReplyWorkChannel {
    @JvmStatic
    fun registerWith(engine: FlutterEngine, appContext: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, ChannelNames.FEEDBACK_REPLY_WORK)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "schedule" -> schedule(appContext, call, result)
                    "cancel" -> {
                        val name: String? = call.argument("uniqueName")
                        if (name == null) {
                            result.error("bad_args", "cancel needs uniqueName", null)
                        } else {
                            WorkManager.getInstance(appContext).cancelUniqueWork(name)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun schedule(appContext: Context, call: MethodCall, result: MethodChannel.Result) {
        val name: String? = call.argument("uniqueName")
        val minutes: Int? = call.argument("intervalMinutes")
        val supportRoot: String? = call.argument("supportRoot")
        val defaultServer: String? = call.argument("defaultServer")
        if (name == null || minutes == null || supportRoot == null || defaultServer == null) {
            result.error(
                "bad_args",
                "schedule needs uniqueName, intervalMinutes, supportRoot and defaultServer",
                null,
            )
            return
        }
        val wm = WorkManager.getInstance(appContext)
        val existing = wm.getWorkInfosForUniqueWork(name)
        existing.addListener({
            val tags: Set<String> = try {
                existing.get().flatMapTo(HashSet()) { info: WorkInfo -> info.tags }
            } catch (e: Exception) {
                result.error("query_failed", e.toString(), null)
                return@addListener
            }
            val request = PeriodicWorkRequestBuilder<FeedbackReplyWorker>(
                minutes.toLong(),
                TimeUnit.MINUTES,
            )
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
                )
                .setInputData(
                    workDataOf(
                        FeedbackReplyWorker.KEY_SUPPORT_ROOT to supportRoot,
                        FeedbackReplyWorker.KEY_DEFAULT_SERVER to defaultServer,
                    ),
                )
                .build()
            wm.enqueueUniquePeriodicWork(name, FeedbackReplyWorkPolicy.policyFor(tags), request)
            result.success(null)
        }, ContextCompat.getMainExecutor(appContext))
    }
}

/**
 * 入队时对已存在的同名任务用哪种策略。
 *
 * 旧版本由 workmanager_android 的 `BackgroundWorker` 排着同名唯一任务；WorkManager 的 `UPDATE`
 * 不允许换 Worker 类（抛 IllegalArgumentException），所以遇到别的 Worker 类的任务必须
 * `CANCEL_AND_REENQUEUE` 换成 [FeedbackReplyWorker]；已经是自家 Worker 时用 `UPDATE`，保留原有
 * 节奏（不会每次启动都把周期重置），只换 inputData。判据是 WorkManager 自动给每个请求加的
 * Worker 类全名 tag。
 */
object FeedbackReplyWorkPolicy {
    /** workmanager_android 的 Worker 类全名（旧任务自动带的 tag）。 */
    const val LEGACY_WORKER_TAG: String = "dev.fluttercommunity.workmanager.BackgroundWorker"

    fun policyFor(existingTags: Set<String>): ExistingPeriodicWorkPolicy =
        if (existingTags.contains(LEGACY_WORKER_TAG)) {
            ExistingPeriodicWorkPolicy.CANCEL_AND_REENQUEUE
        } else {
            ExistingPeriodicWorkPolicy.UPDATE
        }
}
