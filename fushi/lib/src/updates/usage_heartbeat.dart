// 安装统计心跳：Android / Windows / macOS / Linux 每个 UTC 日最多发一次 `POST /v1/ping`
// （rank.fushi.moe，服务端 services/leaderboard/src/installs.js），统计日活 / 周活 / 月活与
// 版本 / 平台 / 通道分布。
//
// 上报内容只有四项：本机安装 id（随机 UUID v4，不挂账户、不挂硬件）、运行中的构建版本、平台、
// 当前更新通道。服务端不存 IP。iOS 不发：App Store Connect 自带分析，再发要改隐私标签。
//
// 开关在「设置 › 系统 › 更新」（`usage_stats_enabled`，默认开）；关掉后心跳停发，反馈也不再
// 附带安装 id（[usageStatsInstallIdForFeedback]）。三个偏好都是设备本地的
// （SyncRepository.deviceLocalPrefKeys），不进备份 / 同步 / Profile 快照。
//
// 发送失败不重试轰炸：只等下一次整点 tick（[UsageHeartbeat.tick]）再看是否到期；成功才记
// 「上次心跳」，所以断网一整天的设备恢复联网后的第一个 tick 会补上当天这一次。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 发心跳的平台（与服务端 `PING_PLATFORMS` 一致）。
const Set<String> kUsageHeartbeatPlatforms = <String>{
  'android',
  'windows',
  'macos',
  'linux',
};

/// **纯函数**：[operatingSystem]（`Platform.operatingSystem` 口径）在心跳里的平台键；
/// iOS 与其它平台返回 null（不发心跳、反馈也不带安装 id）。
String? usageHeartbeatPlatformFor(String operatingSystem) =>
    kUsageHeartbeatPlatforms.contains(operatingSystem) ? operatingSystem : null;

/// 本机是否参与安装统计（只看平台，不看开关）。
bool platformSendsUsageHeartbeat() =>
    usageHeartbeatPlatformFor(Platform.operatingSystem) != null;

/// **纯函数**：上次成功心跳在 [lastPingAt]（毫秒，≤ 0 = 从没成功过）之后，[now] 时是否
/// 该再发一次。按 UTC 日判断，与服务端按天去重同口径：同一 UTC 日发多少次都只记一次，
/// 所以这里一天只发一次就够。
bool usageHeartbeatDue({required int lastPingAt, required DateTime now}) {
  if (lastPingAt <= 0) return true;
  final DateTime last = DateTime.fromMillisecondsSinceEpoch(
    lastPingAt,
    isUtc: true,
  );
  final DateTime current = now.toUtc();
  return last.year != current.year ||
      last.month != current.month ||
      last.day != current.day;
}

/// 反馈要附带的安装 id：本平台参与统计且开关开着才有，否则 null。
Future<String?> usageStatsInstallIdForFeedback(
  PreferencesRepository prefs, {
  String? operatingSystem,
}) async {
  if (usageHeartbeatPlatformFor(operatingSystem ?? Platform.operatingSystem) ==
      null) {
    return null;
  }
  if (!prefs.usageStatsEnabled) return null;
  return prefs.ensureUsageStatsInstallId();
}

/// 真正发出一次心跳（生产装配是 `LeaderboardClient.ping`）。失败抛异常。
typedef UsageHeartbeatSender =
    Future<void> Function({
      required String installId,
      required String version,
      required String platform,
      required String channel,
    });

/// 生产发送器：固定发往 [kLeaderboardDefaultBaseUrl]（统计是 Fushi 自己的，不跟随排行榜
/// 账户的自建服务器地址），经 [createAppHttpIoClient] 走全应用代理装配。
Future<void> sendUsageHeartbeatToFushi({
  required String installId,
  required String version,
  required String platform,
  required String channel,
}) =>
    LeaderboardClient(
      baseUrl: Uri.parse(kLeaderboardDefaultBaseUrl),
      httpClientFactory: () async => createAppHttpIoClient(),
    ).ping(
      installId: installId,
      version: version,
      platform: platform,
      channel: channel,
    );

/// 心跳调度：[start] 时立刻看一次是否到期，之后每 [tick] 再看一次（app 连开好几天也
/// 每天都有一次）。幂等：重复 [start] 不起第二个定时器。
class UsageHeartbeat {
  UsageHeartbeat({
    required PreferencesRepository prefs,
    required UsageHeartbeatSender send,
    required String Function() version,
    required String Function() channel,
    String? operatingSystem,
    this.tick = const Duration(hours: 1),
    DateTime Function() now = DateTime.now,
  }) : _prefs = prefs,
       _send = send,
       _version = version,
       _channel = channel,
       _platform = usageHeartbeatPlatformFor(
         operatingSystem ?? Platform.operatingSystem,
       ),
       _now = now;

  final PreferencesRepository _prefs;
  final UsageHeartbeatSender _send;
  final String Function() _version;
  final String Function() _channel;
  final String? _platform;
  final DateTime Function() _now;

  /// 两次到期检查的间隔。
  final Duration tick;

  Timer? _timer;
  Future<bool>? _active;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null || _platform == null) return;
    _timer = Timer.periodic(tick, (_) => unawaited(runIfDue()));
    unawaited(runIfDue());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _active;
  }

  /// 到期就发一次；返回这次是否发出并成功。并发调用共享同一次发送。
  Future<bool> runIfDue() {
    final Future<bool>? active = _active;
    if (active != null) return active;
    final Future<bool> run = _runIfDue().whenComplete(() => _active = null);
    _active = run;
    return run;
  }

  Future<bool> _runIfDue() async {
    final String? platform = _platform;
    if (platform == null || !_prefs.usageStatsEnabled) return false;
    if (!usageHeartbeatDue(
      lastPingAt: _prefs.usageStatsLastPingAt,
      now: _now(),
    )) {
      return false;
    }
    try {
      await _send(
        installId: await _prefs.ensureUsageStatsInstallId(),
        version: _version(),
        platform: platform,
        channel: _channel(),
      );
    } catch (error) {
      // 断网 / 服务端日预算打满都在这里：等下一个 tick，不记日志上传（不是 app 的错）。
      debugPrint('UsageHeartbeat: ping failed. $error');
      return false;
    }
    await _prefs.setUsageStatsLastPingAt(_now().millisecondsSinceEpoch);
    return true;
  }
}
