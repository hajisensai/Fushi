/// 有声漫画导出包的进程级后台任务表：工作台的导出 / 导入与控制通道
/// （`tts export` / `tts import-package`）都在这里起任务，同一张表——界面离开任务照跑，
/// CLI 能查到界面起的任务，反之亦然。
///
/// 任务只在内存里（几十秒到几分钟），记阶段、进度、结果、失败原因与取消。取消语义：
/// 写包 / 解包阶段随时可取消（杀掉工作 isolate、删半成品）；导入进入落库阶段
/// （[MangaAudioPackageTask.markCommitting]）后拒绝取消——半途停下会留下「书已建、
/// 成品没登记」的残局。
///
/// 导入任务从起任务那一刻到结束都「占住」它要写的卷（[MangaAudioPackageTask.claims]：
/// 本机已有的卷按书键、要新建的卷按内容签名，新建出来后再补上书键）。卷忙不忙的唯一
/// 判据（`manga_audio_volume_busy.dart`）据此把「正在导入」算进去：标注 / 生成 / 导出 /
/// 再导入都不能碰正在导入的卷；同一个包、或要写同一卷的两次导入不能并发（否则两边都
/// 判「新建」、各建一卷重复的）。
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

  /// 导入任务占住的卷（[mangaPackageBookClaim] / [mangaPackageContentClaim]）；导出为空。
  final Set<String> _claims = <String>{};
  Set<String> get claims => Set<String>.unmodifiable(_claims);

  /// 导入新建出一卷后补占它的书键（建好到这次导入结束之间别处也不能碰它）。
  void claimVolume(String bookKey) {
    if (isTerminal) return;
    _claims.add(mangaPackageBookClaim(bookKey));
  }

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

/// 导入任务占住本机已有的一卷（按书键）。
String mangaPackageBookClaim(String bookKey) => 'book:$bookKey';

/// 导入任务占住包里要新建的一卷（按页数与 OCR 的内容签名：同一卷不管在哪个包里都一样）。
String mangaPackageContentClaim(String contentSignature) =>
    'content:$contentSignature';

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

  /// 正在导入、占住了 [bookKey] 这一卷的任务（[except] = 不算这个任务自己）。
  MangaAudioPackageTask? importingVolume(
    String bookKey, {
    MangaAudioPackageTask? except,
  }) {
    final String claim = mangaPackageBookClaim(bookKey);
    for (final MangaAudioPackageTask task in _tasks) {
      if (task.kind == MangaAudioPackageTaskKind.import &&
          !task.isTerminal &&
          !identical(task, except) &&
          task._claims.contains(claim)) {
        return task;
      }
    }
    return null;
  }

  /// 与「导入 [path]、占住 [claims]」冲突的在跑导入：同一个包文件，或要写同一卷。
  MangaAudioPackageTask? activeImportOverlapping(
    String path,
    Set<String> claims,
  ) {
    for (final MangaAudioPackageTask task in _tasks) {
      if (task.kind != MangaAudioPackageTaskKind.import || task.isTerminal) {
        continue;
      }
      if (p.equals(task.path, path) || task._claims.any(claims.contains)) {
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
  ///
  /// 导入任务带上它要写的卷 [claims]（`mangaPackageImportClaims`）：与在跑的导入是
  /// 同一个包、或占住的卷有重叠时同步抛 [MangaAudioPackageException]
  /// （`import_running`）——判据与占卷在同一个同步段里，两次导入不会都判成可以。
  MangaAudioPackageTask start({
    required MangaAudioPackageTaskKind kind,
    required String path,
    required Future<Map<String, Object?>> Function(MangaAudioPackageTask task)
    run,
    Set<String> claims = const <String>{},
  }) {
    if (kind == MangaAudioPackageTaskKind.export &&
        activeExportTo(path) != null) {
      throw MangaAudioPackageException('export_running', '已经在往 $path 导出');
    }
    if (kind == MangaAudioPackageTaskKind.import &&
        activeImportOverlapping(path, claims) != null) {
      throw const MangaAudioPackageException(
        'import_running',
        '这个包或包里的卷已经在导入，等它结束',
      );
    }
    final int now = _now().millisecondsSinceEpoch;
    final MangaAudioPackageTask task = MangaAudioPackageTask._(
      id: 'manga-pkg-${kind.name}-$now-${_seq++}',
      kind: kind,
      path: path,
      createdAt: now,
    );
    if (kind == MangaAudioPackageTaskKind.import) task._claims.addAll(claims);
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
