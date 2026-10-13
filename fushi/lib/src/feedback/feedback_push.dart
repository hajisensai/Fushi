// iOS 远程推送：「开发者回复了你的反馈」（服务端 services/leaderboard/src/feedback_push.js）。
//
// 为什么只有 iOS：iOS 的后台任务（BGAppRefresh，PR #2102）由系统决定时机，常常几小时
// 不跑；APNs 推送在 app 没运行时也能到。Android 国内机型没有 GMS，不接 FCM，继续用
// WorkManager 后台检查；桌面运行中定时检查，都不经这里。
//
// 原生半边在 ios/Runner/AppDelegate.swift（channel `app.fushi.reader/remote_push`）：
// 不引入推送插件——Flutter 的 FlutterAppDelegate 已经把 APNs 注册回调与
// UNUserNotificationCenter 委托转发给我们，几十行 Swift 就够，多一个插件多一份与
// flutter_local_notifications 抢通知委托的风险。
//
// 登记规则（[FeedbackPushRegistrar.sync]，幂等）：
// - 开关「反馈有新回复时通知我」关、系统通知未授权、原生拿不到令牌（缺 aps-environment
//   entitlement / 模拟器 / 非 iOS）→ 注销已登记的全部，不再登记；
// - 否则：本机每条未结案反馈用当前令牌登记一次；已结案 / 被删的注销；令牌变了先注销旧的；
// - 登记结果（令牌、已登记 id、服务端是否「会推送」）落在 poll_state.json，与提醒水位同一份
//   文件：被推送覆盖的反馈，本机的 snackbar / 后台本地通知不再重复提醒。
//
// 点推送 → 直达那条反馈（与 #2102 的本地通知同一个落点 openFeedbackTicket）。前台收到推送
// 时系统照常弹横幅，同时立刻刷新一次进度（红点），见 main.dart。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:fushi/src/feedback/feedback_reply_state.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';

/// 原生推送能力。
abstract class RemotePushPlatform {
  /// 平台有没有远程推送这条路（目前只有 iOS）。
  bool get supported;

  /// 向系统注册远程推送并取回 device token（十六进制）。拿不到（没有 aps-environment
  /// entitlement、网络、模拟器）返回 null。
  Future<String?> deviceToken();

  /// 冷启动：是不是点了反馈推送把 app 拉起来的，是就返回那条反馈 id（只回一次）。
  /// 调用之后原生侧才开始把后续事件直接投给 Dart。
  Future<String?> takeLaunchFeedbackId();

  /// 运行中点了反馈推送（反馈 id）。
  Stream<String> get taps;

  /// app 在前台时收到了反馈推送（反馈 id）。
  Stream<String> get foregroundPushes;
}

/// 非 iOS / 测试：没有远程推送。
class NoRemotePush implements RemotePushPlatform {
  const NoRemotePush();

  @override
  bool get supported => false;

  @override
  Future<String?> deviceToken() async => null;

  @override
  Future<String?> takeLaunchFeedbackId() async => null;

  @override
  Stream<String> get taps => const Stream<String>.empty();

  @override
  Stream<String> get foregroundPushes => const Stream<String>.empty();
}

/// iOS 原生半边（AppDelegate.swift 的 `FushiRemotePush`）。
class MethodChannelRemotePush implements RemotePushPlatform {
  MethodChannelRemotePush({
    MethodChannel channel = const MethodChannel(kRemotePushChannel),
    this.tokenTimeout = const Duration(seconds: 30),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;

  /// 系统迟迟不回 didRegister / didFail（离线时会发生）就放弃这一次，下次 sync 再来。
  final Duration tokenTimeout;

  final StreamController<String> _taps = StreamController<String>.broadcast();
  final StreamController<String> _foreground =
      StreamController<String>.broadcast();

  Future<Object?> _onCall(MethodCall call) async {
    final Object? id = call.arguments;
    if (id is! String || id.isEmpty) return null;
    switch (call.method) {
      case 'onTap':
        _taps.add(id);
      case 'onForegroundPush':
        _foreground.add(id);
    }
    return null;
  }

  @override
  bool get supported => true;

  @override
  Future<String?> deviceToken() async {
    try {
      final String? token = await _channel
          .invokeMethod<String>('register')
          .timeout(tokenTimeout);
      return token == null || token.isEmpty ? null : token.toLowerCase();
    } on TimeoutException {
      return null;
    } on PlatformException catch (e, st) {
      ErrorLogService.instance.log('feedback.push_token', e, st);
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<String?> takeLaunchFeedbackId() async {
    try {
      return await _channel.invokeMethod<String>('takeLaunchFeedbackId');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Stream<String> get foregroundPushes => _foreground.stream;
}

/// 原生 channel 名（AppDelegate.swift 逐字一致）。
const String kRemotePushChannel = 'app.fushi.reader/remote_push';

RemotePushPlatform createRemotePushPlatform() =>
    Platform.isIOS ? MethodChannelRemotePush() : const NoRemotePush();

/// 一次登记同步的结论（测试与日志用）。
class FeedbackPushSyncResult {
  const FeedbackPushSyncResult({
    this.registered = const <String>[],
    this.unregistered = const <String>[],
    this.delivering = false,
  });

  final List<String> registered;
  final List<String> unregistered;
  final bool delivering;
}

class FeedbackPushRegistrar {
  FeedbackPushRegistrar({
    required this.platform,
    required Future<List<FeedbackTicket>> Function() tickets,
    required LeaderboardClient Function() client,
    required Future<FeedbackReplyStateStore> Function() stateStore,
    required bool Function() enabled,
    required Future<bool> Function() permitted,
    required String Function() lang,
  }) : _tickets = tickets,
       _client = client,
       _stateStore = stateStore,
       _enabled = enabled,
       _permitted = permitted,
       _lang = lang;

  final RemotePushPlatform platform;
  final Future<List<FeedbackTicket>> Function() _tickets;
  final LeaderboardClient Function() _client;
  final Future<FeedbackReplyStateStore> Function() _stateStore;
  final bool Function() _enabled;
  final Future<bool> Function() _permitted;
  final String Function() _lang;

  Future<FeedbackPushSyncResult>? _inFlight;

  /// 按当前开关 / 权限 / 本机工单把服务端登记对齐（见文件头）。并发调用合并成一次。
  Future<FeedbackPushSyncResult> sync() {
    if (!platform.supported) {
      return Future<FeedbackPushSyncResult>.value(
        const FeedbackPushSyncResult(),
      );
    }
    return _inFlight ??= _sync().whenComplete(() => _inFlight = null);
  }

  Future<FeedbackPushSyncResult> _sync() async {
    final FeedbackReplyStateStore store = await _stateStore();
    final FeedbackReplyState state = await store.read();
    final List<FeedbackTicket> all = await _tickets();
    final Map<String, FeedbackTicket> byId = <String, FeedbackTicket>{
      for (final FeedbackTicket t in all) t.id: t,
    };

    final String? token = _enabled() && await _permitted()
        ? await platform.deviceToken()
        : null;

    final List<String> unregistered = <String>[];
    // 令牌换了 / 不再推送：旧令牌在服务端的登记逐条注销。
    final String? oldToken = state.pushToken;
    final List<String> kept = <String>[];
    for (final String id in state.pushRegistered) {
      final FeedbackTicket? t = byId[id];
      final bool keep =
          token != null && token == oldToken && t != null && _wantsPush(t);
      if (keep) {
        kept.add(id);
        continue;
      }
      if (oldToken != null && t != null) {
        await _unregister(t, oldToken);
      }
      unregistered.add(id);
    }

    if (token == null) {
      await store.update(
        (FeedbackReplyState s) => s.withPush(
          token: null,
          registered: const <String>[],
          delivering: false,
        ),
      );
      return FeedbackPushSyncResult(unregistered: unregistered);
    }

    final List<String> added = <String>[];
    bool delivering = token == oldToken && state.pushDelivering;
    for (final FeedbackTicket t in all) {
      if (!_wantsPush(t) || kept.contains(t.id)) continue;
      final bool? d = await _register(t, token);
      if (d == null) continue;
      delivering = d;
      added.add(t.id);
    }
    final List<String> registered = <String>[...kept, ...added];
    await store.update(
      (FeedbackReplyState s) => s.withPush(
        token: token,
        registered: registered,
        delivering: delivering,
      ),
    );
    return FeedbackPushSyncResult(
      registered: added,
      unregistered: unregistered,
      delivering: delivering,
    );
  }

  static bool _wantsPush(FeedbackTicket t) => !t.status.isClosed && !t.missing;

  /// 登记成功返回服务端是否「会推送」；失败（离线 / 已结案 409 / 回执失效 404）返回 null，
  /// 这条留给下次 sync。
  Future<bool?> _register(FeedbackTicket t, String token) async {
    try {
      return await _client().registerFeedbackPushToken(
        t.id,
        t.ticket,
        token: token,
        lang: _lang(),
      );
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.push_register', e, st);
      return null;
    }
  }

  /// 注销失败只记日志：服务端在结案 / APNs 报令牌失效时也会清掉，登记不会永久残留。
  Future<void> _unregister(FeedbackTicket t, String token) async {
    try {
      await _client().unregisterFeedbackPushToken(t.id, t.ticket, token: token);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('feedback.push_unregister', e, st);
    }
  }
}
