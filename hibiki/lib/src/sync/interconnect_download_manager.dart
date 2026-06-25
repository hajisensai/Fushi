import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// 本波只承载视频下载（[startVideoDownload]）；底层走可续传引擎，中断留 .part 可续。
/// 书 / 有声书 / 前台服务通知为后续波次，不在此实现。
class InterconnectDownloadManager extends ChangeNotifier {
  InterconnectDownloadManager();

  final Map<String, InterconnectDownloadTask> _tasks =
      <String, InterconnectDownloadTask>{};
  bool _disposed = false;

  /// 全部任务的只读视图（含 running/completed/failed）。
  Map<String, InterconnectDownloadTask> get tasks =>
      Map<String, InterconnectDownloadTask>.unmodifiable(_tasks);

  /// 取某任务快照（无则 null）。
  InterconnectDownloadTask? taskFor(String id) => _tasks[id];

  /// 某任务是否正在下载（UI 决定显示进度徽标）。
  bool isRunning(String id) => _tasks[id]?.isRunning ?? false;

  /// 某任务进度（0..1 或 null=不确定）。
  double? progressFor(String id) => _tasks[id]?.progress;

  /// 启动一个视频下载任务。已在跑（同 [id]）则忽略重复调用，返回当前任务。
  ///
  /// 流程：置 running（不确定进度）→ [run] 驱动下载（走可续传引擎，更新进度）→
  /// 成功调 [onComplete] 收尾（建行/下字幕）→ 标 completed；任一步失败标 failed 并存
  /// 错误。**整个生命周期与页面无关**：页面 dispose 后任务仍在本管理器里推进到底。
  Future<InterconnectDownloadTask> startVideoDownload({
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
        error: e.toString(),
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
    _notify();
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
