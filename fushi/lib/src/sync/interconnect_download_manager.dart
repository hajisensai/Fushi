import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/platform/mobile/download_keep_alive_hub.dart';
import 'package:fushi/src/sync/interconnect_video_resume_store.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';

/// 一个互联（hibiki 互联 / LAN 对端）下载任务的生命周期状态。
///
/// [paused]：用户主动暂停，或进程被杀后从续传清单接回来的任务。`.part` 留着，
/// [InterconnectDownloadManager.resume] 从已下载的字节处接着下。
enum InterconnectDownloadStatus { running, paused, completed, failed }

/// 任务的内容域（下载中心按它选图标 / 分类）。
enum InterconnectDownloadKind { video, book, audiobook }

/// 一个互联下载任务的不可变快照。UI 只读这个渲染进度/状态。
@immutable
class InterconnectDownloadTask {
  const InterconnectDownloadTask({
    required this.id,
    required this.title,
    required this.status,
    required this.progress,
    this.kind = InterconnectDownloadKind.video,
    this.receivedBytes,
    this.totalBytes,
    this.startedAt,
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

  final InterconnectDownloadKind kind;

  /// 已落盘字节（**含续传前已有的 `.part`**）；传输原语不报字节时为 null。
  final int? receivedBytes;

  /// 总字节；服务端没给长度时为 null。
  final int? totalBytes;

  /// 任务（最近一次）开始的时刻（毫秒）；下载中心按它排序。
  final int? startedAt;

  /// 失败时的错误文本（status==failed 时非空）。
  final String? error;

  bool get isRunning => status == InterconnectDownloadStatus.running;
  bool get isPaused => status == InterconnectDownloadStatus.paused;

  InterconnectDownloadTask copyWith({
    InterconnectDownloadStatus? status,
    double? progress,
    bool clearProgress = false,
    int? receivedBytes,
    int? totalBytes,
    String? error,
    bool clearError = false,
  }) {
    return InterconnectDownloadTask(
      id: id,
      title: title,
      status: status ?? this.status,
      progress: clearProgress ? null : (progress ?? this.progress),
      kind: kind,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      startedAt: startedAt,
      error: clearError ? null : (error ?? this.error),
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

/// 一组成员任务（合集的各集）聚成的**整体**下载态，给合集卡画一枚角标用。
///
/// 只聚合[InterconnectDownloadManager.tasks] 里**有任务**的成员：用户只下了
/// 12 集里的 3 集时，分母就是 3，显示的是这 3 集的真实进度而不是稀释后的假数。
/// 批快照（[InterconnectDownloadBatch]）不能当这个数据源：它只在成员整集结束时
/// +1，长片下载全程停在 0/N；逐集手动下载又根本没有批。
@immutable
class InterconnectDownloadAggregate {
  const InterconnectDownloadAggregate({
    required this.progress,
    required this.running,
    required this.failed,
    required this.total,
  });

  /// 0..1；已完成计 1、进行中 / 暂停计其进度（首个回报前计 0）、失败计 0。
  final double progress;

  /// 有任务的成员里还在跑的个数。
  final int running;

  /// 有任务的成员里已失败的个数。
  final int failed;

  /// 有任务的成员总数（≥ 1）。
  final int total;

  bool get isRunning => running > 0;

  /// 全部结束且至少一集失败（UI 画失败角标）。
  bool get isFailed => running == 0 && failed > 0;
}

/// 执行一次实际下载到 [dest] 的原语（注入，便于测试与解耦具体 client）。
/// [onProgress] 上报 0..1 进度。书 / 有声书走这一形；它们的传输不支持中途
/// 中止，所以没有暂停。
typedef InterconnectDownloadRunner = Future<void> Function(
  File dest, {
  void Function(double progress)? onProgress,
});

/// 视频下载原语：在 [InterconnectDownloadRunner] 之上多报字节（[onBytes]，
/// received 含续传前已有的 `.part`），并接受 [cancelSignal]——它完成时传输中止、
/// 抛 [RemoteDownloadCancelled]、`.part` 留着供续传（即「暂停」）。
typedef InterconnectVideoDownloadRunner = Future<void> Function(
  File dest, {
  void Function(double progress)? onProgress,
  void Function(int received, int? total)? onBytes,
  Future<void>? cancelSignal,
});

/// 下载成功后落库/建行等收尾（注入；任一失败计入任务失败，不静默丢半成品）。
typedef InterconnectDownloadComplete = Future<void> Function(File dest);

/// 任务的「怎么再跑一次」：暂停后继续、失败后重试都靠它，不必回到发起页面。
class _DownloadSpec {
  const _DownloadSpec({
    required this.title,
    required this.kind,
    required this.dest,
    required this.run,
    required this.onComplete,
    required this.pausable,
    this.resumeRecord,
  });

  final String title;
  final InterconnectDownloadKind kind;
  final File dest;
  final InterconnectVideoDownloadRunner run;
  final InterconnectDownloadComplete? onComplete;

  /// 传输原语认 cancelSignal（视频）。书的原语不认，暂停无从谈起。
  final bool pausable;

  /// 视频任务的续传清单（null = 不落清单）。
  final InterconnectVideoResumeRecord? resumeRecord;
}

/// **app 级互联下载管理器（TODO-819）**。持有所有进行中/已完成/失败的互联下载任务，
/// 不挂任何页面 State —— 故切 tab / 退页 / 页面 dispose 时下载循环仍在本管理器里活着，
/// 页面只 `ref.watch` 订阅渲染进度。
///
/// 承载视频下载（[startVideoDownload]，底层走可续传引擎，中断留 .part 可续）与
/// 书 / 有声书下载（[startBookDownload] / [startSrtAudiobookDownload]，BUG-1693
/// 批审计：书侧此前挂在书架页 State 里，失败在离页后完全不可见）。
///
/// 进程活不过切后台是另一回事（BUG-2714）：有任务在跑时经 [DownloadKeepAlive]
/// 挂 Android 前台服务保活；真被杀了，视频任务靠与 `.part` 并排的续传清单
/// （[InterconnectVideoResumeStore]）在下次拿到远端清单时接回来。
class InterconnectDownloadManager extends ChangeNotifier {
  InterconnectDownloadManager({
    DownloadKeepAlive? keepAlive,
    int Function()? now,
  })  : _keepAlive = keepAlive,
        _now = now ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final DownloadKeepAlive? _keepAlive;
  final int Function() _now;
  bool _keepAliveActive = false;
  int _keepAliveHolds = 0;

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

  final Map<String, _DownloadSpec> _specs = <String, _DownloadSpec>{};

  /// 在跑任务的中止开关（完成 = 请求暂停）。
  final Map<String, Completer<void>> _cancelSignals =
      <String, Completer<void>>{};

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
  /// （成员自己的失败原因仍在其 [InterconnectDownloadTask.error]）。被用户暂停的
  /// 成员同样计入 failed（批只区分「落地了」与「没落地」），它自己停在暂停态。
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
    await holdKeepAliveDuring(() async {
      for (final Future<void> Function() start in starters) {
        try {
          await start();
          _updateBatch(id, completed: 1);
        } catch (_) {
          _updateBatch(id, failed: 1);
        }
      }
    });
    return _batches[id]!;
  }

  /// 串行跑多条下载的调用方（整批 [startBatch]、启动时的自动续传）用它把保活撑过
  /// 成员之间的空档：一条下完、下一条还没起的那一瞬间没有在跑的任务，若照常撤掉
  /// 前台服务，而 app 此时已在后台，Android 12+ 不允许再拉起（抛
  /// `ForegroundServiceStartNotAllowedException`），后续成员全程没有保活、进程一被
  /// 杀就断。[body] 期间不撤服务；结束后按实际状态同步一次。
  Future<T> holdKeepAliveDuring<T>(Future<T> Function() body) async {
    _keepAliveHolds++;
    try {
      return await body();
    } finally {
      _keepAliveHolds--;
      if (!_disposed) _syncKeepAlive();
    }
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
  /// （失败角标、重试判据），超出这个窗口的最旧结束态直接淘汰。running / paused
  /// 任务永不淘汰（paused 背后是一份还没下完的 `.part`）。
  static const int maxFinishedTasks = 32;

  /// 全部任务的只读视图（含 running/paused/completed/failed）。
  Map<String, InterconnectDownloadTask> get tasks =>
      Map<String, InterconnectDownloadTask>.unmodifiable(_tasks);

  /// 取某任务快照（无则 null）。
  InterconnectDownloadTask? taskFor(String id) => _tasks[id];

  /// 某任务是否正在下载（UI 决定显示进度徽标）。
  bool isRunning(String id) => _tasks[id]?.isRunning ?? false;

  /// 某任务进度（0..1 或 null=不确定）。
  double? progressFor(String id) => _tasks[id]?.progress;

  /// 该任务能否暂停（在跑且传输原语认中止信号）。
  bool canPause(String id) =>
      (_tasks[id]?.isRunning ?? false) && (_specs[id]?.pausable ?? false);

  /// 该任务能否不经发起页面直接再跑（暂停后继续 / 失败后重试）。
  bool canRestart(String id) {
    final InterconnectDownloadTask? task = _tasks[id];
    if (task == null || task.isRunning) return false;
    return task.status != InterconnectDownloadStatus.completed &&
        _specs.containsKey(id);
  }

  /// 把 [ids]（合集各成员的任务键）聚成一条整体下载态；没有任一成员有任务时
  /// 返回 null（调用方不画角标）。见 [InterconnectDownloadAggregate]。
  InterconnectDownloadAggregate? aggregateFor(Iterable<String> ids) {
    int total = 0;
    int running = 0;
    int failed = 0;
    double sum = 0;
    for (final String id in ids) {
      final InterconnectDownloadTask? task = _tasks[id];
      if (task == null) continue;
      total += 1;
      switch (task.status) {
        case InterconnectDownloadStatus.running:
          running += 1;
          sum += (task.progress ?? 0).clamp(0, 1);
        case InterconnectDownloadStatus.paused:
          sum += (task.progress ?? 0).clamp(0, 1);
        case InterconnectDownloadStatus.completed:
          sum += 1;
        case InterconnectDownloadStatus.failed:
          failed += 1;
      }
    }
    if (total == 0) return null;
    return InterconnectDownloadAggregate(
      progress: sum / total,
      running: running,
      failed: failed,
      total: total,
    );
  }

  /// 启动一个视频下载任务（键 = 裸 `RemoteVideoInfo.id`，历史键域冻结不加前缀）。
  /// 已在跑（同 [id]）则忽略重复调用，返回当前任务。
  ///
  /// [resumeRecord] 非空时在起跑前把续传清单落盘、完成后删掉、暂停时标记——
  /// 进程被杀后靠它把任务接回来。被用户暂停时抛 [RemoteDownloadCancelled]
  /// （任务停在 [InterconnectDownloadStatus.paused]）。
  Future<InterconnectDownloadTask> startVideoDownload({
    required String id,
    required String title,
    required File dest,
    required InterconnectVideoDownloadRunner run,
    InterconnectDownloadComplete? onComplete,
    InterconnectVideoResumeRecord? resumeRecord,
  }) =>
      _startDownload(
        id,
        _DownloadSpec(
          title: title,
          kind: InterconnectDownloadKind.video,
          dest: dest,
          run: run,
          onComplete: onComplete,
          pausable: true,
          resumeRecord: resumeRecord,
        ),
      );

  /// 把一个**不在跑**的视频任务以暂停态登记进来（进程重启后从续传清单接回、且
  /// 用户上次是主动暂停的）。之后 [resume] 用同一份 [run] / [onComplete] 续传。
  /// 同 [id] 已有 running / paused 任务则什么也不做。
  void registerPausedVideoDownload({
    required String id,
    required String title,
    required File dest,
    required InterconnectVideoDownloadRunner run,
    InterconnectDownloadComplete? onComplete,
    InterconnectVideoResumeRecord? resumeRecord,
    int? receivedBytes,
    int? totalBytes,
  }) {
    final InterconnectDownloadTask? existing = _tasks[id];
    if (existing != null && (existing.isRunning || existing.isPaused)) return;
    _specs[id] = _DownloadSpec(
      title: title,
      kind: InterconnectDownloadKind.video,
      dest: dest,
      run: run,
      onComplete: onComplete,
      pausable: true,
      resumeRecord: resumeRecord,
    );
    _tasks[id] = InterconnectDownloadTask(
      id: id,
      title: title,
      status: InterconnectDownloadStatus.paused,
      progress: _fraction(receivedBytes, totalBytes),
      kind: InterconnectDownloadKind.video,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
      startedAt: _now(),
    );
    _finishedOrder.remove(id);
    _notify();
  }

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
        bookTaskId(downloadId),
        _DownloadSpec(
          title: title,
          kind: InterconnectDownloadKind.book,
          dest: dest,
          run: _adaptRunner(run),
          onComplete: onComplete,
          pausable: false,
        ),
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
        srtAudiobookTaskId(identity),
        _DownloadSpec(
          title: title,
          kind: InterconnectDownloadKind.audiobook,
          dest: dest,
          run: _adaptRunner(run),
          onComplete: onComplete,
          pausable: false,
        ),
      );

  static InterconnectVideoDownloadRunner _adaptRunner(
    InterconnectDownloadRunner run,
  ) {
    return (
      File dest, {
      void Function(double progress)? onProgress,
      void Function(int received, int? total)? onBytes,
      Future<void>? cancelSignal,
    }) =>
        run(dest, onProgress: onProgress);
  }

  /// 暂停一个在跑的视频任务：发中止信号，传输原语停下并保留 `.part`，任务落到
  /// [InterconnectDownloadStatus.paused]。不可暂停（书）/ 不在跑时什么也不做。
  void pause(String id) {
    if (!canPause(id)) return;
    final Completer<void>? signal = _cancelSignals[id];
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// 继续一个暂停的任务 / 重试一个失败的任务（同一份传输原语与收尾，续传由
  /// `.part` 承接）。返回的 future 在任务结束时完成；失败 / 再次暂停不抛——
  /// 结果以任务状态为准（下载中心的按钮没有人接异常）。
  Future<void> resume(String id) async {
    if (!canRestart(id)) return;
    try {
      await _startDownload(id, _specs[id]!);
    } catch (_) {
      // 状态已落在任务快照里。
    }
  }

  /// 三个公开入口共用的任务生命周期本体。
  ///
  /// 流程：置 running（不确定进度）→ [run] 驱动下载（更新进度）→
  /// 成功调 [onComplete] 收尾（建行/下字幕）→ 标 completed；任一步失败标 failed 并存
  /// 错误；被暂停标 paused。**整个生命周期与页面无关**：页面 dispose 后任务仍在本
  /// 管理器里推进到底。
  Future<InterconnectDownloadTask> _startDownload(
    String id,
    _DownloadSpec spec,
  ) async {
    final InterconnectDownloadTask? existing = _tasks[id];
    if (existing != null && existing.isRunning) return existing;

    _specs[id] = spec;
    final Completer<void> cancel = Completer<void>();
    _cancelSignals[id] = cancel;
    final InterconnectDownloadTask started = InterconnectDownloadTask(
      id: id,
      title: spec.title,
      status: InterconnectDownloadStatus.running,
      // 继续暂停任务时先沿用暂停前的进度，首个回报（含已有 part）会立刻校正。
      progress: existing?.isPaused == true ? existing!.progress : null,
      kind: spec.kind,
      receivedBytes:
          existing?.isPaused == true ? existing!.receivedBytes : null,
      totalBytes: existing?.isPaused == true ? existing!.totalBytes : null,
      startedAt: _now(),
    );
    _tasks[id] = started;
    // 重跑同一个 id（用户重试）= 上一轮的结束态被消费掉了，从保留窗口里摘掉。
    _finishedOrder.remove(id);
    _notify();

    // 清单写入排队但**不等**：它是真实文件 IO，挡在传输前面只会拖慢起跑（widget
    // 测试的 FakeAsync 里更是永远等不到）。同一落点的写入串行，顺序即意图顺序。
    final InterconnectVideoResumeRecord? record = spec.resumeRecord;
    if (record != null) _queueRecordWrite(record.copyWith(paused: false));

    try {
      await spec.run(
        spec.dest,
        onProgress: (double progress) => _updateProgress(id, progress),
        onBytes: (int received, int? total) =>
            _updateBytes(id, received, total),
        cancelSignal: cancel.future,
      );
      if (spec.onComplete != null) await spec.onComplete!(spec.dest);
      if (record != null) _queueRecordClear(record.destPath);
      _specs.remove(id);
      _setStatus(id, InterconnectDownloadStatus.completed, progress: 1);
      return _tasks[id]!;
    } on RemoteDownloadCancelled {
      if (record != null) {
        _queueRecordWrite(
          record.copyWith(paused: true, totalBytes: _tasks[id]?.totalBytes),
        );
      }
      _setStatus(id, InterconnectDownloadStatus.paused);
      rethrow;
    } catch (e) {
      if (record != null && _tasks[id]?.totalBytes != null) {
        _queueRecordWrite(record.copyWith(totalBytes: _tasks[id]!.totalBytes));
      }
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
    } finally {
      if (identical(_cancelSignals[id], cancel)) _cancelSignals.remove(id);
    }
  }

  /// 每个落点一条清单写入链：写 / 删严格按发起顺序落盘（「起跑写 → 暂停标记 →
  /// 继续写 → 完成删」不会因为并发 IO 乱序成「删了又被旧写复活」）。
  final Map<String, Future<void>> _recordWrites = <String, Future<void>>{};

  void _queueRecordWrite(InterconnectVideoResumeRecord record) =>
      _enqueueRecordOp(
        record.destPath,
        () => InterconnectVideoResumeStore.write(record),
      );

  void _queueRecordClear(String destPath) => _enqueueRecordOp(
        destPath,
        () => InterconnectVideoResumeStore.clear(destPath),
      );

  void _enqueueRecordOp(String destPath, Future<void> Function() op) {
    final Future<void> previous =
        _recordWrites[destPath] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) => op()).catchError((Object e) {
      // 清单写不进去只丢「被杀后自动接回」这一项能力，下载本身照跑。
      debugPrint('[interconnect-download] resume manifest op failed: $e');
    }).whenComplete(() {
      if (identical(_recordWrites[destPath], next)) {
        _recordWrites.remove(destPath);
      }
    });
    _recordWrites[destPath] = next;
  }

  /// 等所有已排队的清单写入落盘（测试 / 需要读回清单的调用方用）。
  @visibleForTesting
  Future<void> flushResumeManifests() =>
      Future.wait(_recordWrites.values.toList());

  /// 移除一个已结束（completed/failed/paused）任务的记录。running 任务不移除
  /// （避免悬挂下载失去其状态槽）。移除 paused 任务 = 用户不再打算续，连带删
  /// 续传清单（`.part` 本身不删：那是 [discard] 的事）。
  void clearTask(String id) {
    final InterconnectDownloadTask? task = _tasks[id];
    if (task == null || task.isRunning) return;
    final InterconnectVideoResumeRecord? record = _specs[id]?.resumeRecord;
    if (record != null) _queueRecordClear(record.destPath);
    _tasks.remove(id);
    _specs.remove(id);
    _finishedOrder.remove(id);
    _notify();
  }

  /// 放弃一个未完成（paused/failed）的任务并删掉已下载的半成品（`.part` 与
  /// 续传清单）。返回是否真的删了文件。
  Future<bool> discard(String id) async {
    final InterconnectDownloadTask? task = _tasks[id];
    final _DownloadSpec? spec = _specs[id];
    if (task == null || task.isRunning || spec == null) return false;
    clearTask(id);
    final String destPath = spec.dest.path;
    bool deleted = false;
    for (final File f in <File>[
      File('$destPath.part'),
      File('$destPath.part.etag'),
    ]) {
      try {
        if (await f.exists()) {
          await f.delete();
          deleted = true;
        }
      } catch (e) {
        debugPrint('[interconnect-download] discard ${f.path} failed: $e');
      }
    }
    _queueRecordClear(destPath);
    await flushResumeManifests();
    return deleted;
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
      _specs.remove(evicted);
    }
  }

  void _updateProgress(String id, double progress) {
    final InterconnectDownloadTask? task = _tasks[id];
    if (task == null || !task.isRunning) return;
    _tasks[id] = task.copyWith(progress: progress.clamp(0.0, 1.0));
    _notify();
  }

  void _updateBytes(String id, int received, int? total) {
    final InterconnectDownloadTask? task = _tasks[id];
    if (task == null || !task.isRunning) return;
    final int? knownTotal = total != null && total > 0 ? total : null;
    _tasks[id] = task.copyWith(
      receivedBytes: received,
      totalBytes: knownTotal,
      progress: _fraction(received, knownTotal ?? task.totalBytes),
    );
    _notify();
  }

  static double? _fraction(int? received, int? total) {
    if (received == null || total == null || total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
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
      clearError: error == null,
    );
    if (status == InterconnectDownloadStatus.completed ||
        status == InterconnectDownloadStatus.failed) {
      _retainFinished(id);
    }
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    _syncKeepAlive();
    notifyListeners();
  }

  /// 有任务在跑就挂前台服务（通知里是进度），全停了就撤。节流 / 去重在
  /// [DownloadKeepAlive] 里做，这里每次状态变化都如实报。
  void _syncKeepAlive() {
    final DownloadKeepAlive? keepAlive = _keepAlive;
    if (keepAlive == null) return;
    final List<InterconnectDownloadTask> running = <InterconnectDownloadTask>[
      for (final InterconnectDownloadTask task in _tasks.values)
        if (task.isRunning) task,
    ];
    if (running.isEmpty) {
      // 串行下载的空档（见 [holdKeepAliveDuring]）：不撤，下一条起跑时再 update。
      if (_keepAliveHolds > 0) return;
      if (_keepAliveActive) {
        _keepAliveActive = false;
        unawaited(keepAlive.stop());
      }
      return;
    }
    _keepAliveActive = true;
    int received = 0;
    int total = 0;
    bool totalsKnown = true;
    for (final InterconnectDownloadTask task in running) {
      final int? taskTotal = task.totalBytes;
      if (taskTotal == null) {
        totalsKnown = false;
        break;
      }
      received += task.receivedBytes ?? 0;
      total += taskTotal;
    }
    final int? percent =
        totalsKnown && total > 0 ? (received * 100 ~/ total) : null;
    final String title = running.length == 1
        ? running.single.title
        : t.interconnect_download_notification_title(count: running.length);
    unawaited(keepAlive.update(
      title: title,
      text: percent == null
          ? t.download_task_status_downloading
          : '${t.download_task_status_downloading} · $percent%',
      percent: percent,
    ));
  }

  @override
  void dispose() {
    _disposed = true;
    if (_keepAliveActive) unawaited(_keepAlive?.stop());
    super.dispose();
  }
}

/// app 级单例 provider：在整个 app 生命周期内持有互联下载任务，跨页面存活。
final interconnectDownloadManagerProvider =
    ChangeNotifierProvider<InterconnectDownloadManager>(
  (ref) => InterconnectDownloadManager(
      keepAlive: downloadKeepAliveHub.lease('interconnect')),
);
