// 「反馈有新回复时通知我」的主 isolate 编排：开关、后台检查的排程、桌面运行中的定时
// 检查、首次提交后的通知权限申请。
//
// 三条提醒路径与它们的分工：
// - 启动 / 回到前台：FeedbackReplyNotifier.check() → 应用内 snackbar（PR #2092）；
// - 移动端 app 不在前台：系统后台任务（feedback_reply_background.dart）→ 本地通知；
// - 桌面 app 运行中（含最小化 / 托盘）：每 [kFeedbackReplyPollInterval] 一次
//   [tick]，窗口在前台就 snackbar、否则系统通知（Windows toast）。
// - iOS 还有第四条：服务端 APNs 远程推送（feedback_push.dart），app 没运行也能到；
//   被推送覆盖的反馈，上面三条不再重复提醒。
// 几条路径共用 poll_state.json 的提醒水位，同一条回复只提醒一次。
//
// 开关只管「系统级」那两条（后台任务 + 系统通知）；应用内 snackbar 不受它控制——
// 那是用户正在用 app 时的被动提示，与红点同性质。

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/feedback/feedback_push.dart';
import 'package:fushi/src/feedback/feedback_reply_background.dart';
import 'package:fushi/src/feedback/feedback_reply_notifier.dart';
import 'package:fushi/src/feedback/feedback_reply_state.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 开关的偏好键（bool，默认 true）。登记在 preference_keys.dart。
const String kFeedbackReplyNotificationsPref = 'feedback_reply_notifications';

/// 「有回复时通知我」开关的唯一读取口径（默认开）。设置行显示开关值只需要它——
/// 不必为读一个布尔值去构造 [feedbackReplyAlertsProvider] 那整张依赖图（通知器 →
/// 反馈服务 → 读回执）。
bool feedbackReplyNotificationsEnabled(PreferencesRepository prefs) =>
    prefs.getPref(kFeedbackReplyNotificationsPref, defaultValue: true) as bool;

/// 一次 [FeedbackReplyAlerts.tick] 的去向。
enum FeedbackReplyDelivery {
  /// 没有要提醒的。
  none,

  /// 交给调用方弹应用内提示（窗口在前台）。
  inApp,

  /// 已发系统通知。
  system,
}

class FeedbackReplyAlerts {
  FeedbackReplyAlerts({
    required this.checker,
    required this.systemNotifier,
    required this.scheduler,
    this.push,
    required bool Function() readEnabled,
    required Future<void> Function(bool value) writeEnabled,
    required Future<String> Function() serverUrl,
    required String Function() alertTitle,
  }) : _readEnabled = readEnabled,
       _writeEnabled = writeEnabled,
       _serverUrl = serverUrl,
       _alertTitle = alertTitle;

  final FeedbackReplyNotifier checker;
  final UpdateNotifier systemNotifier;
  final FeedbackReplyBackgroundScheduler scheduler;

  /// iOS 远程推送的令牌登记（feedback_push.dart）；null / 平台不支持 = 没有这条路。
  final FeedbackPushRegistrar? push;
  final bool Function() _readEnabled;
  final Future<void> Function(bool value) _writeEnabled;
  final Future<String> Function() _serverUrl;
  final String Function() _alertTitle;

  /// 「反馈有新回复时通知我」。
  bool get enabled => _readEnabled();

  /// 改开关并立刻同步后台排程（关 = 撤掉后台任务）。
  Future<void> setEnabled(bool value) async {
    await _writeEnabled(value);
    await syncSchedule();
  }

  /// 后台检查该不该排着：开关开 **且** 有后台查得了的未结案反馈（本机回执，见
  /// [FeedbackReplyNotifier.hasBackgroundPollableTickets]）才排，否则撤掉——没东西可等、
  /// 或者只剩后台查不了的账户条目时，不该让系统隔 15 分钟白拉起一次 app。账户条目由
  /// 前台 / 桌面运行中的检查覆盖，iOS 上还有远程推送。排之前把后台 isolate 需要、却自己拿
  /// 不到的运行环境（服务器地址、当前语言的通知标题）写进状态文件。
  ///
  /// 启动、回到前台、提交反馈后、改开关时调用；幂等。顺带对齐 iOS 远程推送的令牌登记
  /// （开关关 / 未授权 → 全部注销；否则未结案的登记、已结案的注销）。
  Future<void> syncSchedule() async {
    await syncPush();
    if (!scheduler.supported) return;
    try {
      if (!enabled || !await checker.hasBackgroundPollableTickets()) {
        await scheduler.cancel();
        return;
      }
      final String server = await _serverUrl();
      final String title = _alertTitle();
      await (await checker.stateStore()).update(
        (FeedbackReplyState s) =>
            s.copyWith(serverUrl: server, alertTitle: title),
      );
      await scheduler.schedule();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.reply_schedule', e, st);
    }
  }

  /// 只对齐远程推送登记（[syncSchedule] 的前半段）：通知权限刚变化之后单独调。
  Future<void> syncPush() async {
    final FeedbackPushRegistrar? registrar = push;
    if (registrar == null) return;
    try {
      await registrar.sync();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.push_sync', e, st);
    }
  }

  /// 桌面运行中的定时检查（节流与水位都在 [FeedbackReplyNotifier.check] 里）。
  /// [foreground] = 窗口此刻在前台：交给调用方弹应用内提示；否则发系统通知。
  /// 开关关着时什么都不做（这条路径只为系统通知而存在，前台提示有启动 / 回前台那条）。
  Future<({FeedbackReplyDelivery delivery, FeedbackReplyCheck result})> tick({
    required bool foreground,
  }) async {
    const ({FeedbackReplyDelivery delivery, FeedbackReplyCheck result}) none = (
      delivery: FeedbackReplyDelivery.none,
      result: FeedbackReplyCheck.none,
    );
    if (!enabled) return none;
    final FeedbackReplyCheck result = await checker.check();
    if (!result.announce) return none;
    if (foreground) {
      return (delivery: FeedbackReplyDelivery.inApp, result: result);
    }
    final bool sent = await postFeedbackReplyNotifications(
      systemNotifier,
      result.fresh,
      title: _alertTitle(),
    );
    return (
      // 发不出（没授权 / 后端不可用）就到此为止：刷新已把红点点亮，用户回到窗口
      // 能看到；不重试同一条（水位已推进）。
      delivery: sent
          ? FeedbackReplyDelivery.system
          : FeedbackReplyDelivery.none,
      result: result,
    );
  }

  /// 首次提交反馈成功后：开关开着、系统还没授权、之前没申请过 → 向系统申请一次通知
  /// 权限（Android 13+ / iOS / macOS 会弹系统框）。时机是用户刚做完「提交」这个显式
  /// 动作、正等着回复的时候——不在启动期弹（BUG-2498）。只申请一次，被拒就不再追着要，
  /// 用户可以在设置里重新打开。
  Future<void> requestPermissionAfterSubmit() async {
    try {
      if (!enabled) return;
      final FeedbackReplyStateStore store = await checker.stateStore();
      if ((await store.read()).permissionAsked) return;
      if (!await systemNotifier.ensureReady()) return;
      if (await systemNotifier.hasPermission()) return;
      await store.update(
        (FeedbackReplyState s) => s.copyWith(permissionAsked: true),
      );
      // 授权了才登记远程推送（没授权时推送到了也不显示，登记了反而让本机路径以为
      // 「推送会提醒」而不再提醒）。
      if (await systemNotifier.requestPermission()) await syncPush();
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.reply_permission', e, st);
    }
  }
}

/// 本进程唯一的远程推送原生通道（channel handler 只能挂一个）。
final Provider<RemotePushPlatform> remotePushPlatformProvider =
    Provider<RemotePushPlatform>((Ref ref) => createRemotePushPlatform());

/// 只有桌面需要运行中的定时检查（移动端交给系统后台任务）。
bool get feedbackReplyDesktopPolling =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

final Provider<FeedbackReplyAlerts>
feedbackReplyAlertsProvider = Provider<FeedbackReplyAlerts>((Ref ref) {
  final AppModel app = ref.read(appProvider);
  final FeedbackReplyNotifier checker = ref.read(feedbackReplyNotifierProvider);
  bool readEnabled() => feedbackReplyNotificationsEnabled(app.prefsRepo);
  final RemotePushPlatform pushPlatform = ref.read(remotePushPlatformProvider);
  return FeedbackReplyAlerts(
    checker: checker,
    systemNotifier: app.systemNotifier,
    scheduler: createFeedbackReplyBackgroundScheduler(),
    push: pushPlatform.supported
        ? FeedbackPushRegistrar(
            platform: pushPlatform,
            tickets: () async {
              await checker.service.load();
              return checker.service.tickets;
            },
            // 与反馈中心同一个客户端（同一服务器）。
            client: () => ref.read(leaderboardServiceProvider).feedbackClient(),
            stateStore: checker.stateStore,
            enabled: readEnabled,
            permitted: () async =>
                await app.systemNotifier.ensureReady() &&
                await app.systemNotifier.hasPermission(),
            lang: () => LocaleSettings.currentLocale.languageTag,
          )
        : null,
    readEnabled: readEnabled,
    writeEnabled: (bool v) =>
        app.prefsRepo.setPref(kFeedbackReplyNotificationsPref, v),
    // 与反馈中心刷新进度用的是同一个客户端（账户可覆盖服务器地址），后台必须问
    // 同一个服务器，否则查不到的条目会被当成不存在。
    serverUrl: () async {
      final LeaderboardService board = ref.read(leaderboardServiceProvider);
      try {
        await board.load();
      } on Object {
        // 账户文件读不出 = 未开启，匿名客户端即默认服务器。
      }
      return board.feedbackClient().baseUrl.toString();
    },
    alertTitle: () => t.feedback_reply_notification_title,
  );
});
