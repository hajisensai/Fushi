/// 控制通道上「起了就返回」的设置类后台任务（应用更新下载、Plex 账号授权、
/// Hoshi 备份导入…）的登记表。
///
/// 一条控制通道请求只有一来一回：要先把授权链接 / 任务号交给终端、再慢慢等结果的
/// 动作，执行体在这里起任务并立即返回 [SettingsCliTask.toJson]；CLI 用
/// `fushi_cli task get <id> --wait <秒>` 等结局、`task cancel <id>` 取消。
///
/// 只在内存里记（进度、阶段、结果、取消）：这些步骤是秒级到分钟级的交互流程，
/// 没有需要跨重启恢复的落盘队列。
///
/// 取消语义：任务自己在 [SettingsCliTask.onCancel] 里登记怎么停（取消令牌 / 轮询
/// 旗标）；进入提交阶段（[SettingsCliTask.markCommitting]：写库 / 交给安装器）后
/// 取消请求一律拒绝——半途停下会留下残局。
library;

import 'dart:async';

/// 任务状态。[done] / [failed] / [cancelled] 是终态。
enum SettingsCliTaskStatus { running, done, failed, cancelled }

/// 取消请求的结局。
enum SettingsCliCancelOutcome {
  /// 已登记，任务会在下一个检查点停下。
  requested,

  /// 已进入提交阶段，或任务本身不支持取消。
  refused,

  /// 任务已经结束。
  finished,
}

/// 执行体抛出它 = 任务被取消（不算失败）。
class SettingsCliTaskCancelled implements Exception {
  const SettingsCliTaskCancelled();

  @override
  String toString() => 'SettingsCliTaskCancelled';
}

class SettingsCliTask {
  SettingsCliTask._({
    required this.id,
    required this.kind,
    required this.createdAt,
  }) : updatedAt = createdAt;

  final String id;

  /// 任务种类（`update-download` / `plex-sign-in` / `external-reader-import`…）。
  final String kind;
  final int createdAt;
  int updatedAt;

  SettingsCliTaskStatus status = SettingsCliTaskStatus.running;

  /// 当前步骤名（自由文本，如 `downloading` / `waiting_authorization`）。
  String? phase;

  /// 0..1；null = 不确定。
  double? progress;

  /// 运行中就要给终端看的信息（授权链接 / PIN / 目标版本…）。不放凭据。
  final Map<String, Object?> detail = <String, Object?>{};

  /// 终态结果（[SettingsCliTaskStatus.done] 时）。
  Map<String, Object?>? result;
  String? error;

  bool _cancelRequested = false;
  bool _committing = false;
  void Function()? _onCancel;
  final Completer<void> _done = Completer<void>();

  /// 执行体的取消检查点读这个。
  bool get cancelRequested => _cancelRequested;
  bool get committing => _committing;
  bool get isTerminal => status != SettingsCliTaskStatus.running;

  /// 任务能否被取消：执行体登记过 [onCancel]，且还没进提交阶段。
  bool get cancellable => !isTerminal && !_committing && _onCancel != null;

  /// 任务结束（任一终态）时完成。
  Future<void> get whenDone => _done.future;

  /// 登记取消动作（取消令牌 / 旗标）；不登记 = 该任务不可取消。
  set onCancel(void Function() cancel) => _onCancel = cancel;

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
    'status': status.name,
    if (phase != null) 'phase': phase,
    if (progress != null) 'progress': (progress! * 1000).round() / 10,
    if (detail.isNotEmpty) 'detail': detail,
    'cancellable': cancellable,
    if (_cancelRequested && !isTerminal) 'cancelRequested': true,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}

/// 失败原因转成给人看的文案。
typedef SettingsCliTaskErrorDescriber = String Function(Object error);

class SettingsCliTaskRegistry {
  SettingsCliTaskRegistry({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 进程级唯一登记表。
  static final SettingsCliTaskRegistry instance = SettingsCliTaskRegistry();

  /// 只保留最近这么多个已结束的任务（防常驻进程无限增长）。
  static const int kMaxFinished = 30;

  final DateTime Function() _now;
  final List<SettingsCliTask> _tasks = <SettingsCliTask>[];
  int _seq = 0;

  List<SettingsCliTask> get tasks => List<SettingsCliTask>.unmodifiable(_tasks);

  SettingsCliTask? byId(String id) {
    for (final SettingsCliTask task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// 同种类未结束的任务（同种任务串行：两次更新下载 / 两轮 PIN 授权会互相踩）。
  SettingsCliTask? activeOf(String kind) {
    for (final SettingsCliTask task in _tasks) {
      if (task.kind == kind && !task.isTerminal) return task;
    }
    return null;
  }

  /// 同种类最近一个任务（含已结束的）。
  SettingsCliTask? latestOf(String kind) {
    for (final SettingsCliTask task in _tasks.reversed) {
      if (task.kind == kind) return task;
    }
    return null;
  }

  /// 起一个任务并立即返回；[run] 的返回值落 [SettingsCliTask.result]。
  /// [run] 抛 [SettingsCliTaskCancelled] 或 [isCancellation] 认得的异常 = 取消；
  /// 抛别的 = 失败（文案经 [describe]）。[run] 在本调用里同步跑到它的第一个
  /// `await` 为止：在那之前登记的 [SettingsCliTask.onCancel] / detail 会出现在
  /// start 返回后立刻取的快照里。
  SettingsCliTask start({
    required String kind,
    required Future<Map<String, Object?>?> Function(SettingsCliTask task) run,
    SettingsCliTaskErrorDescriber? describe,
    bool Function(Object error)? isCancellation,
  }) {
    final int now = _now().millisecondsSinceEpoch;
    final SettingsCliTask task = SettingsCliTask._(
      id: '$kind-$now-${_seq++}',
      kind: kind,
      createdAt: now,
    );
    _tasks.add(task);
    _trimFinished();
    unawaited(() async {
      try {
        task.result = await run(task);
        task.status = SettingsCliTaskStatus.done;
      } on Object catch (e) {
        if (e is SettingsCliTaskCancelled ||
            (isCancellation?.call(e) ?? false)) {
          task.status = SettingsCliTaskStatus.cancelled;
        } else {
          task
            ..status = SettingsCliTaskStatus.failed
            ..error = describe?.call(e) ?? '$e';
        }
      } finally {
        task
          ..progress = null
          ..updatedAt = _now().millisecondsSinceEpoch;
        task._done.complete();
      }
    }());
    return task;
  }

  /// 请求取消（任务在下一个检查点停下）。
  SettingsCliCancelOutcome cancel(SettingsCliTask task) {
    if (task.isTerminal) return SettingsCliCancelOutcome.finished;
    if (!task.cancellable) return SettingsCliCancelOutcome.refused;
    task._cancelRequested = true;
    task._onCancel!();
    return SettingsCliCancelOutcome.requested;
  }

  /// 等 [task] 结束，最多 [timeout]；返回是否已结束。
  Future<bool> wait(SettingsCliTask task, Duration timeout) async {
    if (task.isTerminal) return true;
    try {
      await task.whenDone.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void _trimFinished() {
    final List<SettingsCliTask> finished = <SettingsCliTask>[
      for (final SettingsCliTask t in _tasks)
        if (t.isTerminal) t,
    ];
    final int extra = finished.length - kMaxFinished;
    for (int i = 0; i < extra; i++) {
      _tasks.remove(finished[i]);
    }
  }
}
