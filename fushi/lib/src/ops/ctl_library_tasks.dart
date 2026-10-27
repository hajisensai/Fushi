/// library 域短时后台任务（有声书挂载 / 替换、重新匹配）的登记表。
///
/// 这些步骤几秒到几分钟，没有落盘队列可复用（小时级的转录才有
/// `AudiobookTranscribeImportQueue`），所以只在内存里记：进度、阶段、结果、取消。
///
/// 取消语义：底层函数只在**提交点之前**的检查点上看 [LibraryCtlTask.cancelRequested]
/// （见 `AudiobookAlignmentCancelled`）。任务一旦进入提交阶段（[LibraryCtlTask.markCommitting]：
/// 同步持久目录 / 写库），取消请求被拒——半途停下会留下「库指着已删文件」的残局。
library;

import 'dart:async';

import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show AudiobookAlignmentCancelled;

/// 任务状态。[done] / [failed] / [cancelled] 是终态。
enum LibraryCtlTaskStatus { running, done, failed, cancelled }

/// 取消请求的结局。
enum LibraryCtlCancelOutcome {
  /// 已登记，任务会在下一个检查点停下。
  requested,

  /// 已进入提交阶段，不能取消。
  committing,

  /// 任务已经结束。
  finished,
}

class LibraryCtlTask {
  LibraryCtlTask._({
    required this.id,
    required this.kind,
    required this.key,
    required this.createdAt,
  }) : updatedAt = createdAt;

  final String id;

  /// `attach` / `rematch`。
  final String kind;

  /// 条目键（`book:` / `srt:`）。
  final String key;
  final int createdAt;
  int updatedAt;

  LibraryCtlTaskStatus status = LibraryCtlTaskStatus.running;

  /// 当前步骤名（自由文本，如 `parsing` / `matching` / `saving`）。
  String? phase;

  /// 0..1；null = 不确定。
  double? progress;
  bool _cancelRequested = false;
  bool _committing = false;
  Map<String, Object?>? result;
  String? error;
  final Completer<void> _done = Completer<void>();

  /// 底层函数的取消检查点读这个。
  bool get cancelRequested => _cancelRequested;

  /// 是否已进入提交阶段（之后不能取消）。
  bool get committing => _committing;
  bool get isTerminal => status != LibraryCtlTaskStatus.running;

  /// 任务结束（任一终态）时完成。
  Future<void> get whenDone => _done.future;

  /// 报进度；[phase] 为 null 时保留原阶段。
  void report({String? phase, double? progress}) {
    if (isTerminal) return;
    if (phase != null) this.phase = phase;
    this.progress = progress;
    updatedAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// 进入提交阶段（之后的取消请求一律拒绝）。
  void markCommitting() => _committing = true;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'key': key,
    'status': status.name,
    if (phase != null) 'phase': phase,
    if (progress != null) 'progress': (progress! * 1000).round() / 10,
    'cancellable': !isTerminal && !_committing,
    if (_cancelRequested && !isTerminal) 'cancelRequested': true,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}

/// 失败原因转成给人看的文案（[describe] 由路由层给：认得的异常换中文）。
typedef LibraryCtlTaskErrorDescriber = String Function(Object error);

class LibraryCtlTaskRegistry {
  LibraryCtlTaskRegistry({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 进程级唯一登记表。
  static final LibraryCtlTaskRegistry instance = LibraryCtlTaskRegistry();

  /// 只保留最近这么多个已结束的任务（防常驻进程无限增长）。
  static const int kMaxFinished = 50;

  final DateTime Function() _now;
  final List<LibraryCtlTask> _tasks = <LibraryCtlTask>[];
  int _seq = 0;

  List<LibraryCtlTask> get tasks => List<LibraryCtlTask>.unmodifiable(_tasks);

  LibraryCtlTask? byId(String id) {
    for (final LibraryCtlTask task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// 同一条目上未结束的任务（挂载 / 匹配会互相踩持久目录与 cue，同键串行）。
  LibraryCtlTask? activeFor(String key) {
    for (final LibraryCtlTask task in _tasks) {
      if (task.key == key && !task.isTerminal) return task;
    }
    return null;
  }

  /// 起一个任务并立即返回；[run] 的返回值落 [LibraryCtlTask.result]。
  /// [run] 抛 [AudiobookAlignmentCancelled] = 取消；抛别的 = 失败（文案经 [describe]）。
  LibraryCtlTask start({
    required String kind,
    required String key,
    required Future<Map<String, Object?>> Function(LibraryCtlTask task) run,
    required LibraryCtlTaskErrorDescriber describe,
  }) {
    final int now = _now().millisecondsSinceEpoch;
    final LibraryCtlTask task = LibraryCtlTask._(
      id: '$kind-$now-${_seq++}',
      kind: kind,
      key: key,
      createdAt: now,
    );
    _tasks.add(task);
    _trimFinished();
    unawaited(() async {
      try {
        task.result = await run(task);
        task.status = LibraryCtlTaskStatus.done;
      } on AudiobookAlignmentCancelled {
        task.status = LibraryCtlTaskStatus.cancelled;
      } on Object catch (e) {
        task
          ..status = LibraryCtlTaskStatus.failed
          ..error = describe(e);
      } finally {
        task
          ..phase = null
          ..progress = null
          ..updatedAt = _now().millisecondsSinceEpoch;
        task._done.complete();
      }
    }());
    return task;
  }

  /// 请求取消（任务在下一个检查点停下）。
  LibraryCtlCancelOutcome cancel(LibraryCtlTask task) {
    if (task.isTerminal) return LibraryCtlCancelOutcome.finished;
    if (task.committing) return LibraryCtlCancelOutcome.committing;
    task._cancelRequested = true;
    return LibraryCtlCancelOutcome.requested;
  }

  void _trimFinished() {
    final List<LibraryCtlTask> finished = <LibraryCtlTask>[
      for (final LibraryCtlTask t in _tasks)
        if (t.isTerminal) t,
    ];
    final int extra = finished.length - kMaxFinished;
    for (int i = 0; i < extra; i++) {
      _tasks.remove(finished[i]);
    }
  }
}
