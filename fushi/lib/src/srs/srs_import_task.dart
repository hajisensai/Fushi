/// 复习（SRS）Anki 包导入的后台任务（BUG-3549）。
///
/// 范式照词典下载的 `DictionaryDownloadController`：app 级常驻控制器（不绑页面生命周期）+
/// 可观察状态 + 结束时由控制器统一提示。用户发起导入后可以关掉对话框、离开牌组列表继续用
/// app；牌组列表顶上有任务条显示进度，完成 / 失败弹全局提示，完成后牌组列表自动重读。
///
/// - [SrsImportController]：串行队列（同一时刻只跑一个导入：导入按批事务写库，两个导入并发
///   只会互相排队等事务，没有收益）。任务开始前就锁定目标 store / 媒体目录，中途切 profile
///   不会写到别的 profile。
/// - [startSrsBackgroundImport]：UI「导入」与「Anki 一键迁移」共用的入口。
///
/// 数据库并发：导入每批（约千条事件）一个事务，批与批之间让出连接，复习页的评分等写入
/// 排在批之间完成（Drift 单连接 + WAL，事务互斥）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/utils.dart';

/// 一个导入任务的状态。[cancelled]：排队中被取消（一行没写），或运行中被叫停（引擎在两批
/// 之间停下，已落库的完整笔记保留，重导同一份来源幂等补齐）。
enum SrsImportTaskStatus { queued, running, done, failed, cancelled }

/// 任务被用户取消（[SrsImportTask.result] 以它结束）。
class SrsImportCancelledException implements Exception {
  const SrsImportCancelledException();

  @override
  String toString() => 'SrsImportCancelledException';
}

/// 执行一次导入（测试注入假实现；缺省 [importAnkiPackageFile]，媒体落 [SrsMediaStore]）。
typedef SrsAnkiImportRunner =
    Future<SrsImportReport> Function({
      required SrsDbStore store,
      required SrsMediaStore media,
      required File file,
      required SrsAnkiImportOptions options,
      required void Function(double progress) onProgress,
      required bool Function() shouldStop,
    });

Future<SrsImportReport> _defaultRunner({
  required SrsDbStore store,
  required SrsMediaStore media,
  required File file,
  required SrsAnkiImportOptions options,
  required void Function(double progress) onProgress,
  required bool Function() shouldStop,
}) => importAnkiPackageFile(
  store: store,
  file: file,
  storeMedia: (String name, Uint8List bytes) => media.store(name, bytes),
  options: options,
  onProgress: onProgress,
  shouldStop: shouldStop,
);

/// 一次导入的执行体：只管写库并上报进度（store / 媒体目录在入队时已锁定进闭包）。
/// [shouldStop] 返回 true 时应在两批之间停下并抛 [SrsImportStopped]。
typedef SrsImportJob =
    Future<SrsImportReport> Function(
      void Function(double progress) onProgress,
      bool Function() shouldStop,
    );

/// 一个后台导入任务。
class SrsImportTask {
  SrsImportTask._({
    required this.id,
    required this.displayName,
    required SrsImportJob job,
    Future<void> Function()? cleanup,
  }) : _job = job,
       _cleanup = cleanup;

  final int id;

  /// 界面上显示的名字（缺省文件名）。
  final String displayName;
  final SrsImportJob _job;

  /// 结束（成功或失败）后的收尾：删迁移导出的临时包 / 丢弃 Anki 集合快照目录。
  final Future<void> Function()? _cleanup;

  /// 0..1；0 = 还没有进度（显示不定态）。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  SrsImportTaskStatus _status = SrsImportTaskStatus.queued;
  SrsImportTaskStatus get status => _status;

  /// 成功时的导入报告。
  SrsImportReport? report;

  /// 失败原因。
  Object? error;

  final Completer<SrsImportReport> _done = Completer<SrsImportReport>();

  /// 任务结束：成功给报告，失败抛原异常（如 [SrsImportException]）。
  Future<SrsImportReport> get result => _done.future;

  bool get isFinished =>
      _status == SrsImportTaskStatus.done ||
      _status == SrsImportTaskStatus.failed ||
      _status == SrsImportTaskStatus.cancelled;

  bool _stopRequested = false;

  /// 运行中已请求停止、引擎还没在批间停下。
  bool get stopping => _status == SrsImportTaskStatus.running && _stopRequested;

  /// 能不能取消：排队中，或运行中且还没请求过停止。
  bool get canCancel =>
      _status == SrsImportTaskStatus.queued ||
      (_status == SrsImportTaskStatus.running && !_stopRequested);
}

/// 后台导入的串行队列（app 级，见库注释）。
class SrsImportController extends ChangeNotifier {
  SrsImportController({
    required void Function() onDataChanged,
    void Function(SrsImportTask task)? onFinished,
    SrsAnkiImportRunner? runner,
  }) : _onDataChanged = onDataChanged,
       _onFinished = onFinished,
       _runner = runner ?? _defaultRunner;

  final void Function() _onDataChanged;
  final void Function(SrsImportTask task)? _onFinished;
  final SrsAnkiImportRunner _runner;

  final List<SrsImportTask> _tasks = <SrsImportTask>[];
  int _nextId = 1;
  bool _pumping = false;
  bool _disposed = false;

  /// 全部任务（排队 / 运行中 / 已结束未关掉的），按发起顺序。
  List<SrsImportTask> get tasks => List<SrsImportTask>.unmodifiable(_tasks);

  /// 有没有还没结束的任务。
  bool get busy => _tasks.any((SrsImportTask t) => !t.isFinished);

  /// 排一个导入；立即返回任务（结果见 [SrsImportTask.result]）。
  SrsImportTask enqueue({
    required SrsDbStore store,
    required SrsMediaStore media,
    required File file,
    SrsAnkiImportOptions options = const SrsAnkiImportOptions(),
    String? displayName,
    bool deleteFileWhenDone = false,
  }) {
    return enqueueJob(
      displayName: displayName ?? file.uri.pathSegments.last,
      job:
          (
            void Function(double progress) onProgress,
            bool Function() shouldStop,
          ) => _runner(
            store: store,
            media: media,
            file: file,
            options: options,
            onProgress: onProgress,
            shouldStop: shouldStop,
          ),
      cleanup: deleteFileWhenDone
          ? () async {
              try {
                await file.delete();
              } on FileSystemException {
                // 临时包删不掉（被占用）：留给系统临时目录清理。
              }
            }
          : null,
    );
  }

  /// 排一个不是单个包文件的导入（Anki 一键迁移的本机集合快照）。[cleanup] 在任务结束
  /// （成功或失败）后、[SrsImportTask.result] 完成前执行。
  SrsImportTask enqueueJob({
    required String displayName,
    required SrsImportJob job,
    Future<void> Function()? cleanup,
  }) {
    final SrsImportTask task = SrsImportTask._(
      id: _nextId++,
      displayName: displayName,
      job: job,
      cleanup: cleanup,
    );
    // 失败由控制器提示；没人 await result 时也不能变成未处理的异步错误。
    task.result.ignore();
    _tasks.add(task);
    _notify();
    unawaited(_pump());
    return task;
  }

  /// 取消一个任务（任务条上的「取消」），[SrsImportTask.result] 以
  /// [SrsImportCancelledException] 结束，行留在任务条上显示「已取消」，由用户关掉。
  /// - 排队中：不再开始跑，收尾（删临时包 / 丢快照）照常执行。
  /// - 运行中：请求停止（[SrsImportTask.stopping]），引擎在两批之间停下（已落库的完整
  ///   笔记保留），之后照常收尾、列表重读。返回时任务可能还没停下。
  /// 已结束 / 已请求过停止的返回 false。
  Future<bool> cancel(SrsImportTask task) async {
    if (!task.canCancel || !_tasks.contains(task)) return false;
    if (task._status == SrsImportTaskStatus.running) {
      task._stopRequested = true;
      _notify();
      return true;
    }
    // 先改状态：_pump 只挑 queued 的任务，改完它就不会再被拿去跑。
    task._status = SrsImportTaskStatus.cancelled;
    _notify();
    await _runCleanup(task);
    task.error = const SrsImportCancelledException();
    task._done.completeError(const SrsImportCancelledException());
    _notify();
    _reportFinished(task);
    return true;
  }

  /// 从列表里移除一个已结束的任务（任务条上的「关闭」）。
  void dismiss(SrsImportTask task) {
    if (!task.isFinished) return;
    if (_tasks.remove(task)) {
      task.progress.dispose();
      _notify();
    }
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final SrsImportTask? next = _tasks
            .where((SrsImportTask t) => t._status == SrsImportTaskStatus.queued)
            .firstOrNull;
        if (next == null) return;
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(SrsImportTask task) async {
    task._status = SrsImportTaskStatus.running;
    _notify();
    SrsImportReport? report;
    Object? error;
    StackTrace? errorStack;
    bool stopped = false;
    try {
      report = await task._job((double p) {
        if (!_disposed) task.progress.value = p.clamp(0.0, 1.0);
      }, () => task._stopRequested);
    } on SrsImportStopped {
      stopped = true;
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsImportController', e, stack);
      error = e;
      errorStack = stack;
    }
    // 收尾（删临时包 / 丢快照）做完才算任务结束：result 完成时临时文件已不在。
    await _runCleanup(task);
    if (stopped) {
      task.error = const SrsImportCancelledException();
      task._status = SrsImportTaskStatus.cancelled;
      task._done.completeError(const SrsImportCancelledException());
    } else if (report != null) {
      task.report = report;
      task._status = SrsImportTaskStatus.done;
      task._done.complete(report);
    } else {
      task.error = error;
      task._status = SrsImportTaskStatus.failed;
      task._done.completeError(error!, errorStack);
    }
    // 失败 / 叫停也可能已写入一部分批次：一样让列表重读。
    if (!_disposed) {
      _onDataChanged();
      _notify();
    }
    _reportFinished(task);
  }

  Future<void> _runCleanup(SrsImportTask task) async {
    final Future<void> Function()? cleanup = task._cleanup;
    if (cleanup == null) return;
    try {
      await cleanup();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsImportController.cleanup', e, stack);
    }
  }

  /// 通知外部「任务结束了」（全局提示）。这是控制器之外的回调：它抛异常不能顺着 [_run]
  /// 冒到 [_pump] 里把整条队列停掉（后面排队的导入永远不开始），所以在这里隔离——记进
  /// 错误日志，队列照常往下走。
  void _reportFinished(SrsImportTask task) {
    final void Function(SrsImportTask task)? onFinished = _onFinished;
    if (_disposed || onFinished == null) return;
    try {
      onFinished(task);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsImportController.onFinished', e, stack);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 一个任务结束时的全局提示（离开了牌组列表也看得到）。
void showSrsImportFinishedToast(SrsImportTask task) {
  // 取消是用户刚在任务条上点的，行本身就显示「已取消」，不再另弹提示。
  if (task.status == SrsImportTaskStatus.cancelled) return;
  if (task.status == SrsImportTaskStatus.done) {
    FushiToast.show(
      msg: t.srs_import_task_done(
        name: task.displayName,
        n: task.report?.notesAdded ?? 0,
      ),
      severity: ToastSeverity.success,
      toastLength: Toast.LENGTH_LONG,
    );
  } else {
    FushiToast.show(
      msg: t.srs_import_task_failed(name: task.displayName),
      severity: ToastSeverity.error,
      toastLength: Toast.LENGTH_LONG,
    );
  }
}

/// 进程内唯一的后台导入控制器（根容器里常驻，不随页面销毁）。
final Provider<SrsImportController> srsImportControllerProvider =
    Provider<SrsImportController>((Ref ref) {
      final SrsImportController c = SrsImportController(
        onDataChanged: () => ref.read(srsRevisionProvider.notifier).state++,
        onFinished: showSrsImportFinishedToast,
      );
      ref.onDispose(c.dispose);
      return c;
    });

/// 后台导入入口（牌组列表「导入」与「Anki 一键迁移」共用）。
///
/// 解析当前 profile 的 store 与媒体目录后排进 [srsImportControllerProvider]，立即返回任务；
/// 复习模块关着 / store 打不开时返回 null（调用方提示失败）。[deleteFileWhenDone] 给迁移流程
/// 导出的临时包用：任务结束后删掉。等结果用 `task.result`（失败抛原异常）。
Future<SrsImportTask?> startSrsBackgroundImport(
  WidgetRef ref, {
  required File file,
  SrsAnkiImportOptions options = const SrsAnkiImportOptions(),
  String? displayName,
  bool deleteFileWhenDone = false,
}) async {
  final SrsDbStore? store = await readSrsStore(ref);
  SrsMediaStore? media;
  try {
    media = await ref.read(srsMediaStoreProvider.future);
  } catch (e, stack) {
    ErrorLogService.instance.log('startSrsBackgroundImport.media', e, stack);
  }
  if (store == null || media == null) return null;
  return ref
      .read(srsImportControllerProvider)
      .enqueue(
        store: store,
        media: media,
        file: file,
        options: options,
        displayName: displayName,
        deleteFileWhenDone: deleteFileWhenDone,
      );
}
