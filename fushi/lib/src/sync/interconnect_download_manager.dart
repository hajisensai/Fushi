import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';

/// 一个互联（hibiki 互联 / LAN 对端）下载任务的生命周期状态。
enum InterconnectDownloadStatus { running, completed, failed }

/// 一个互联下载任务的不可变快照。UI 只读这个渲染进度/状态。
@immutable
class InterconnectDownloadTask {
  const InterconnectDownloadTask({
    required this.id,
    required this.title,
    required this.status,
    required this.progress,
    this.error,
  });

  /// 稳定任务键（视频用 RemoteVideoInfo.id；与列表去重键一致）。
  final String id;

  /// 展示标题。
  final String title;

  /// 当前生命周期状态。
  final InterconnectDownloadStatus status;

  /// 0..1 进度；首个 onProgress 前为 null（不确定进度）。
  final double? progress;

  /// 失败时的错误文本（status==failed 时非空）。
  final String? error;

  bool get isRunning => status == InterconnectDownloadStatus.running;

  InterconnectDownloadTask copyWith({
    InterconnectDownloadStatus? status,
    double? progress,
    bool clearProgress = false,
    String? error,
  }) {
    return InterconnectDownloadTask(
      id: id,
      title: title,
      status: status ?? this.status,
      progress: clearProgress ? null : (progress ?? this.progress),
      error: error ?? this.error,
    );
  }
}

/// 一批互联下载（合集整体下载）的进度快照。成员任务本身仍各自记在
/// [InterconnectDownloadManager.tasks] 里；批只记「排了几个、完成几个、失败几个」。
@immutable
class InterconnectDownloadBatch {
  const InterconnectDownloadBatch({
    required this.id,
    required this.title,
    required this.total,
    this.completed = 0,
    this.failed = 0,
  });

  /// 批键（合集用 [InterconnectDownloadManager.collectionBatchId]）。
  final String id;

  /// 展示标题（合集名）。
  final String title;

  final int total;
  final int completed;
  final int failed;

  int get finished => completed + failed;
  bool get isRunning => finished < total;

  InterconnectDownloadBatch copyWith({int? completed, int? failed}) {
    return InterconnectDownloadBatch(
      id: id,
      title: title,
      total: total,
      completed: completed ?? this.completed,
      failed: failed ?? this.failed,
    );
  }
}

/// 执行一次实际下载到 [dest] 的原语（注入，便于测试与解耦具体 client）。
/// [onProgress] 上报 0..1 进度。
typedef InterconnectDownloadRunner = Future<void> Function(
  File dest, {
  void Function(double progress)? onProgress,
});

/// 下载成功后落库/建行等收尾（注入；任一失败计入任务失败，不静默丢半成品）。
typedef InterconnectDownloadComplete = Future<void> Function(File dest);

/// **app 级互联下载管理器（TODO-819）**。持有所有进行中/已完成/失败的互联下载任务，
/// 不挂任何页面 State —— 故切 tab / 退页 / 页面 dispose 时下载循环仍在本管理器里活着，
/// 页面只 `ref.watch` 订阅渲染进度。
///
/// 承载视频下载（[startVideoDownload]，底层走可续传引擎，中断留 .part 可续）与
/// 书 / 有声书下载（[startBookDownload] / [startSrtAudiobookDownload]，BUG-1693
/// 批审计：书侧此前挂在书架页 State 里，失败在离页后完全不可见）。前台服务通知
/// 为后续波次，不在此实现。
class InterconnectDownloadManager extends ChangeNotifier {
  InterconnectDownloadManager();

  /// 书域任务键（BUG-1693 批审计）：书任务与视频任务同居一张 [_tasks] 表——视频
  /// 键是 `RemoteVideoInfo.id`、书键是 `RemoteBookInfo.downloadId`（= host 的
  /// `bookKey ?? title`），两个值域互不设防，域前缀隔离避免撞键。UI 查书任务
  /// 状态必须经同一派生函数，不得手拼前缀。
  static String bookTaskId(String downloadId) => 'book:$downloadId';

  /// 纯 SRT（standalone）远端有声书任务键（身份 = uid，与书 downloadId 又是一个
  /// 不同值域，再隔一个域前缀）。
  static String srtAudiobookTaskId(String identity) => 'srt:$identity';

  /// 合集整体下载的批键（本地 `media_collections.id`）。
  static String collectionBatchId(int collectionId) =>
      'collection:$collectionId';

  final Map<String, InterconnectDownloadTask> _tasks =
      <String, InterconnectDownloadTask>{};

  final Map<String, InterconnectDownloadBatch> _batches =
      <String, InterconnectDownloadBatch>{};

  /// 取某批快照（无则 null）。
  InterconnectDownloadBatch? batchFor(String id) => _batches[id];

  /// 某批是否还在跑（UI 决定合集卡是否显示批进度）。
  bool isBatchRunning(String id) => _batches[id]?.isRunning ?? false;

  /// **串行**跑一批下载（合集整体下载）。每个 [starters] 项自己调
  /// [startVideoDownload] / [startBookDownload]（目标路径、传输原语、收尾登记都
  /// 由调用方在排队前解析好，启动器不再依赖页面 State——页面 dispose 后批照跑）。
  ///
  /// 串行是有意的：互联 host 是单台设备、客户端多为移动端，同时开 N 条 Range 流
  /// 只会互抢带宽并让每条都看起来卡住；成员失败不中断后续成员，失败计入批快照
  /// （成员自己的失败原因仍在其 [InterconnectDownloadTask.error]）。
  /// 同 [id] 已在跑则忽略重复调用，返回当前批。
  Future<InterconnectDownloadBatch> startBatch({
    required String id,
    required String title,
    required List<Future<void> Function()> starters,
  }) async {
    final InterconnectDownloadBatch? existing = _batches[id];
    if (existing != null && existing.isRunning) return existing;
    _batches[id] = InterconnectDownloadBatch(
      id: id,
      title: title,
      total: starters.length,
    );
    _notify();
    for (final Future<void> Function() start in starters) {
      try {
        await start();
        _updateBatch(id, completed: 1);
      } catch (_) {
        _updateBatch(id, failed: 1);
      }
    }
    return _batches[id]!;
  }

  void _updateBatch(String id, {int completed = 0, int failed = 0}) {
    final InterconnectDownloadBatch? batch = _batches[id];
    if (batch == null) return;
    _batches[id] = batch.copyWith(
      completed: batch.completed + completed,
      failed: batch.failed + failed,
    );
    _notify();
  }

  /// 已结束（completed/failed）任务的**完成顺序**，用于有界保留（BUG-1561）。
  /// Dart 的 Map 迭代序是首次插入序，覆写同 key 不会把它挪到末尾，所以顺序得自己记。
  final List<String> _finishedOrder = <String>[];
  bool _disposed = false;

  /// 已结束任务的保留上限（BUG-1561）。此前 [_tasks] 只增不减：一次会话里下载/重试
  /// 过的每个条目都永久占一格，进程活多久就攒多久。结束态只对「刚发生的事」有意义
  /// （失败角标、重试判据），超出这个窗口的最旧结束态直接淘汰。running 任务永不淘汰。
  static const int maxFinishedTasks = 32;

  /// 全部任务的只读视图（含 running/completed/failed）。
  Map<String, InterconnectDownloadTask> get tasks =>
      Map<String, InterconnectDownloadTask>.unmodifiable(_tasks);

  /// 取某任务快照（无则 null）。
  InterconnectDownloadTask? taskFor(String id) => _tasks[id];

  /// 某任务是否正在下载（UI 决定显示进度徽标）。
  bool isRunning(String id) => _tasks[id]?.isRunning ?? false;

  /// 某任务进度（0..1 或 null=不确定）。
  double? progressFor(String id) => _tasks[id]?.progress;

  /// 启动一个视频下载任务（键 = 裸 `RemoteVideoInfo.id`，历史键域冻结不加前缀）。
  /// 已在跑（同 [id]）则忽略重复调用，返回当前任务。
  Future<InterconnectDownloadTask> startVideoDownload({
    required String id,
    required String title,
    required File dest,
    required InterconnectDownloadRunner run,
    InterconnectDownloadComplete? onComplete,
  }) =>
      _startDownload(
        id: id,
        title: title,
        dest: dest,
        run: run,
        onComplete: onComplete,
      );

  /// 启动一个远端书下载任务（EPUB / 漫画包，含随书有声书；键 = [bookTaskId]）。
  /// 已在跑（同 [downloadId]）则忽略重复调用，返回当前任务。
  Future<InterconnectDownloadTask> startBookDownload({
    required String downloadId,
    required String title,
    required File dest,
    required InterconnectDownloadRunner run,
    InterconnectDownloadComplete? onComplete,
  }) =>
      _startDownload(
        id: bookTaskId(downloadId),
        title: title,
        dest: dest,
        run: run,
        onComplete: onComplete,
      );

  /// 启动一个纯 SRT（standalone）远端有声书下载任务（键 = [srtAudiobookTaskId]）。
  /// 已在跑（同 [identity]）则忽略重复调用，返回当前任务。
  Future<InterconnectDownloadTask> startSrtAudiobookDownload({
    required String identity,
    required String title,
    required File dest,
    required InterconnectDownloadRunner run,
    InterconnectDownloadComplete? onComplete,
  }) =>
      _startDownload(
        id: srtAudiobookTaskId(identity),
        title: title,
        dest: dest,
        run: run,
        onComplete: onComplete,
      );

  /// 三个公开入口共用的任务生命周期本体。
  ///
  /// 流程：置 running（不确定进度）→ [run] 驱动下载（更新进度）→
  /// 成功调 [onComplete] 收尾（建行/下字幕）→ 标 completed；任一步失败标 failed 并存
  /// 错误。**整个生命周期与页面无关**：页面 dispose 后任务仍在本管理器里推进到底。
  Future<InterconnectDownloadTask> _startDownload({
    required String id,
    required String title,
    required File dest,
    required InterconnectDownloadRunner run,
    InterconnectDownloadComplete? onComplete,
  }) async {
    final InterconnectDownloadTask? existing = _tasks[id];
    if (existing != null && existing.isRunning) return existing;

    final InterconnectDownloadTask started = InterconnectDownloadTask(
      id: id,
      title: title,
      status: InterconnectDownloadStatus.running,
      progress: null,
    );
    _tasks[id] = started;
    // 重跑同一个 id（用户重试）= 上一轮的结束态被消费掉了，从保留窗口里摘掉。
    _finishedOrder.remove(id);
    _notify();

    try {
      await run(
        dest,
        onProgress: (double progress) => _updateProgress(id, progress),
      );
      if (onComplete != null) await onComplete(dest);
      _setStatus(id, InterconnectDownloadStatus.completed, progress: 1);
      return _tasks[id]!;
    } catch (e) {
      _setStatus(
        id,
        InterconnectDownloadStatus.failed,
        // BUG-1693：存**用户可读**的失败原因（对端离线 → 「无法连接配对设备…」），
        // 不是 `SocketException: OS Error: … errno = 1225` 这类原始异常文本——
        // 它会被失败角标 tooltip 原样上屏。未知错误 friendlySyncErrorDetail
        // 回落原文，不吞信息。
        error: friendlySyncErrorDetail(e),
      );
      rethrow;
    }
  }

  /// 移除一个已结束（completed/failed）任务的记录。running 任务不移除（避免悬挂下载
  /// 失去其状态槽）。
  void clearTask(String id) {
    final InterconnectDownloadTask? task = _tasks[id];
    if (task == null || task.isRunning) return;
    _tasks.remove(id);
    _finishedOrder.remove(id);
    _notify();
  }

  /// 把 [id] 记进结束窗口并淘汰最旧的溢出项（BUG-1561）。
  void _retainFinished(String id) {
    _finishedOrder
      ..remove(id)
      ..add(id);
    while (_finishedOrder.length > maxFinishedTasks) {
      final String evicted = _finishedOrder.removeAt(0);
      final InterconnectDownloadTask? task = _tasks[evicted];
      // 理论上不会命中 running（只有结束时才进这个表），但真撞上就留着它的状态槽。
      if (task != null && task.isRunning) continue;
      _tasks.remove(evicted);
    }
  }

  void _updateProgress(String id, double progress) {
    final InterconnectDownloadTask? task = _tasks[id];
    if (task == null) return;
    _tasks[id] = task.copyWith(progress: progress.clamp(0.0, 1.0));
    _notify();
  }

  void _setStatus(
    String id,
    InterconnectDownloadStatus status, {
    double? progress,
    String? error,
  }) {
    final InterconnectDownloadTask? task = _tasks[id];
    if (task == null) return;
    _tasks[id] = task.copyWith(
      status: status,
      progress: progress,
      error: error,
    );
    if (status != InterconnectDownloadStatus.running) _retainFinished(id);
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// app 级单例 provider：在整个 app 生命周期内持有互联下载任务，跨页面存活。
final interconnectDownloadManagerProvider =
    ChangeNotifierProvider<InterconnectDownloadManager>(
  (ref) => InterconnectDownloadManager(),
);
