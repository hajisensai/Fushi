/// 来源「自动扫描」（拍板台 C_8oheua0H / ICOLa6LZLU / enSm2GOuFA，维护者拍板）。
///
/// - **开关每来源一个**（`media_sources.auto_scan`，schema v157），默认关；书 / 有声书
///   （书籍来源里的音频 + 字幕组）/ 漫画 / 视频 / 音乐 / 游戏全部来源种类都支持——它们
///   本来就走同一个 [SourceLibraryScanner.scan]。
/// - **触发 = app 启动 + 回到前台**（拍板选项 A）。不做文件系统监听：Android SAF、iOS
///   沙箱与 WebDAV / SFTP / FTP / AList 网络来源都监听不了，五端行为会分裂；启动 / 回
///   前台在五端一致，iOS 也能用。
/// - **限流**：
///   1. 同一时刻只扫一个来源——自动扫描之间串行，并与所有手动扫描入口共用
///      [SourceScanActivity] 这一条道：[SourceLibraryScanner.scan] 自己登记进这把每来源
///      锁，任何扫描在跑时自动扫描排在后面，同一来源被两个入口同时扫时后到的等前一个；
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
import 'package:fushi/src/media/source_library/source_library_scanner.dart'
    show SourceLibraryScanner, SourceScanSummary;
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

  /// 列目录阶段：已列完 [dirPath]，累计找到 [filesFound] 个文件。
  void reportListing(int sourceId, String dirPath, int filesFound) {
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

  /// 已出队、还没扫完的来源（出队后要 await 重取候选，这段窗口里它既不在 [_queue]
  /// 也可能还没进 [_activity]；没有这个登记，重叠的 [trigger] 会把它再入队、连扫两遍）。
  int? _inFlight;
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
      if (_queue.contains(row.id) ||
          _inFlight == row.id ||
          _activity.isScanning(row.id)) {
        continue;
      }
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
      _inFlight = id;
      try {
        await _scanDequeued(id);
      } finally {
        _inFlight = null;
      }
    }
  }

  Future<void> _scanDequeued(int id) async {
    // 入队到真正开扫之间用户可能关了开关、删了来源、关了模块：按当前状态重取。
    final SourceLibraryRow? row = (await _loadCandidates())
        .where((SourceLibraryRow r) => r.id == id)
        .firstOrNull;
    if (row == null || _disposed) return;
    // 重取那一下 await 期间别的入口可能已经开始扫。
    if (!_activity.isIdle) {
      _queue.addFirst(id);
      return;
    }
    // 排队期间它可能刚被手动扫过（lastScannedAt 已更新）：按最新状态再判一次到期。
    if (!_isDue(row, _now())) return;
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

/// 自动扫描的候选过滤：库「已迁移只读」时一个都不扫；所属模块关掉的来源不扫；未知
/// 种类不扫。
List<SourceLibraryRow> autoScanEligibleSources(
  Iterable<SourceLibraryRow> rows, {
  required bool readonly,
  required bool Function(ModuleId module) isModuleEnabled,
}) {
  if (readonly) return const <SourceLibraryRow>[];
  return <SourceLibraryRow>[
    for (final SourceLibraryRow row in rows)
      if (sourceLibraryKindModule(row.mediaKind) case final ModuleId module
          when isModuleEnabled(module))
        row,
  ];
}

/// 自动扫描一个来源的收尾分支（首页 `_runAutoSourceScan` 装配依赖后调这里）：
///
/// - 非视频来源：直接 [scan]，算 scanned；
/// - 视频来源：经 [tryRunVideoScan]（刮削任务控制器的门，与联网刮削互斥）；门被手动
///   刮削 / 清理占着（返回 null）→ deferred，留给下一次触发；
/// - 视频扫完：这轮真的新增了视频才 [onVideoScanCreated]（串联「扫描后自动刮削」），
///   没新增只 [onVideoScanNoNew]（刷新视频库），不把整个来源送去联网刮削。
Future<SourceAutoScanOutcome> runAutoSourceScan(
  SourceLibraryRow source, {
  required Future<SourceScanSummary> Function() scan,
  required Future<SourceScanSummary>? Function(
    int sourceId,
    Future<SourceScanSummary> Function() scan,
  )
  tryRunVideoScan,
  required Future<void> Function(SourceScanSummary summary) onVideoScanCreated,
  required void Function() onVideoScanNoNew,
}) async {
  if (source.mediaKind != SourceLibraryKind.video.dbValue) {
    await scan();
    return SourceAutoScanOutcome.scanned;
  }
  final Future<SourceScanSummary>? started = tryRunVideoScan(source.id, scan);
  if (started == null) return SourceAutoScanOutcome.deferred;
  final SourceScanSummary summary = await started;
  if (summary.createdVideoUids.isEmpty) {
    onVideoScanNoNew();
  } else {
    await onVideoScanCreated(summary);
  }
  return SourceAutoScanOutcome.scanned;
}
