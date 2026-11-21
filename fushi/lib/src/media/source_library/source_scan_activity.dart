/// 来源扫描占用表与扫描进度（[SourceScanActivity] / [sourceScanActivity]）。
///
/// 从 `source_auto_scan.dart` 拆出的叶子文件：扫描器（`source_library_scanner.dart`）、
/// 扫描临时目录清理（`source_scan_temp.dart`）只需要这把每来源锁与进度表，不该为此
/// import 自动扫描调度器（它反过来 import 扫描器）。原先 `source_scan_temp → source_auto_scan
/// → source_library_scanner` 这条边把 `source_scan_temp` 拖进了 lib/ 最大 import 环
/// （`test/build/import_cycle_guard_test.dart`）。`source_auto_scan.dart` 照旧 re-export 本文件。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// 来源扫描占用表 + 每来源互斥锁：哪些来源此刻正在被扫（手动或自动）。
///
/// [SourceLibraryScanner.scan] 自己经 [run] 登记，所以**所有**扫描入口（来源页「重新
/// 扫描」、曲库页重扫、音乐来源重扫、ctl 路由、添加文件夹、自动扫描）都过这一把锁：
/// 同一来源不会被两个入口并发扫（后到的等前一个扫完再扫）；来源页行级 loading 能看到
/// 别处发起的扫描；自动扫描在任何扫描期间排队（[whenIdle]）。
///
/// [run] 可重入：在某个来源的 [run] 里（同一 zone 链上）再对同一来源 [run]，直接执行，
/// 不等自己——调度器 / 来源页先登记、内层扫描器再登记是常态。
class SourceScanActivity extends ChangeNotifier {
  SourceScanActivity({
    this.progressPublishInterval = kSourceScanProgressPublishInterval,
  });

  final Map<int, Completer<void>> _active = <int, Completer<void>>{};
  Completer<void>? _idle;

  /// 每个在扫来源的最新进度（拍板台 design-nmv-scan-progress）。只在 [run] 持锁期间
  /// 有值，锁一放就清。
  final Map<int, SourceScanProgress> _progress = <int, SourceScanProgress>{};
  final _SourceScanProgressNotifier _progressNotifier =
      _SourceScanProgressNotifier();

  /// 进度通知的最小间隔；测试把进程级单例调成 [Duration.zero] 以逐条观察进度。
  @visibleForTesting
  Duration progressPublishInterval;

  /// 发布后的冷却期：期间的报告只记 [_progressDirty]，冷却结束补发一次最新值。
  Timer? _progressCooldown;
  bool _progressDirty = false;

  /// zone 值：当前 zone 链上已持有锁的来源 id（只在本实例内有意义）。
  late final Object _heldKey = Object();

  /// 没有任何来源在扫。
  bool get isIdle => _active.isEmpty;

  /// [sourceId] 正在被扫。
  bool isScanning(int sourceId) => _active.containsKey(sourceId);

  /// 此刻正在扫的来源 id 快照。
  Set<int> get activeSourceIds => Set<int>.unmodifiable(_active.keys.toSet());

  /// 持有 [sourceId] 的锁执行 [operation]。同一来源正被别的入口扫时先等它扫完；当前
  /// zone 已持有这把锁（嵌套调用）时直接执行。
  Future<T> run<T>(int sourceId, Future<T> Function() operation) async {
    final Set<int> held =
        (Zone.current[_heldKey] as Set<int>?) ?? const <int>{};
    if (held.contains(sourceId)) return operation();
    for (
      Completer<void>? other = _active[sourceId];
      other != null;
      other = _active[sourceId]
    ) {
      await other.future;
    }
    final Completer<void> done = Completer<void>();
    _active[sourceId] = done;
    notifyListeners();
    try {
      return await runZoned(
        operation,
        zoneValues: <Object?, Object?>{
          _heldKey: <int>{...held, sourceId},
        },
      );
    } finally {
      _active.remove(sourceId);
      if (_progress.remove(sourceId) != null) _publishProgress();
      done.complete();
      if (_active.isEmpty) {
        final Completer<void>? idle = _idle;
        _idle = null;
        idle?.complete();
      }
      notifyListeners();
    }
  }

  /// [run] 的不等待版：[sourceId] 此刻没人持锁时持锁执行 [operation]；已被持有（含
  /// 当前 zone 自己持有——调用方正在扫这个来源）时**不执行**、返回 null。
  ///
  /// 给「动这个来源但不能等扫描」的维护动作用（启动残留清扫删临时来源行）：拿到锁就
  /// 做，期间到来的扫描排在后面；拿不到说明有人正在扫它，留到下次。判定与占锁之间没有
  /// await，不会和 [run] 同时进入。
  Future<T>? tryRun<T>(int sourceId, Future<T> Function() operation) {
    if (_active.containsKey(sourceId)) return null;
    return run(sourceId, operation);
  }

  /// 所有扫描都结束时完成；此刻已空闲则立即完成。
  Future<void> whenIdle() {
    if (isIdle) return Future<void>.value();
    return (_idle ??= Completer<void>()).future;
  }

  /// 进度变化的通知（与占用变化的 [addListener] 分开：进度一秒几次，占用表的监听方
  /// 要做「谁刚扫完」的对账，不该被进度刷屏）。发布节流到 [kSourceScanProgressPublishInterval]
  /// 一次，扫描结束那一下立即发布。
  Listenable get progressListenable => _progressNotifier;

  /// [sourceId] 此刻的扫描进度；没在扫、或扫描器还没报过进度时为 null。
  SourceScanProgress? progressOf(int sourceId) => _progress[sourceId];

  /// 列目录阶段：开始列 [dirPath]，此前累计找到 [filesFound] 个文件。
  ///
  /// 阶段只进不退：进入导入阶段后文件系统的列目录回调（远端来源导书失败后的连通性
  /// 探测、非递归来源逐卷现场列漫画目录）不再算列目录进度，否则导入计数被冲成
  /// 「已找到 0 个文件」且之后的 [reportImportItem] 全被丢弃。
  void reportListing(int sourceId, String dirPath, int filesFound) {
    if (_progress[sourceId]?.phase == SourceScanPhase.importing) return;
    _report(
      sourceId,
      SourceScanProgress.listing(filesFound: filesFound, currentPath: dirPath),
    );
  }

  /// 进入导入阶段：本轮计划要逐个过一遍的条目共 [total] 个。
  void beginImport(int sourceId, int total) {
    _report(sourceId, SourceScanProgress.importing(processed: 0, total: total));
  }

  /// 导入阶段：开始处理 [path] 这一条（已在库跳过的也算处理过）。计数封顶在
  /// [beginImport] 给的总数——收尾阶段（HLS 清单里展开的流、合订本回收）会再过几条。
  void reportImportItem(int sourceId, String path) {
    final SourceScanProgress? current = _progress[sourceId];
    if (current == null || current.phase != SourceScanPhase.importing) return;
    final int processed = current.processed + 1;
    _report(
      sourceId,
      SourceScanProgress.importing(
        processed: processed > current.total ? current.total : processed,
        total: current.total,
        currentPath: path,
      ),
    );
  }

  void _report(int sourceId, SourceScanProgress progress) {
    // 锁外的报告（扫描器被测试直接调内部入口、锁已放掉的迟到回调）不登记：进度只描述
    // 正在持锁的那一次扫描。
    if (!_active.containsKey(sourceId)) return;
    _progress[sourceId] = progress;
    if (_progressCooldown != null) {
      _progressDirty = true;
      return;
    }
    _publishProgress();
  }

  /// 立即发布并进入冷却期（[progressPublishInterval] 为零时不冷却，逐条发布）。
  void _publishProgress() {
    _progressDirty = false;
    _progressCooldown?.cancel();
    _progressCooldown = progressPublishInterval == Duration.zero
        ? null
        : Timer(progressPublishInterval, _onProgressCooldownEnd);
    _progressNotifier.publish();
  }

  void _onProgressCooldownEnd() {
    _progressCooldown = null;
    if (_progressDirty) _publishProgress();
  }

  @override
  void dispose() {
    _progressCooldown?.cancel();
    _progressNotifier.dispose();
    super.dispose();
  }
}

/// 进度行里显示的路径：去掉尾部分隔符后的最后一段（来源条目路径已解码，WebDAV 目录
/// 带尾斜杠）。根目录 `/` 返回空串，调用方只显示计数。
String scanProgressPathLabel(String path) {
  String trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') || trimmed.endsWith(r'\'))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final int sep = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  return sep >= 0 ? trimmed.substring(sep + 1) : trimmed;
}

/// 进度发布的最小间隔：大库列目录一秒能报几百个目录，逐个通知会让来源页每帧重建。
const Duration kSourceScanProgressPublishInterval = Duration(milliseconds: 200);

class _SourceScanProgressNotifier extends ChangeNotifier {
  void publish() => notifyListeners();
}

/// 一次来源扫描的阶段。
enum SourceScanPhase {
  /// 遍历来源目录、收集文件清单（总量未知）。
  listing,

  /// 按清单逐条入库（总量已知）。
  importing,
}

/// 一次来源扫描的进度快照（来源页行内显示「已找到 N 个文件 · 当前目录」/「正在导入
/// i / n · 当前条目」）。音乐、游戏来源由 Rust / 专用扫描器整段完成，不报进度。
@immutable
class SourceScanProgress {
  const SourceScanProgress.listing({required this.filesFound, this.currentPath})
    : phase = SourceScanPhase.listing,
      processed = 0,
      total = 0;

  const SourceScanProgress.importing({
    required this.processed,
    required this.total,
    this.currentPath,
  }) : phase = SourceScanPhase.importing,
       filesFound = 0;

  final SourceScanPhase phase;

  /// 列目录阶段累计找到的文件数。
  final int filesFound;

  /// 导入阶段已开始处理的条目数（封顶 [total]）。
  final int processed;

  /// 导入阶段的条目总数。
  final int total;

  /// 正在列的目录 / 正在处理的条目路径。
  final String? currentPath;

  /// 导入阶段的完成比例；列目录阶段总量未知，返回 null（不定进度条）。
  double? get fraction => phase == SourceScanPhase.importing && total > 0
      ? processed / total
      : null;

  @override
  bool operator ==(Object other) =>
      other is SourceScanProgress &&
      other.phase == phase &&
      other.filesFound == filesFound &&
      other.processed == processed &&
      other.total == total &&
      other.currentPath == currentPath;

  @override
  int get hashCode =>
      Object.hash(phase, filesFound, processed, total, currentPath);

  @override
  String toString() =>
      'SourceScanProgress($phase, found: $filesFound, '
      '$processed/$total, $currentPath)';
}

/// 进程内唯一的来源扫描占用表（来源页与首页的自动扫描调度共用）。
final SourceScanActivity sourceScanActivity = SourceScanActivity();
