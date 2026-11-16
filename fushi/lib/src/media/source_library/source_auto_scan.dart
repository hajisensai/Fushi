/// 来源「自动扫描」（拍板台 C_8oheua0H / ICOLa6LZLU / enSm2GOuFA，维护者拍板）。
///
/// - **开关每来源一个**（`media_sources.auto_scan`，schema v155），默认关；书 / 有声书
///   （书籍来源里的音频 + 字幕组）/ 漫画 / 视频 / 音乐 / 游戏全部来源种类都支持——它们
///   本来就走同一个 [SourceLibraryScanner.scan]。
/// - **触发 = app 启动 + 回到前台**（拍板选项 A）。不做文件系统监听：Android SAF、iOS
///   沙箱与 WebDAV / SFTP / FTP / AList 网络来源都监听不了，五端行为会分裂；启动 / 回
///   前台在五端一致，iOS 也能用。
/// - **限流**：
///   1. 同一时刻只扫一个来源——自动扫描之间串行，并与来源页的手动「重新扫描」共用
///      [SourceScanActivity] 这一条道（手动扫描在跑时自动扫描排在后面，反之手动入口
///      在自动扫描期间置忙）；
///   2. 节流：一个来源上次扫描（`lastScannedAt`，手动扫的也算）或上次自动尝试距今不足
///      [kSourceAutoScanMinInterval] 就跳过——桌面端切窗口也会触发 resumed，没有节流就
///      等于每次 Alt+Tab 都扫一遍；
///   3. 去重：已在队列里或正在扫的来源不重复入队。
/// - **扫完串联自动刮削**由调用方（首页，持有视频刮削任务控制器）的扫描函数负责，见
///   `home_page.dart` 的 `_runAutoSourceScan`。
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';

/// 两次自动扫描同一来源的最小间隔。
const Duration kSourceAutoScanMinInterval = Duration(minutes: 15);

/// 自动扫描的触发时机。
enum SourceAutoScanTrigger {
  /// app 启动（首页首帧后）。
  startup,

  /// app 回到前台（`AppLifecycleState.resumed`）。
  resume,
}

/// 一次自动扫描尝试的结局。
enum SourceAutoScanOutcome {
  /// 真的扫了（成功与否由扫描器写进 `lastScanError`）。
  scanned,

  /// 这次不能扫（例如视频来源的扫描 / 刮削门被用户手动任务占着），留给下一次触发；
  /// 不计入节流。
  deferred,
}

/// 扫描一个来源；由持有页面级依赖（有声书转录端口、视频刮削任务控制器）的调用方实现。
typedef SourceAutoScanRunner =
    Future<SourceAutoScanOutcome> Function(SourceLibraryRow source);

/// 来源扫描占用表：哪些来源此刻正在被扫（手动或自动）。
///
/// 来源页的「重新扫描」和自动扫描都经 [run] 登记，所以：来源页行级 loading 能看到
/// 自动扫描、手动入口在自动扫描期间置忙；自动扫描在手动扫描期间排队（[whenIdle]）。
class SourceScanActivity extends ChangeNotifier {
  final Set<int> _active = <int>{};
  Completer<void>? _idle;

  /// 没有任何来源在扫。
  bool get isIdle => _active.isEmpty;

  /// [sourceId] 正在被扫。
  bool isScanning(int sourceId) => _active.contains(sourceId);

  /// 此刻正在扫的来源 id 快照。
  Set<int> get activeSourceIds => Set<int>.unmodifiable(_active);

  /// 登记 [sourceId] 正在扫描并执行 [operation]；同一来源已在扫时抛 [StateError]
  /// （调用方应先看 [isScanning] / [isIdle]）。
  Future<T> run<T>(int sourceId, Future<T> Function() operation) async {
    if (!_active.add(sourceId)) {
      throw StateError('来源 $sourceId 已在扫描');
    }
    notifyListeners();
    try {
      return await operation();
    } finally {
      _active.remove(sourceId);
      if (_active.isEmpty) {
        final Completer<void>? idle = _idle;
        _idle = null;
        idle?.complete();
      }
      notifyListeners();
    }
  }

  /// 所有扫描都结束时完成；此刻已空闲则立即完成。
  Future<void> whenIdle() {
    if (isIdle) return Future<void>.value();
    return (_idle ??= Completer<void>()).future;
  }
}

/// 进程内唯一的来源扫描占用表（来源页与首页的自动扫描调度共用）。
final SourceScanActivity sourceScanActivity = SourceScanActivity();

/// 来源种类所属的功能模块；模块关掉时它的来源不自动扫描。未知种类返回 null。
ModuleId? sourceLibraryKindModule(String mediaKind) =>
    switch (SourceLibraryKind.tryParse(mediaKind)) {
      SourceLibraryKind.book => ModuleId.books,
      SourceLibraryKind.manga => ModuleId.manga,
      SourceLibraryKind.video => ModuleId.video,
      SourceLibraryKind.music => ModuleId.music,
      SourceLibraryKind.game => ModuleId.games,
      null => null,
    };

/// 自动扫描调度器：每次 [trigger] 把「开着自动扫描、到期、没在扫」的来源排进队列，
/// 再逐个串行扫。
class SourceAutoScanScheduler {
  SourceAutoScanScheduler({
    required Future<List<SourceLibraryRow>> Function() loadCandidates,
    required SourceAutoScanRunner scan,
    SourceScanActivity? activity,
    DateTime Function()? now,
    this.minInterval = kSourceAutoScanMinInterval,
  }) : _loadCandidates = loadCandidates,
       _scan = scan,
       _activity = activity ?? sourceScanActivity,
       _now = now ?? DateTime.now;

  /// 开着自动扫描、且此刻允许扫（模块开着、库可写）的来源，按来源页顺序。
  final Future<List<SourceLibraryRow>> Function() _loadCandidates;
  final SourceAutoScanRunner _scan;
  final SourceScanActivity _activity;
  final DateTime Function() _now;

  /// 同一来源两次自动扫描的最小间隔。
  final Duration minInterval;

  final Queue<int> _queue = Queue<int>();
  final Map<int, DateTime> _lastAttempt = <int, DateTime>{};
  Future<void>? _drain;
  bool _disposed = false;

  /// 队列里等着扫的来源 id（测试与诊断用）。
  List<int> get queuedSourceIds => List<int>.unmodifiable(_queue);

  /// 按 [trigger] 时机入队到期来源并开始（或接上）串行扫描；返回的 future 在这一轮
  /// 队列清空时完成。
  Future<void> trigger(SourceAutoScanTrigger trigger) async {
    if (_disposed) return;
    final List<SourceLibraryRow> candidates = await _loadCandidates();
    if (_disposed) return;
    final DateTime at = _now();
    for (final SourceLibraryRow row in candidates) {
      if (_queue.contains(row.id) || _activity.isScanning(row.id)) continue;
      if (!_isDue(row, at)) continue;
      _queue.add(row.id);
    }
    if (_queue.isEmpty) return _drain ?? Future<void>.value();
    return _drain ??= _drainQueue().whenComplete(() => _drain = null);
  }

  /// 停止调度：清空队列；正在扫的那一个照常收尾（扫描器不可中途取消）。
  void dispose() {
    _disposed = true;
    _queue.clear();
  }

  bool _isDue(SourceLibraryRow row, DateTime at) {
    final DateTime? scanned = row.lastScannedAt;
    final DateTime? attempted = _lastAttempt[row.id];
    final DateTime? last = switch ((scanned, attempted)) {
      (null, null) => null,
      (final DateTime s, null) => s,
      (null, final DateTime a) => a,
      (final DateTime s, final DateTime a) => s.isAfter(a) ? s : a,
    };
    return last == null || at.difference(last) >= minInterval;
  }

  Future<void> _drainQueue() async {
    while (_queue.isNotEmpty && !_disposed) {
      // 与手动「重新扫描」共用一条道：有人在扫就等它扫完。
      while (!_activity.isIdle) {
        await _activity.whenIdle();
      }
      if (_disposed || _queue.isEmpty) break;
      final int id = _queue.removeFirst();
      // 入队到真正开扫之间用户可能关了开关、删了来源、关了模块：按当前状态重取。
      final SourceLibraryRow? row = (await _loadCandidates())
          .where((SourceLibraryRow r) => r.id == id)
          .firstOrNull;
      if (row == null || _disposed) continue;
      // 重取那一下 await 期间手动扫描可能已经开始。
      if (!_activity.isIdle) {
        _queue.addFirst(id);
        continue;
      }
      final DateTime? previousAttempt = _lastAttempt[id];
      _lastAttempt[id] = _now();
      try {
        final SourceAutoScanOutcome outcome = await _activity.run(
          id,
          () => _scan(row),
        );
        if (outcome == SourceAutoScanOutcome.deferred) {
          // 没扫成不占节流，下一次触发再试。
          if (previousAttempt == null) {
            _lastAttempt.remove(id);
          } else {
            _lastAttempt[id] = previousAttempt;
          }
        }
      } catch (error, stack) {
        // 扫描器自己把常规失败写进 lastScanError；走到这里是意外异常。上报进错误
        // 日志，但不拖垮队列里的其它来源。
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'source auto scan',
            context: ErrorDescription('auto-scanning source $id'),
          ),
        );
      }
    }
  }
}
