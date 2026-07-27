/// mokuro.moe 卷下载队列：app 生命周期常驻（挂 [AppModel]，懒建），「在线目录」
/// 对话框与「下载」页任务 tab 共同观察同一实例——对话框只负责 enqueue，关闭
/// 对话框**不**中断下载（统一下载中心语义，与 torrent 任务同级可见）。
///
/// 执行模型与原对话框内联队列一致：顺序一次一卷（mokuro.moe 是社区托管小站，
/// 不做并发）；区别于旧「失败即停整队」，后台队列语义是单卷失败/取消只标记
/// 该任务、继续下一卷。下载编排复用 [MokuroMoeVolumeDownloader]，断点续传
/// 语义不变：失败/取消保留 `.part`，同卷重新入队即续传。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_volume_downloader.dart';

/// 测试注入口：替换真实 [MokuroMoeVolumeDownloader.run]（测试绕网络/DB）。
typedef MokuroMoeVolumeRunner = Stream<MokuroMoeVolumeDownloadEvent> Function({
  required String seriesName,
  required String volumeName,
});

/// 单个卷任务的生命周期状态。
enum MokuroMoeTaskStatus { queued, running, done, failed, cancelled }

/// 队列中的一个卷下载任务（可变快照；变更经队列 [MokuroMoeDownloadQueue]
/// 的 notifyListeners 广播）。
class MokuroMoeDownloadTask {
  MokuroMoeDownloadTask._({required this.seriesName, required this.volumeName});

  final String seriesName;
  final String volumeName;

  MokuroMoeTaskStatus status = MokuroMoeTaskStatus.queued;

  /// 最近一次下载事件（阶段/字节/页进度），UI 据此渲染进度。
  MokuroMoeVolumeDownloadEvent? lastEvent;

  /// 失败原因（status == failed 时非空）。
  String? error;

  /// 入库 bookKey（status == done 且真的新建行时非空）。
  String? bookKey;

  /// 该卷已在库、导入被静默跳过（视作成功但无新行）。
  bool skippedExisting = false;

  /// 入库标题（与导入侧同源派生，书架身份 key 的输入）。
  String get title =>
      MokuroMoeVolumeDownloader.volumeTitle(seriesName, volumeName);

  bool get isFinished =>
      status == MokuroMoeTaskStatus.done ||
      status == MokuroMoeTaskStatus.failed ||
      status == MokuroMoeTaskStatus.cancelled;
}

/// 顺序执行的 mokuro.moe 卷下载队列。
class MokuroMoeDownloadQueue extends ChangeNotifier {
  MokuroMoeDownloadQueue({
    required HibikiDatabase db,
    required MokuroMoeClient Function() clientFactory,
    @visibleForTesting MokuroMoeVolumeRunner? runnerOverride,
  })  : _db = db,
        _clientFactory = clientFactory,
        _runnerOverride = runnerOverride;

  final HibikiDatabase _db;
  final MokuroMoeClient Function() _clientFactory;
  final MokuroMoeVolumeRunner? _runnerOverride;

  final List<MokuroMoeDownloadTask> _tasks = <MokuroMoeDownloadTask>[];

  MokuroMoeDownloadTask? _running;
  MokuroMoeVolumeDownloader? _activeDownloader;
  StreamSubscription<MokuroMoeVolumeDownloadEvent>? _sub;
  bool _disposed = false;

  /// 累计成功新建行的卷数（书架刷新信号：监听方比对增量后失效书架 provider）。
  int _importedCount = 0;
  int get importedCount => _importedCount;

  List<MokuroMoeDownloadTask> get tasks =>
      List<MokuroMoeDownloadTask>.unmodifiable(_tasks);

  /// 当前执行中的任务（无则 null）。
  MokuroMoeDownloadTask? get runningTask => _running;

  bool get hasUnfinished =>
      _tasks.any((MokuroMoeDownloadTask t) => !t.isFinished);

  int get finishedCount =>
      _tasks.where((MokuroMoeDownloadTask t) => t.isFinished).length;

  int get totalCount => _tasks.length;

  /// 该卷是否已排队/执行中（对话框据此禁用复选框，防重复入队）。
  bool isPending(String seriesName, String volumeName) =>
      _tasks.any((MokuroMoeDownloadTask t) =>
          !t.isFinished &&
          t.seriesName == seriesName &&
          t.volumeName == volumeName);

  /// 查找该卷的未完成任务（对话框渲染行内进度用）。
  MokuroMoeDownloadTask? pendingTask(String seriesName, String volumeName) {
    for (final MokuroMoeDownloadTask t in _tasks) {
      if (!t.isFinished &&
          t.seriesName == seriesName &&
          t.volumeName == volumeName) {
        return t;
      }
    }
    return null;
  }

  /// 入队若干卷（保持传入顺序）；已排队/执行中的同卷去重。返回实际新增数。
  int enqueue({
    required String seriesName,
    required List<String> volumeNames,
  }) {
    int added = 0;
    for (final String volume in volumeNames) {
      if (isPending(seriesName, volume)) continue;
      _tasks.add(
          MokuroMoeDownloadTask._(seriesName: seriesName, volumeName: volume));
      added++;
    }
    if (added > 0) {
      notifyListeners();
      _pump();
    }
    return added;
  }

  /// 取消一个任务：排队中→直接移除；执行中→请求下载器中止（`.part` 保留，
  /// 供下次同卷续传）。已结束的任务是 no-op。
  void cancel(MokuroMoeDownloadTask task) {
    if (task.isFinished) return;
    if (identical(task, _running)) {
      final MokuroMoeVolumeDownloader? downloader = _activeDownloader;
      if (downloader != null) {
        downloader.cancel();
      } else {
        // 注入 runner（测试）没有 cancel 通道：掐订阅按取消收尾。
        unawaited(_sub?.cancel());
        _finish(task, error: const MokuroMoeDownloadCancelled());
      }
      return;
    }
    _tasks.remove(task);
    notifyListeners();
  }

  /// 清掉所有已结束任务（下载页「清除已完成」）。
  void clearFinished() {
    final int before = _tasks.length;
    _tasks.removeWhere((MokuroMoeDownloadTask t) => t.isFinished);
    if (_tasks.length != before) notifyListeners();
  }

  void _pump() {
    if (_disposed || _running != null) return;
    MokuroMoeDownloadTask? next;
    for (final MokuroMoeDownloadTask t in _tasks) {
      if (t.status == MokuroMoeTaskStatus.queued) {
        next = t;
        break;
      }
    }
    if (next == null) return;
    final MokuroMoeDownloadTask task = next;
    task.status = MokuroMoeTaskStatus.running;
    _running = task;

    final Stream<MokuroMoeVolumeDownloadEvent> stream;
    final MokuroMoeVolumeRunner? runner = _runnerOverride;
    if (runner != null) {
      _activeDownloader = null;
      stream = runner(seriesName: task.seriesName, volumeName: task.volumeName);
    } else {
      final MokuroMoeVolumeDownloader downloader =
          MokuroMoeVolumeDownloader(client: _clientFactory());
      _activeDownloader = downloader;
      stream = downloader.run(
        db: _db,
        seriesName: task.seriesName,
        volumeName: task.volumeName,
      );
    }
    _sub = stream.listen(
      (MokuroMoeVolumeDownloadEvent event) {
        task.lastEvent = event;
        if (event.stage == MokuroMoeDownloadStage.done) {
          task.bookKey = event.bookKey;
          task.skippedExisting = event.skippedExisting;
        }
        notifyListeners();
      },
      onError: (Object e) => _finish(task, error: e),
      onDone: () => _finish(task),
    );
    notifyListeners();
  }

  /// 任务收尾（onError 后流仍会 onDone：以 `_running` 身份判重，只收一次）。
  void _finish(MokuroMoeDownloadTask task, {Object? error}) {
    if (!identical(task, _running)) return;
    _running = null;
    _activeDownloader = null;
    _sub = null;
    if (error is MokuroMoeDownloadCancelled) {
      task.status = MokuroMoeTaskStatus.cancelled;
    } else if (error != null) {
      task.status = MokuroMoeTaskStatus.failed;
      task.error = '$error';
    } else if (task.lastEvent?.stage == MokuroMoeDownloadStage.done) {
      task.status = MokuroMoeTaskStatus.done;
      if (!task.skippedExisting && task.bookKey != null) _importedCount++;
    } else {
      // 流没走到 done 就结束（如注入 runner 提前关流）：按取消处理。
      task.status = MokuroMoeTaskStatus.cancelled;
    }
    if (_disposed) return;
    notifyListeners();
    _pump();
  }

  @override
  void dispose() {
    _disposed = true;
    _activeDownloader?.cancel();
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
