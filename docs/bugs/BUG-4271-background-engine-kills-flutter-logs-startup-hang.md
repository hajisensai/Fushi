## BUG-4271 · 后台被 WorkManager 拉起后打开白屏、启动耗时超出预期（flutter_logs 静态 channel 被后台引擎销毁时清掉）
- **报告**：2026-11-07（用户：手机一段时间不用后打开 Fushi 白屏，然后提示加载超时）
- **真实性**：✅ 真 bug。OnePlus CPH2747（Android 16，3.3.0-debug.24478）经无线 adb 自然复现两次，日志全程在案。
  - 链路：进程在后台被系统回收 → WorkManager 周期任务（反馈新回复检查，`fushi/lib/src/feedback/feedback_reply_background.dart`）拉起进程，workmanager 的 `BackgroundWorker` 用 `FlutterEngine(applicationContext)` 建后台引擎 W 并自动注册全部插件 → W 上的 audio_service 插件 `onAttachedToEngine` 里 `connect()` 绑定 `AudioService`，`AudioService.onCreate` 新建主引擎 A 跑 `main()`（停在无界面 gate）→ 任务结束销毁 W。实测时间线：14:45:42.557 W 建、.733 A 建、.844 A 停在 gate、.847 W 销毁；14:47:31 打开界面，A 放行后 `main()` 抛 `MissingPluginException(No implementation found for method initLogs on channel flutter_logs)`。
  - 根因：flutter_logs 2.1.11 `android/src/main/kotlin/com/flutter/logs/plogs/flutter_logs/FlutterLogsPlugin.kt:28-31` 把 `channel` / `event_channel` 存在 `companion object`（进程级静态）。A 附着时覆盖了静态 channel，W 销毁时 `onDetachedFromEngine`（同文件 :345-348）`channel?.setMethodCallHandler(null)` 清掉的是 **A 的** handler。
  - 后果：`fushi/lib/main.dart:741` `await FlutterLogs.initLogs(...)` 抛异常冒到 zone，`appModel.initialise()`（main.dart:794）永不调用；加载页先白屏（首帧延迟），20s 后看门狗显「启动耗时超出预期」。点 Retry 走 `retryInitialise()` 直接跑 init，所以一点就好（现场证据：Retry 时 `_initInFlight` 为 null，即 main 从未调用 initialise）。
- **[x] ① 已修复** — 升级 flutter_logs 2.1.11 → 2.2.8（`fushi/pubspec.yaml`；2.2.7 起 channel 改为插件实例字段，2.2.8 另修 Android `logThis` 等不回复）。顺带更正 `fushi/lib/src/startup/headless_launch_gate.dart` 里把 initLogs 的 MissingPlugin 归因于「无界面引擎」的旧注释。
- **[x] ② 已加自动化测试** — `fushi/test/platform/flutter_logs_engine_scoped_channel_test.dart`：解析到的 flutter_logs 包里 Android 插件的 channel 不得在 companion object、必须是实例字段；并钉住 main() 在 initialise() 前调 initLogs 这一前提。对 2.1.11 源码按同一判据会红。
- **备注**：
  - 全量扫了解析到的所有 Android 插件，channel 存进程级静态的只有 flutter_logs；flutter_webrtc 只有静态 `eventSink`（channel 是实例字段），不影响启动。
  - 遗留结构问题（WorkManager 后台引擎会自动注册 audio_service，每次后台任务都顺带拉起一整个主引擎（停在 gate）常驻；后台引擎销毁时 audio_service 的静态 `audioHandlerInterface` 也随之销毁）已在下方「追加：后台任务不再起 Flutter 引擎」修掉。
  - 设备复测缺口：复现机是用户日常机，装着在用的 debug 通道包，规则不允许覆盖安装；待修复进 debug 通道后按「杀进程 → 等 WorkManager 自然触发（约 15 分钟）→ 打开」复测原始失败路径。

### 追加：后台任务不再起 Flutter 引擎（2026-11-10，反馈 `yjn-3h8B-7`）
- **根因**：全仓唯一的 WorkManager 任务是反馈回复检查，`fushi/lib/src/feedback/feedback_reply_background.dart:164`（修复前）经 workmanager 插件 `registerPeriodicTask` 排；workmanager_android 0.10.9 `BackgroundWorker.kt:132` 用 `FlutterEngine(applicationContext)` 建后台引擎 W 并自动注册全部插件 → audio_service 0.18.18 `AudioServicePlugin.onAttachedToEngine`（`AudioServicePlugin.java:266-283`）在 `mediaBrowser == null` 时 `connect()`，并把进程级静态 `audioHandlerInterface` 绑到 W → `AudioService.onCreate` 经 `getFlutterEngine`（`:70-111`）新建主引擎 A 跑 `main()`，停在 BUG-4072 的无界面 gate 常驻；W 销毁时 `audioHandlerInterface` 跟着销毁。只要后台检查还跑在一个 Flutter 引擎里，「自动注册了哪个插件」就是一份永远要追着插件版本维护的名单，所以从宿主上拿掉引擎。
- **[x] ① 已修复**：
  - Android 的检查改为纯原生 `CoroutineWorker`：`fushi/android/app/src/main/kotlin/app/fushi/reader/feedback/FeedbackReplyWorker.kt`。读与 Dart 共用的 `<supportRoot>/feedback/tickets.json`（只读）与 `poll_state.json`（只改 `notified`，锁文件协议与 Dart `FeedbackReplyStateStore` 相同，`FeedbackReplyStateFile.kt`），OkHttp 直接 POST `/v1/feedback/status`（凭据是每条反馈的 ticket，本就在 tickets.json 里），有新回复发系统通知。判据（可查条目、15 分钟节流、按条水位、远程推送覆盖、通知 id 派生）抽成纯函数 `FeedbackReplyCheck.kt`，与 Dart `pollFeedbackRepliesInBackground` 逐条一致。
  - 点通知：PendingIntent 按 flutter_local_notifications 的点击契约（`SELECT_NOTIFICATION` + `notificationId` / `payload`）打开启动 Activity，点击照常经 `LocalUpdateNotifier` 进反馈详情，冷启动也走 launch details。渠道沿用 `fushi_updates`。
  - 排程：`FeedbackReplyWorkChannel.kt`（主引擎，`app.fushi.reader/feedback_reply_work`），Dart 门面 `AndroidFeedbackReplyScheduler` 传任务名（冻结的 `kFeedbackReplyTaskName`）、周期、数据根、默认服务器；遇到旧版插件 `BackgroundWorker` 排下的同名任务用 `CANCEL_AND_REENQUEUE` 换掉（`UPDATE` 不允许换 Worker 类），否则 `UPDATE` 保留节奏。
  - workmanager 依赖保留：iOS 仍用它（BGTaskScheduler）；Android 上 lib/ 不再排任何 workmanager 任务。`feedbackReplyBackgroundDispatcher` 保留给 iOS 和 Android 升级前遗留的旧任务。
- **[x] ② 已加自动化测试**（本分支未运行，统一在合并后验证）：
  - `fushi/android/app/src/test/kotlin/app/fushi/reader/feedback/FeedbackReplyCheckTest.kt`：回执筛选、损坏文件、节流、服务器 / 标题回退与端点拼接、请求 / 响应形状、按条水位与旧版全局水位、远程推送覆盖（含旧格式）、通知 id 与 Dart 同值、过期锁收走、迁移策略与插件 Worker 类名。
  - `fushi/test/feedback/feedback_reply_android_worker_test.dart`：Dart 门面经通道排 / 撤的参数、原生报错上抛；生产装配 Android 不走 workmanager、lib/ 别处不 import workmanager；通道名两边一致且 MainActivity 注册；Worker 不碰 `io.flutter`；Kotlin 常量与 Dart 一致；点击契约对照解析到的 flutter_local_notifications 源码。
- **备注**：
  - 升级后到用户首次打开新版本重新排程之前，旧的插件任务还会按旧路径跑，期间旧现象仍可能出现。
  - 后台检查用系统代理（OkHttp 默认 `ProxySelector`）；用户在 app 里手填的代理存在 Drift 里，后台读不到——与旧 Dart 后台实现一样。
  - iOS 的 BGTask 引擎仍由 `AppDelegate.swift` 的 `setPluginRegistrantCallback` 全量注册插件，是否有同形问题未在本条处理。
  - 未做真机复测。复测方法：杀进程，`adb shell cmd jobscheduler run -f <包名> <jobId>` 强制触发，logcat 确认没有 `FlutterEngine` / `AudioService onCreate` / 第二次 `main()`，之后打开 app 启动正常。
