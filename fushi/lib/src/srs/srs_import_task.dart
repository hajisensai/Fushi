/// 复习（SRS）Anki 包导入的后台任务（BUG-3520）。
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

/// 一个导入任务的状态。
enum SrsImportTaskStatus { queued, running, done, failed }

/// 执行一次导入（测试注入假实现；缺省 [importAnkiPackageFile]，媒体落 [SrsMediaStore]）。
typedef SrsAnkiImportRunner =
    Future<SrsImportReport> Function({
      required SrsDbStore store,
      required SrsMediaStore media,
      required File file,
      required SrsAnkiImportOptions options,
      required void Function(double progress) onProgress,
    });

Future<SrsImportReport> _defaultRunner({
  required SrsDbStore store,
  required SrsMediaStore media,
  required File file,
  required SrsAnkiImportOptions options,
  required void Function(double progress) onProgress,
}) => importAnkiPackageFile(
  store: store,
  file: file,
  storeMedia: (String name, Uint8List bytes) => media.store(name, bytes),
  options: options,
  onProgress: onProgress,
);

/// 一次导入的执行体：只管写库并上报进度（store / 媒体目录在入队时已锁定进闭包）。
typedef SrsImportJob =
    Future<SrsImportReport> Function(void Function(double progress) onProgress);

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
      _status == SrsImportTaskStatus.failed;
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
      job: (void Function(double progress) onProgress) => _runner(
        store: store,
        media: media,
        file: file,
        options: options,
        onProgress: onProgress,
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
    try {
      report = await task._job((double p) {
        if (!_disposed) task.progress.value = p.clamp(0.0, 1.0);
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsImportController', e, stack);
      error = e;
      errorStack = stack;
    }
    // 收尾（删临时包 / 丢快照）做完才算任务结束：result 完成时临时文件已不在。
    final Future<void> Function()? cleanup = task._cleanup;
    if (cleanup != null) {
      try {
        await cleanup();
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsImportController.cleanup', e, stack);
      }
    }
    if (report != null) {
      task.report = report;
      task._status = SrsImportTaskStatus.done;
      task._done.complete(report);
    } else {
      task.error = error;
      task._status = SrsImportTaskStatus.failed;
      task._done.completeError(error!, errorStack);
    }
    // 失败也可能已写入一部分批次：一样让列表重读。
    if (!_disposed) {
      _onDataChanged();
      _notify();
      _onFinished?.call(task);
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
