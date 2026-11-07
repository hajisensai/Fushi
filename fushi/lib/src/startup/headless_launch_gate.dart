/// BUG-4072 方案 C：无界面拉起的引擎走精简入口——界面接上来之前不跑完整 app 初始化。
///
/// 谁会无界面跑 `main()`：Android 上系统媒体续播 / 媒体键 / 车机绑
/// `com.ryanheise.audioservice.AudioService`（`MediaBrowserService`）时，
/// `AudioService.onCreate` → `AudioServicePlugin.getFlutterEngine` 在没有 Activity 的情况下
/// 新建引擎跑默认入口；iOS 上系统后台拉起（后台刷新、推送、音频）时隐式引擎照样跑 `main()`。
///
/// 这类引擎以前跑**完整**初始化，带来三件事：
/// 1. 消费并覆写上一个（有界面）会话的会话标记、在没人看得见的引擎里做闪退判定 / 提示 /
///    auto_send（previous_exit_log.dart、crash_report.dart）；
/// 2. `MainActivity.configureFlutterEngine` 才注册的通道（`app.fushi.reader/tts`、
///    `app.fushi.reader/process_exit`）在这个引擎上全是 MissingPluginException——
///    Activity 之后接管这个缓存引擎时，Dart 早期那几次调用已经失败、不会重来；
///    （`FlutterLogs.initLogs` 的 MissingPluginException 不属此类：那是 flutter_logs
///    2.1.x 把 channel 存成进程级静态、同进程另一个引擎销毁时把它清掉，BUG-4220，
///    已靠升级插件根修）；
/// 3. 无界面进程常驻后台却开着数据库、词典、同步、WebView 预热，白占内存。
///
/// 精简入口：原生说「这次没有界面」时，`main()` 只做 binding 初始化然后停在这里，等到
/// 第一个前台生命周期（resumed / inactive）才放行，后面的完整初始化原样跑。不 runApp、
/// 不碰会话标记 / 闪退报告 / 日志插件 / 数据库——这一关之前的东西就是无界面引擎的全部开销。
///
/// 媒体会话不需要在这里装任何 Dart 服务：audio handler 一直是按需起的
/// （`AudioController.initialiseHandler`，用户打开有声书 / 音乐时），完整初始化也从不在启动时
/// 调 `AudioService.init`；无界面引擎里原生 `AudioService` 自己答 `onGetRoot`，Dart 侧
/// handler 没配置时 `onLoadChildren` / 媒体键回空——与以前跑完整初始化时的行为相同。
///
/// 放行时机与通道的先后：Android 上 FlutterActivity 接管缓存引擎发生在 `onCreate`
/// （`attachToActivity` → `configureFlutterEngine` 同步注册 tts / process_exit），
/// 而 resumed / inactive 要到 `onResume` / `onPause` 才发，所以放行后 Dart 发出的第一条调用
/// 一定落在已配置好的引擎上。
///
/// 判据沿用方案 A（`package:fushi_launch_presence`）：只有原生**明确**说没有界面才拦；
/// 不知道（桌面、没注册通道、形状不对）一律走完整入口——宁可退回旧行为，也不把真正的
/// 有界面启动卡在这里。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi_launch_presence/fushi_launch_presence.dart';

/// 入口路由结果。
enum LaunchEntry {
  /// 直接跑完整初始化。
  full,

  /// 原生说这次没有界面：先等界面接上来，再跑完整初始化。
  deferUntilUi,
}

/// 视为「界面已接上」的生命周期：resumed 与 inactive 都意味着有窗口挂在引擎上。
/// hidden / paused / detached 与 null（从没收到过）都不算。
bool lifecycleHasUi(AppLifecycleState? state) =>
    state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

/// 纯判定：这次启动走哪个入口。
///
/// * 非移动端：没有无界面启动 → [LaunchEntry.full]；
/// * 原生不知道（[presence] 为 null）或说有界面 → [LaunchEntry.full]；
/// * 原生说没界面但生命周期已经在前台（问答期间界面接上来了）→ [LaunchEntry.full]；
/// * 其余 → [LaunchEntry.deferUntilUi]。
LaunchEntry chooseLaunchEntry({
  required bool mobile,
  required LaunchPresence? presence,
  required AppLifecycleState? lifecycle,
}) {
  if (!mobile) return LaunchEntry.full;
  if (presence == null || presence.hasUi) return LaunchEntry.full;
  if (lifecycleHasUi(lifecycle)) return LaunchEntry.full;
  return LaunchEntry.deferUntilUi;
}

/// 等到 [binding] 的生命周期进入前台（[lifecycleHasUi]）。已经在前台则立即完成。
///
/// 先查当前值再挂观察者，两步之间没有 await，不会漏掉中间到达的生命周期消息。
Future<void> waitForUiLifecycle(WidgetsBinding binding) {
  if (lifecycleHasUi(binding.lifecycleState)) return Future<void>.value();
  final _UiLifecycleWaiter waiter = _UiLifecycleWaiter(binding);
  binding.addObserver(waiter);
  return waiter.done.future;
}

class _UiLifecycleWaiter with WidgetsBindingObserver {
  _UiLifecycleWaiter(this.binding);

  final WidgetsBinding binding;
  final Completer<void> done = Completer<void>();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (done.isCompleted || !lifecycleHasUi(state)) return;
    binding.removeObserver(this);
    done.complete();
  }
}

/// 精简入口这一关的结果，完整初始化起来后写进错误日志当证据。
@immutable
class HeadlessLaunchOutcome {
  const HeadlessLaunchOutcome({
    required this.entry,
    required this.presenceDetail,
    required this.waitedMs,
  });

  final LaunchEntry entry;

  /// 原生给的取证（[LaunchPresence.detail]）；没问 / 不知道 / 空为 null。
  final String? presenceDetail;

  /// 在这一关等了多久（直接放行为 0）。
  final int waitedMs;

  bool get deferred => entry == LaunchEntry.deferUntilUi;

  /// 只在真拦过时给一条诊断文本；直接放行返回 null（不往日志里灌噪音）。
  String? describe() {
    if (!deferred) return null;
    return 'headless launch held at lean entry for ${waitedMs}ms until UI '
        'attached (launch={${presenceDetail ?? ''}})';
  }
}

/// 本进程这一关的结果（main 写日志用；没走过为 null）。
HeadlessLaunchOutcome? get lastHeadlessLaunchOutcome => _lastOutcome;
HeadlessLaunchOutcome? _lastOutcome;

/// 日志 source 标签（不是 i18n key）。
const String kHeadlessLaunchLogSource = 'Startup.headlessLeanEntry';

/// `main()` 在 binding 初始化之后、任何完整初始化之前 await 这一关。
///
/// [mobile] / [channel] / [nowMs] 供测试注入；生产用平台判断、正式通道与墙钟。
Future<HeadlessLaunchOutcome> holdHeadlessLaunchUntilUi({
  required WidgetsBinding binding,
  bool? mobile,
  MethodChannel channel = launchPresenceChannel,
  int Function()? nowMs,
}) async {
  final int Function() clock =
      nowMs ?? () => DateTime.now().millisecondsSinceEpoch;
  final bool isMobile = mobile ?? (Platform.isAndroid || Platform.isIOS);
  final LaunchPresence? presence = isMobile
      ? await queryLaunchPresence(channel: channel)
      : null;
  final LaunchEntry entry = chooseLaunchEntry(
    mobile: isMobile,
    presence: presence,
    lifecycle: binding.lifecycleState,
  );
  final String? detail = presence == null || presence.detail.isEmpty
      ? null
      : presence.detail;
  int waited = 0;
  if (entry == LaunchEntry.deferUntilUi) {
    final int start = clock();
    debugPrint('[Fushi] headless launch: lean entry, waiting for UI ($detail)');
    await waitForUiLifecycle(binding);
    waited = clock() - start;
  }
  return _lastOutcome = HeadlessLaunchOutcome(
    entry: entry,
    presenceDetail: detail,
    waitedMs: waited,
  );
}
