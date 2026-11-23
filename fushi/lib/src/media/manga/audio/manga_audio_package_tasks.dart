/// 有声漫画导出包的进程级后台任务表：工作台的导出 / 导入与控制通道
/// （`tts export` / `tts import-package`）都在这里起任务，同一张表——界面离开任务照跑，
/// CLI 能查到界面起的任务，反之亦然。
///
/// 任务只在内存里（几十秒到几分钟），记阶段、进度、结果、失败原因与取消。取消语义：
/// 写包 / 解包阶段随时可取消（杀掉工作 isolate、删半成品）；导入进入落库阶段
/// （[MangaAudioPackageTask.markCommitting]）后拒绝取消——半途停下会留下「书已建、
/// 成品没登记」的残局。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/audio/manga_audio_package_io.dart';

enum MangaAudioPackageTaskKind { export, import }

enum MangaAudioPackageTaskStatus { running, done, failed, cancelled }

/// 取消请求的结局。
enum MangaAudioPackageCancelOutcome { requested, committing, finished }

class MangaAudioPackageTask extends ChangeNotifier {
  MangaAudioPackageTask._({
    required this.id,
    required this.kind,
    required this.path,
    required this.createdAt,
  });

  final String id;
  final MangaAudioPackageTaskKind kind;

  /// 导出的目标文件 / 导入的包文件。
  final String path;
  final int createdAt;
  final MangaPackageCancelToken cancelToken = MangaPackageCancelToken();

  MangaAudioPackageTaskStatus status = MangaAudioPackageTaskStatus.running;

  /// 当前阶段（`collecting` / `hashing` / `writing` / `extracting` / `verifying` /
  /// `importing`）。
  String? phase;

  /// 0..1；null = 不确定。
  double? progress;
  bool _committing = false;

  /// 结束时的结果（导出：文件与各卷摘要；导入：逐卷结局）。
  Map<String, Object?>? result;

  /// 失败原因码与说明。
  String? errorCode;
  String? error;
  List<String> errorDetails = const <String>[];

  final Completer<void> _done = Completer<void>();

  bool get isTerminal => status != MangaAudioPackageTaskStatus.running;
  bool get committing => _committing;
  Future<void> get whenDone => _done.future;

  void report(String phase, [double? progress]) {
    if (isTerminal) return;
    this.phase = phase;
    this.progress = progress?.clamp(0.0, 1.0);
    notifyListeners();
  }

  void markCommitting() {
    _committing = true;
    notifyListeners();
  }

  void _settle() {
    phase = null;
    progress = null;
    _done.complete();
    notifyListeners();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'taskId': id,
    'kind': kind.name,
    'path': path,
    'status': status.name,
    if (phase != null && !isTerminal) 'phase': phase,
    if (progress != null && !isTerminal)
      'progress': (progress! * 1000).round() / 10,
    'cancellable': !isTerminal && !_committing,
    if (result != null) 'result': result,
    if (errorCode != null) 'code': errorCode,
    if (error != null) 'error': error,
    if (errorDetails.isNotEmpty) 'details': errorDetails,
    'createdAt': createdAt,
  };
}

class MangaAudioPackageTasks extends ChangeNotifier {
  MangaAudioPackageTasks({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 进程级唯一任务表。
  static final MangaAudioPackageTasks instance = MangaAudioPackageTasks();

  /// 只保留最近这么多个已结束的任务。
  static const int kMaxFinished = 20;

  final DateTime Function() _now;
  final List<MangaAudioPackageTask> _tasks = <MangaAudioPackageTask>[];
  int _seq = 0;

  List<MangaAudioPackageTask> get tasks =>
      List<MangaAudioPackageTask>.unmodifiable(_tasks);

  MangaAudioPackageTask? byId(String id) {
    for (final MangaAudioPackageTask task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// 正在写 [path] 的导出任务（同一个目标文件不并发写）。
  MangaAudioPackageTask? activeExportTo(String path) {
    for (final MangaAudioPackageTask task in _tasks) {
      if (task.kind == MangaAudioPackageTaskKind.export &&
          p.equals(task.path, path) &&
          !task.isTerminal) {
        return task;
      }
    }
    return null;
  }

  /// 起一个任务并立即返回；[run] 的返回值落 [MangaAudioPackageTask.result]。
  /// [run] 抛 [MangaAudioPackageCancelled] = 取消；[MangaAudioPackageException] = 失败
  /// （带原因码）；别的异常 = 失败（`internal`）。
  ///
  /// 同一个目标文件已有导出在写时同步抛 [MangaAudioPackageException]
  /// （`export_running`）：两个任务往同一个 `.part` 写会互相毁掉对方的包。判据放在
  /// 任务表这里，界面与控制通道起任务都过这一道。
  MangaAudioPackageTask start({
    required MangaAudioPackageTaskKind kind,
    required String path,
    required Future<Map<String, Object?>> Function(MangaAudioPackageTask task)
    run,
  }) {
    if (kind == MangaAudioPackageTaskKind.export &&
        activeExportTo(path) != null) {
      throw MangaAudioPackageException('export_running', '已经在往 $path 导出');
    }
    final int now = _now().millisecondsSinceEpoch;
    final MangaAudioPackageTask task = MangaAudioPackageTask._(
      id: 'manga-pkg-${kind.name}-$now-${_seq++}',
      kind: kind,
      path: path,
      createdAt: now,
    );
    _tasks.add(task);
    _trimFinished();
    notifyListeners();
    unawaited(() async {
      try {
        task.result = await run(task);
        task.status = MangaAudioPackageTaskStatus.done;
      } on MangaAudioPackageCancelled {
        task.status = MangaAudioPackageTaskStatus.cancelled;
      } on MangaAudioPackageException catch (e) {
        task
          ..status = MangaAudioPackageTaskStatus.failed
          ..errorCode = e.code
          ..error = e.message
          ..errorDetails = e.details;
      } on Object catch (e) {
        task
          ..status = MangaAudioPackageTaskStatus.failed
          ..errorCode = 'internal'
          ..error = '$e';
      } finally {
        task._settle();
        notifyListeners();
      }
    }());
    return task;
  }

  MangaAudioPackageCancelOutcome cancel(MangaAudioPackageTask task) {
    if (task.isTerminal) return MangaAudioPackageCancelOutcome.finished;
    if (task.committing) return MangaAudioPackageCancelOutcome.committing;
    task.cancelToken.cancel();
    return MangaAudioPackageCancelOutcome.requested;
  }

  void _trimFinished() {
    final List<MangaAudioPackageTask> finished = <MangaAudioPackageTask>[
      for (final MangaAudioPackageTask t in _tasks)
        if (t.isTerminal) t,
    ];
    final int extra = finished.length - kMaxFinished;
    for (int i = 0; i < extra; i++) {
      _tasks.remove(finished[i]);
    }
  }
}
