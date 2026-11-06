/// 后台更新检查的调度（v101）。
///
/// **一个定时器**，各域自带「上次查过没多久」的到期判据。不是三个 Timer：三个
/// 定时器要各自 start/stop/dispose、各自在 App 前后台切换时对齐，而它们要做的
/// 事只有「醒来看看谁到点了」——把周期差异做成数据（[intervals]），定时器就只剩
/// 一个，前后台对齐也只有一处。
///
/// 番剧**不在这里**：它有自己的相位学习节奏（`subscription_check_schedule.dart`
/// 从订阅的历史发布时刻学出周内相位，热窗加密、冷窗拉长），比这里的固定间隔准
/// 得多，也早就在跑。把它拉进来只会退化成均匀轮询。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';

/// 一次域检查。抛异常 = 这轮没查成（网络不通、源挂了），调度器吞掉并照常记时刻
/// ——不记的话每个 tick 都会重试，网络一断就是一场对源站的连击。
typedef UpdateProbe = Future<void> Function();

/// 某个域上次检查完成的时刻（毫秒）落这个偏好键。
String updateLastCheckPrefKey(UpdateFeedKind kind) =>
    'updates_last_check_${kind.dbValue}';

/// 调度器的域开关（[UpdateCheckScheduler.isKindEnabled] 的生产接线）。
///
/// 番剧新集域在调度器里只跑「媒体库在线作品补新集」：跑不跑看它自己的开关
/// [videoLibraryAutoUpdate]（`video_library_auto_update`），**不看**「番剧新集提醒」
/// ——提醒开关只决定补上的集进不进更新中心（publishBatch 按域开关丢弃），用户
/// 2026-10-23 拍板拆开。其余域看各自的提醒开关 [notifyEnabled]。
bool Function(UpdateFeedKind) updateCheckKindGate({
  required bool Function() videoLibraryAutoUpdate,
  required bool Function(UpdateFeedKind) notifyEnabled,
}) =>
    (UpdateFeedKind kind) => kind == UpdateFeedKind.videoEpisode
    ? videoLibraryAutoUpdate()
    : notifyEnabled(kind);

class UpdateCheckScheduler {
  UpdateCheckScheduler({
    required PreferencesRepository prefs,
    required Map<UpdateFeedKind, UpdateProbe> probes,
    required bool Function(UpdateFeedKind) isKindEnabled,
    this.intervals = kDefaultUpdateCheckIntervals,
    this.tick = const Duration(minutes: 30),
    Set<UpdateFeedKind> dueOnStart = const <UpdateFeedKind>{},
    DateTime Function() now = DateTime.now,
  }) : _prefs = prefs,
       _dueOnStart = <UpdateFeedKind>{...dueOnStart},
       _probes = probes,
       _isKindEnabled = isKindEnabled,
       _now = now;

  /// 各域的最小检查间隔。
  ///
  /// 漫画 6 小时：连载更新是天级事件，查得再密也只是给源站加压。
  /// 扩展与 app 24 小时：版本发布是周级事件，一天一次已经足够快。
  static const Map<UpdateFeedKind, Duration> kDefaultUpdateCheckIntervals =
      <UpdateFeedKind, Duration>{
        // 番剧域在这里只有「媒体库在线作品补新集」（订阅仍走自己的相位节奏，见库注释）。
        UpdateFeedKind.videoEpisode: Duration(hours: 6),
        UpdateFeedKind.mangaChapter: Duration(hours: 6),
        UpdateFeedKind.mangaExtension: Duration(hours: 24),
        UpdateFeedKind.animeExtension: Duration(hours: 24),
        UpdateFeedKind.appRelease: Duration(hours: 24),
      };

  final PreferencesRepository _prefs;
  final Map<UpdateFeedKind, UpdateProbe> _probes;
  final bool Function(UpdateFeedKind) _isKindEnabled;
  final Map<UpdateFeedKind, Duration> intervals;

  /// 醒来的节奏。醒来只是「看看谁到点了」，绝大多数 tick 什么都不做。
  final Duration tick;

  final DateTime Function() _now;

  /// 本进程**第一轮**无视最小间隔、照查一次的域（每个域只豁免一次，查过即移出）。
  ///
  /// 给扩展后台自动更新用：它只在「应用刚启动、还没打开任何在线源」时装，错过
  /// 启动这一轮就只能等下次启动——24 小时间隔若还拦着它，被推迟的更新会一拖再拖。
  final Set<UpdateFeedKind> _dueOnStart;

  Timer? _timer;
  Future<void>? _activeRun;

  bool get isRunning => _timer != null;

  /// 启动。**立刻先跑一轮**：应用启动是用户最可能想知道「我不在的时候更新了
  /// 什么」的时刻，等半小时才第一次检查等于把这个时刻错过。到期判据仍然生效，
  /// 所以频繁重启应用不会变成频繁请求。
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(tick, (_) => unawaited(runDue()));
    unawaited(runDue());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _activeRun;
  }

  /// 跑一轮：到期且开关开着的域各查一次。
  ///
  /// 上一轮还没跑完就直接返回——检查本身是联网操作，慢过一个 tick 是常态，重入
  /// 会让同一个源被同时打两次。
  Future<void> runDue() {
    final Future<void>? active = _activeRun;
    if (active != null) return active;
    final Future<void> run = _runDue();
    _activeRun = run;
    return run.whenComplete(() {
      _activeRun = null;
    });
  }

  Future<void> _runDue() async {
    for (final MapEntry<UpdateFeedKind, UpdateProbe> entry in _probes.entries) {
      final UpdateFeedKind kind = entry.key;
      if (!_isKindEnabled(kind)) continue;
      if (!_dueOnStart.remove(kind) && !isDue(kind)) continue;
      try {
        await entry.value();
      } on Object catch (error) {
        debugPrint(
          'UpdateCheckScheduler: ${kind.dbValue} probe failed. $error',
        );
      }
      // 成败都记：失败也算「这一轮问过了」，否则断网时每个 tick 都重试。
      await _prefs.setPref(
        updateLastCheckPrefKey(kind),
        _now().millisecondsSinceEpoch,
      );
    }
  }

  /// 这个域到点了吗。没有记录过 = 到点（第一次运行就该查一次）。
  bool isDue(UpdateFeedKind kind) {
    final Duration? interval = intervals[kind];
    if (interval == null) return false;
    final Object? raw = _prefs.getPref(
      updateLastCheckPrefKey(kind),
      defaultValue: 0,
    );
    final int last = raw is int ? raw : 0;
    if (last <= 0) return true;
    return _now().millisecondsSinceEpoch - last >= interval.inMilliseconds;
  }

  /// 强制现在查一遍（设置页的「立即检查」）：**绕过**到期判据，但不绕过开关。
  Future<void> checkNow(UpdateFeedKind kind) async {
    final UpdateProbe? probe = _probes[kind];
    if (probe == null || !_isKindEnabled(kind)) return;
    try {
      await probe();
    } finally {
      await _prefs.setPref(
        updateLastCheckPrefKey(kind),
        _now().millisecondsSinceEpoch,
      );
    }
  }
}
