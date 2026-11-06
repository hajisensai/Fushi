import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/mining/web_mine_idle.dart';

/// 网页视频制卡队列的**后台**空闲自动制卡：用户不在网页播放页时也能跑。
///
/// 页面级的 [WebMineIdleScheduler]（`web_video_fushi_page.dart`）只在播放页开着、已暂停时
/// 生效——用户关掉播放页去干别的，攒下的队列就一直躺着，「全自动」名不副实。这里在 app
/// 级别盯同一个系统空闲判据：整台机器 [kWebMineIdleThreshold] 无输入、Fushi 里没有东西
/// 在播（[nothingPlaying]：用户停在哪一页都行，制卡页叠上去、跑完关掉就回到原处）、没开着
/// 自带空闲制卡的网页播放页（那一页自己跑）、某本网页视频书有待办 → 打开那本书的制卡页
/// 静音重放（[openMiningPage]，跑完自己关），一次一本；还空闲就接着下一本。
/// 用户一回来：页面自己的调度器录完当前这句即停、关页，本轮试过的书清空，下次空闲重来。
///
/// 纯编排、无 UI：页面打开 / 顶层判断 / 待办查询全部注入，测试里用假件。
class WebMineBackgroundRunner {
  WebMineBackgroundRunner({
    required this.pendingBookUids,
    required this.nothingPlaying,
    required this.openMiningPage,
    Duration? Function()? inputIdle,
    Timer Function(Duration d, void Function() f)? createTimer,
    this.refreshInterval = const Duration(seconds: 30),
    Duration idlePoll = const Duration(seconds: 5),
    Duration activePoll = const Duration(milliseconds: 500),
  }) : _createTimer = createTimer ?? Timer.new {
    _scheduler = WebMineIdleScheduler(
      canStart: _canStart,
      onIdle: _onIdle,
      onUserActive: _onUserActive,
      inputIdle: inputIdle,
      idlePoll: idlePoll,
      activePoll: activePoll,
      pageLevel: false,
      createTimer: createTimer,
    );
  }

  /// 有待办、且能在网页播放器里重放的书（按最早入队排）。
  final Future<List<String>> Function() pendingBookUids;

  /// 此刻能不能把制卡页叠上去：Fushi 里没有东西在播（视频 / 有声书 / 音乐）。用户
  /// 停在哪一页都行——制卡页压在它上面，跑完关掉就回到原处。
  final bool Function() nothingPlaying;

  /// 打开这本书的制卡页，页面关掉（跑完 / 让位 / 放弃）时完成。
  final Future<void> Function(String bookUid) openMiningPage;

  final Duration refreshInterval;
  final Timer Function(Duration d, void Function() f) _createTimer;
  late final WebMineIdleScheduler _scheduler;

  Timer? _refreshTimer;
  List<String> _pending = const <String>[];
  bool _running = false;
  bool _disposed = false;

  /// 本次空闲里已经开过的书：页面放弃了（静音录音起不来、导航超时）待办还在，
  /// 不能在用户回来之前反复开同一本。
  final Set<String> _attempted = <String>{};

  @visibleForTesting
  WebMineIdleScheduler get scheduler => _scheduler;

  @visibleForTesting
  bool get running => _running;

  void start() {
    if (_disposed) return;
    unawaited(refresh());
    _scheduleRefresh();
    _scheduler.start();
  }

  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _scheduler.dispose();
  }

  /// 重读待办（入队 / 跑完后页面外的状态变化靠这个低频轮询跟上）。
  @visibleForTesting
  Future<void> refresh() async {
    try {
      final List<String> uids = await pendingBookUids();
      if (!_disposed) _pending = uids;
    } catch (_) {
      // DB 暂不可读：保留上一次结果，下一拍再读。
    }
  }

  void _scheduleRefresh() {
    _refreshTimer = _createTimer(refreshInterval, () {
      if (_disposed) return;
      unawaited(refresh());
      _scheduleRefresh();
    });
  }

  String? get _next {
    for (final String uid in _pending) {
      if (!_attempted.contains(uid)) return uid;
    }
    return null;
  }

  bool _canStart() =>
      !_disposed &&
      !_running &&
      !WebMineIdleScheduler.silentCaptureUnavailable &&
      WebMineIdleScheduler.livePageSchedulers == 0 &&
      _next != null &&
      nothingPlaying();

  void _onIdle() {
    final String? uid = _next;
    if (uid == null) {
      _scheduler.runFinished();
      return;
    }
    _running = true;
    _attempted.add(uid);
    unawaited(_run(uid));
  }

  Future<void> _run(String uid) async {
    try {
      await openMiningPage(uid);
    } catch (_) {
      // 页面没开起来：这本记作已试过，等用户回来再说。
    } finally {
      _running = false;
      await refresh();
      if (!_disposed) _scheduler.runFinished();
    }
  }

  /// 用户回来了：页面自己的调度器负责让位关页；这里只把「本次空闲已试过」清掉。
  void _onUserActive() => _attempted.clear();
}
