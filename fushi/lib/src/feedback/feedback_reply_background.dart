// 反馈回复的**后台**检查（Android WorkManager 周期任务 / iOS BGTaskScheduler app refresh）。
//
// 不需要任何第三方推送账号：系统隔一段时间跑一次检查，有新回复就发本地通知。两端宿主不同：
// - Android：纯原生的 `FeedbackReplyWorker.kt`（`android/app/src/main/kotlin/app/fushi/reader/
//   feedback/`），**不起任何 Flutter 引擎**，由 [AndroidFeedbackReplyScheduler] 经主引擎上的
//   `FeedbackReplyWorkChannel.kt` 排 / 撤。判据与文件格式和本文件 + feedback_reply_state.dart
//   逐条一致（`FeedbackReplyCheck.kt`），改一边要同步另一边。
//   不能再经 workmanager 插件（反馈 yjn-3h8B-7，BUG-4271 记下的遗留结构问题）：它的
//   BackgroundWorker 用 `FlutterEngine(applicationContext)` 建后台引擎并自动注册全部插件，
//   audio_service 一附着就 `connect()`，`AudioService.onCreate` 另起一个跑 `main()` 的主引擎停在
//   无界面 gate 常驻，进程级静态 `audioHandlerInterface` 也被绑到后台引擎、随它销毁。
// - iOS：workmanager 插件（[WorkmanagerFeedbackReplyScheduler]），系统拉起一个无界面 isolate 跑
//   [feedbackReplyBackgroundDispatcher] → [runFeedbackReplyBackgroundTask]。
//   [feedbackReplyBackgroundDispatcher] 在 Android 上也要保留：升级前排下的 workmanager 旧任务
//   在用户首次打开新版本、[AndroidFeedbackReplyScheduler] 把它换成原生 Worker 之前还会跑一次。
//
// 以下说的是 iOS 的后台 isolate。
// 后台 isolate 的边界（与 `asr_host.dart` 的 `AsrIsolateBackend` 同一个教训）：主 isolate
// 的全局装配点**一个都带不过来**——没有 AppModel、没有打开的 Drift、`primeAppProxy` 没跑过、
// slang 没设语言、排行榜账户没加载。所以这里只用：
// - 插件（path_provider 解数据根、flutter_local_notifications 发通知），由
//   `DartPluginRegistrant.ensureInitialized()` 在本 isolate 注册；
// - 主 isolate 事先写进 `poll_state.json` 的运行环境（服务器地址、通知标题文案），见
//   [FeedbackReplyStateStore]；
// - 本机工单回执 tickets.json（只读）。
// 出站照样经 `createAppHttpIoClient()`：环境变量代理照常生效；用户在 app 里手填的代理
// 存在 Drift 里、后台读不到，这一路退回直连（rank.fushi.moe 走 Cloudflare，直连可达）。
//
// 只在主 app 入口注册（main.dart → FeedbackReplyAlerts.syncSchedule）；弹窗词典 / 悬浮
// 词典两个 entry point 不碰它。

import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:fushi/src/feedback/feedback_reply_state.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart'
    show kLeaderboardDefaultBaseUrl;
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/updates/local_update_notifier.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:workmanager/workmanager.dart';

/// 通知标题的兜底（主 isolate 还没写过本地化文案时）。正常路径下主 isolate 每次同步
/// 调度都会把当前语言的 `t.feedback_reply_notification_title` 写进状态文件。
const String _kFallbackAlertTitle = 'Fushi';

/// 一条新回复 → 一条系统通知：标题是固定文案（「开发者回复了你的反馈」），正文是反馈
/// 标题，载荷带反馈 id（点击直达详情），通知 id 按反馈 id 派生（同一条再有回复 = 替换）。
UpdateNotification feedbackReplyNotification(
  FeedbackReplyAlert alert, {
  required String title,
}) => UpdateNotification(
  id: feedbackNotificationId(alert.id),
  title: title,
  body: alert.title,
  payload: encodeFeedbackNotificationPayload(alert.id),
  timestamp: DateTime.fromMillisecondsSinceEpoch(alert.devReplyAt),
  grouped: false,
);

/// 把一批新回复发成系统通知。通知后端不可用 / 系统没授权 → 什么都不发（返回 false），
/// 水位照样已推进：红点与反馈中心照常显示，不会因为发不出通知就反复重试同一条。
Future<bool> postFeedbackReplyNotifications(
  UpdateNotifier notifier,
  List<FeedbackReplyAlert> alerts, {
  required String title,
}) async {
  if (alerts.isEmpty) return false;
  if (!await notifier.ensureReady()) return false;
  if (!await notifier.hasPermission()) return false;
  for (final FeedbackReplyAlert a in alerts) {
    await notifier.notify(feedbackReplyNotification(a, title: title));
  }
  return true;
}

/// 后台任务本体。返回值交给 WorkManager：true = 成功（含「没什么可做」），false = 这轮
/// 失败（网络等），按系统退避再来。
Future<bool> runFeedbackReplyBackgroundTask({
  UpdateNotifier? notifier,
  Future<Directory> Function()? supportRoot,
  LeaderboardClient Function(Uri baseUrl)? client,
  int Function()? nowMs,
}) async {
  try {
    final Directory root =
        await (supportRoot ?? AppPaths.supportRootDirectory)();
    final List<FeedbackReplyAlert> alerts =
        await pollFeedbackRepliesInBackground(
          supportRoot: root,
          client:
              client ??
              (Uri baseUrl) => LeaderboardClient(
                baseUrl: baseUrl,
                httpClientFactory: () async => createAppHttpIoClient(),
              ),
          defaultBaseUrl: Uri.parse(kLeaderboardDefaultBaseUrl),
          nowMs: (nowMs ?? () => DateTime.now().millisecondsSinceEpoch)(),
        );
    if (alerts.isEmpty) return true;
    final String title =
        (await FeedbackReplyStateStore(root).read()).alertTitle ??
        _kFallbackAlertTitle;
    await postFeedbackReplyNotifications(
      notifier ?? LocalUpdateNotifier(appName: 'Fushi'),
      alerts,
      title: title,
    );
    return true;
  } on Object catch (e) {
    // 后台 isolate 里没有 ErrorLogService 的落盘（那是主 isolate 的内存环形缓冲），
    // 只能打到平台日志。
    debugPrint('feedback reply background check failed: $e');
    return false;
  }
}

/// workmanager 插件拉起后台 isolate 时的入口（iOS BGTaskScheduler；以及 Android 上升级前排下、
/// 尚未被 [AndroidFeedbackReplyScheduler] 换掉的旧任务）。必须是顶层函数并保留
/// `vm:entry-point`，否则 release 构建的 tree shaking 会把它裁掉。
@pragma('vm:entry-point')
void feedbackReplyBackgroundDispatcher() {
  Workmanager().executeTask((String task, Map<String, dynamic>? _) async {
    // 注册本 isolate 的 Dart 侧插件实现（path_provider 等）；原生侧插件由宿主引擎注册。
    DartPluginRegistrant.ensureInitialized();
    if (task != kFeedbackReplyTaskName) return true;
    return runFeedbackReplyBackgroundTask();
  });
}

/// 后台检查的排程（主 isolate 用）。关掉开关 / 没有未结案反馈时 [cancel]，否则
/// [schedule]——「关时不注册后台任务」。
abstract class FeedbackReplyBackgroundScheduler {
  /// 这个平台有没有系统级后台检查（Android / iOS 有；桌面靠运行中的定时器）。
  bool get supported;

  Future<void> schedule();

  Future<void> cancel();
}

/// 没有系统后台任务的平台（桌面、测试）。
class NoopFeedbackReplyScheduler implements FeedbackReplyBackgroundScheduler {
  const NoopFeedbackReplyScheduler();

  @override
  bool get supported => false;

  @override
  Future<void> schedule() async {}

  @override
  Future<void> cancel() async {}
}

/// Android：纯原生的 `FeedbackReplyWorker`（不起 Flutter 引擎），经主引擎上的
/// `app.fushi.reader/feedback_reply_work` 排程。唯一任务名、周期、数据根与默认服务器都由这边
/// 传过去，原生侧不另存一份；遇到旧版 workmanager 插件排下的同名任务，原生侧把它换成原生
/// Worker（`FeedbackReplyWorkPolicy`）。
class AndroidFeedbackReplyScheduler
    implements FeedbackReplyBackgroundScheduler {
  AndroidFeedbackReplyScheduler({
    MethodChannel? channel,
    Future<Directory> Function()? supportRoot,
  }) : _channel = channel ?? FushiChannels.feedbackReplyWork,
       _supportRoot = supportRoot ?? AppPaths.supportRootDirectory;

  final MethodChannel _channel;
  final Future<Directory> Function() _supportRoot;

  @override
  bool get supported => true;

  @override
  Future<void> schedule() async {
    final Directory root = await _supportRoot();
    await _channel.invokeMethod<void>('schedule', <String, Object>{
      'uniqueName': kFeedbackReplyTaskName,
      'intervalMinutes': kFeedbackReplyPollInterval.inMinutes,
      'supportRoot': root.path,
      'defaultServer': kLeaderboardDefaultBaseUrl,
    });
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>(
    'cancel',
    <String, Object>{'uniqueName': kFeedbackReplyTaskName},
  );
}

/// iOS：workmanager 插件（BGTaskScheduler）。
class WorkmanagerFeedbackReplyScheduler
    implements FeedbackReplyBackgroundScheduler {
  WorkmanagerFeedbackReplyScheduler({Workmanager? workmanager})
    : _wm = workmanager ?? Workmanager();

  final Workmanager _wm;
  Future<void>? _initialised;

  @override
  bool get supported => true;

  Future<void> _ensureInitialised() =>
      _initialised ??= _wm.initialize(feedbackReplyBackgroundDispatcher);

  @override
  Future<void> schedule() async {
    await _ensureInitialised();
    await _wm.registerPeriodicTask(
      kFeedbackReplyTaskName,
      kFeedbackReplyTaskName,
      frequency: kFeedbackReplyPollInterval,
      constraints: Constraints(networkType: NetworkType.connected),
      // update：已排着就保留原节奏，只换参数；不会每次启动都把周期重置。
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  @override
  Future<void> cancel() async {
    await _ensureInitialised();
    await _wm.cancelByUniqueName(kFeedbackReplyTaskName);
  }
}

/// 生产装配：Android 用纯原生 Worker，iOS 用 workmanager，其余平台没有系统后台检查。
FeedbackReplyBackgroundScheduler createFeedbackReplyBackgroundScheduler() {
  if (Platform.isAndroid) return AndroidFeedbackReplyScheduler();
  if (Platform.isIOS) return WorkmanagerFeedbackReplyScheduler();
  return const NoopFeedbackReplyScheduler();
}
