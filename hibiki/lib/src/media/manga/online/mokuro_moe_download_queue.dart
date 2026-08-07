/// mokuro.moe 卷下载队列：app 生命周期常驻（挂 [AppModel]，懒建），「在线目录」
/// 对话框与「下载」页任务 tab 共同观察同一实例——对话框只负责 enqueue，关闭
/// 对话框**不**中断下载（统一下载中心语义，与 torrent 任务同级可见）。
///
/// 执行模型与原对话框内联队列一致：顺序一次一卷（mokuro.moe 是社区托管小站，
/// 不做并发）；区别于旧「失败即停整队」，后台队列语义是单卷失败/取消只标记
/// 该任务、继续下一卷。下载编排复用 [MokuroMoeVolumeDownloader]，断点续传
/// 语义不变：失败/取消保留 `.part`，同卷重新入队即续传。
///
/// 重试语义（自动 + 手动）都是**就地复活同一个任务对象**，不新建行：任务在列表
/// 里的位置、身份不变，失败行不会变成一条僵尸残留 + 一条新任务。续传由
/// downloader 的 `.part` 保证，重试不重下已到的字节。
/// - 自动：网络类瞬时失败（连接超时/连接重置/TLS/5xx/429）按 [kMokuroMoeRetryBackoff]
///   退避重排，退避期间状态是 [MokuroMoeTaskStatus.waitingRetry]，**不占执行位**
///   ——队列继续跑后面的卷，到期再回 queued 参与调度。
/// - 手动：[MokuroMoeDownloadQueue.retry] 让 failed/cancelled 任务回 queued，
///   并把自动重试计数清零（用户的一次点击 = 一轮新的自动重试预算）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_client.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_volume_downloader.dart';

/// 自动重试的退避梯度；**长度即最大自动重试次数**。
///
/// 首次退避短（2s：抖动/瞬断，站点多半马上就回来），后面拉长（8s/20s：站点
/// 过载或本机网络出问题，密集重试只会加重）。总计约 30s，超过还失败就交给
/// 用户手动重试——继续机械重试对社区小站没有礼貌，也帮不上忙。
const List<Duration> kMokuroMoeRetryBackoff = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 8),
  Duration(seconds: 20),
];

/// 测试注入口：替换真实 [MokuroMoeVolumeDownloader.run]（测试绕网络/DB）。
typedef MokuroMoeVolumeRunner = Stream<MokuroMoeVolumeDownloadEvent> Function({
  required String seriesName,
  required String volumeName,
});

/// 单个卷任务的生命周期状态。
///
/// [waitingRetry] 是「失败了但还会自己回来」——不是终态（[MokuroMoeDownloadTask.isFinished]
/// 为 false，不会被「清除已完成」扫掉），也不被 `_pump` 选中执行。
enum MokuroMoeTaskStatus {
  queued,
  running,
  waitingRetry,
  done,
  failed,
  cancelled
}

/// 队列中的一个卷下载任务（可变快照；变更经队列 [MokuroMoeDownloadQueue]
/// 的 notifyListeners 广播）。
class MokuroMoeDownloadTask {
  MokuroMoeDownloadTask._({required this.seriesName, required this.volumeName});

  final String seriesName;
  final String volumeName;

  MokuroMoeTaskStatus status = MokuroMoeTaskStatus.queued;

  /// 最近一次下载事件（阶段/字节/页进度），UI 据此渲染进度。
  MokuroMoeVolumeDownloadEvent? lastEvent;

  /// 失败原因（status == failed / waitingRetry 时非空）。
  String? error;

  /// 已消耗的自动重试次数（0 = 还没自动重试过）。手动 [MokuroMoeDownloadQueue.retry]
  /// 归零，所以用户点一次重试就重新拿到完整的自动重试预算。
  int autoRetries = 0;

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
    @visibleForTesting List<Duration>? retryBackoffOverride,
  })  : _db = db,
        _clientFactory = clientFactory,
        _runnerOverride = runnerOverride,
        _retryBackoff = retryBackoffOverride ?? kMokuroMoeRetryBackoff;

  final HibikiDatabase _db;
  final MokuroMoeClient Function() _clientFactory;
  final MokuroMoeVolumeRunner? _runnerOverride;
  final List<Duration> _retryBackoff;

  final List<MokuroMoeDownloadTask> _tasks = <MokuroMoeDownloadTask>[];

  /// 退避中的重试定时器（任务可并存多个：A 在退避时队列继续跑 B，B 也可能失败）。
  final Map<MokuroMoeDownloadTask, Timer> _retryTimers =
      <MokuroMoeDownloadTask, Timer>{};

  MokuroMoeDownloadTask? _running;
  MokuroMoeVolumeDownloader? _activeDownloader;
  StreamSubscription<MokuroMoeVolumeDownloadEvent>? _sub;
  bool _disposed = false;

  /// 单个任务最多自动重试几次（超过就落 failed，等用户手动重试）。
  int get maxAutoRetries => _retryBackoff.length;

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

  /// 取消一个任务：排队中/退避重试中→直接移除；执行中→请求下载器中止（`.part`
  /// 保留，供下次同卷续传）。已结束的任务是 no-op。
  void cancel(MokuroMoeDownloadTask task) {
    if (task.isFinished) return;
    // 退避中的任务先掐掉定时器，否则到期回调还会把它推回 queued。
    _retryTimers.remove(task)?.cancel();
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

  /// 手动重试一个失败/已取消的任务：**就地**把它复活成排队态（不新建任务行，
  /// 列表位置与身份不变——否则失败行会作为僵尸残留，同名任务重复占位）。
  ///
  /// 自动重试计数清零：用户的显式点击重新给满预算。`.part` 仍在，实际是续传，
  /// 不重下已到的字节。已成功/仍在进行中的任务是 no-op。
  void retry(MokuroMoeDownloadTask task) {
    if (task.status != MokuroMoeTaskStatus.failed &&
        task.status != MokuroMoeTaskStatus.cancelled) {
      return;
    }
    _resetForRetry(task);
    task.status = MokuroMoeTaskStatus.queued;
    task.autoRetries = 0;
    notifyListeners();
    _pump();
  }

  /// 重试一切失败/取消的任务（下载页批量入口）。返回真正复活的任务数。
  int retryAllFailed() {
    int revived = 0;
    for (final MokuroMoeDownloadTask task in _tasks) {
      if (task.status != MokuroMoeTaskStatus.failed &&
          task.status != MokuroMoeTaskStatus.cancelled) {
        continue;
      }
      _resetForRetry(task);
      task.status = MokuroMoeTaskStatus.queued;
      task.autoRetries = 0;
      revived++;
    }
    if (revived > 0) {
      notifyListeners();
      _pump();
    }
    return revived;
  }

  /// 清空上一轮的失败/进度残留（状态由调用方置），保证重跑的 UI 从干净起点开始。
  void _resetForRetry(MokuroMoeDownloadTask task) {
    task.error = null;
    task.lastEvent = null;
    task.bookKey = null;
    task.skippedExisting = false;
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
      task.error = '$error';
      // 网络瞬断（mokuro.moe 是社区小站，连接超时是常态）自己退避重来；
      // 排不上自动重试的才落终态 failed，等用户手动重试。
      task.status = _scheduleAutoRetry(task, error)
          ? MokuroMoeTaskStatus.waitingRetry
          : MokuroMoeTaskStatus.failed;
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

  /// 安排一次自动重试；返回 false 表示这个错误/这个任务不该再自动重试。
  ///
  /// 退避期间任务是 [MokuroMoeTaskStatus.waitingRetry]：不占执行位，队列立刻
  /// 去跑下一卷；到期后回 queued 参与正常调度（而不是插队抢跑）。
  bool _scheduleAutoRetry(MokuroMoeDownloadTask task, Object error) {
    if (_disposed) return false;
    if (task.autoRetries >= _retryBackoff.length) return false;
    if (!_isTransientError(error)) return false;

    final Duration delay = _retryBackoff[task.autoRetries];
    task.autoRetries++;
    // 进度归零：重跑会从 `.part` 续传点重新报字节，留着旧事件会让 UI 停在
    // 一个不再对应任何下载的进度上。
    task.lastEvent = null;
    _retryTimers[task] = Timer(delay, () {
      _retryTimers.remove(task);
      // 期间被取消/清掉/手动重试过就不要再插手。
      if (_disposed || task.status != MokuroMoeTaskStatus.waitingRetry) return;
      task.status = MokuroMoeTaskStatus.queued;
      notifyListeners();
      _pump();
    });
    return true;
  }

  /// 值得自动重试的错误 = 「再来一次可能就好了」的瞬时故障。
  ///
  /// 网络/传输层（连接超时、连接重置、DNS 抖动、TLS 握手失败）一律算；HTTP 只认
  /// 5xx/408/429（[MokuroMoeHttpException.isTransient]），404/403 这类稳定结论
  /// 重试纯属白等。zip 校验失败、解包失败、路径穿越等本地/数据错误不自动重试
  /// ——重跑同一份坏数据不会变好，交给用户手动决定。
  static bool _isTransientError(Object error) {
    if (error is MokuroMoeHttpException) return error.isTransient;
    return error is SocketException ||
        error is TimeoutException ||
        error is TlsException ||
        error is HttpException;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final Timer timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _activeDownloader?.cancel();
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
