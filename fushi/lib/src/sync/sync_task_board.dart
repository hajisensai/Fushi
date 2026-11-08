/// 在飞同步的**任务表**：每一轮同步一项，各自带着阶段、当前条目、在等谁、出过哪些错
/// （反馈 kM-Gb_Xnu-，开发者追加的要求）。
///
/// 按资源加锁（`sync_resource_locks.dart`）之后，同一时刻可能有好几轮同步在跑——全量
/// sweep 在传视频，退出的那本书的进度同步同时在走。以前的单值 [syncActivity] /
/// [syncProgress] 只装得下一轮，后开始的那轮会把前一轮的身份与阶段覆盖掉；面板也只能
/// 说「同步阅读数据 (3/12)」，看不出这是哪一轮、条目是书还是视频、停在这一步多久了、
/// 哪几项失败了。这里是这些信息的唯一来源，旧的三个全局值改为由它派生
/// （[_SyncTaskBoard._publish]），既有消费方一行不改。
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';
import 'package:material_ui/material_ui.dart';

/// 有没有同步在飞（任意一轮）。由任务表派生。
final ValueNotifier<bool> syncInProgress = ValueNotifier<bool>(false);

/// **主任务**最近一个阶段 tick（主任务的选法见 [_SyncTaskBoard._primary]）。由任务表
/// 派生；没有同步在跑时为 null。设置页「立即同步」那行与桌面控制通道读它。
final ValueNotifier<SyncProgress?> syncProgress = ValueNotifier<SyncProgress?>(
  null,
);

/// 主任务的身份。由任务表派生；没有同步在跑时为 null。
final ValueNotifier<SyncActivity?> syncActivity = ValueNotifier<SyncActivity?>(
  null,
);

/// 一轮同步里记下的一条失败。
@immutable
class SyncTaskError {
  const SyncTaskError({required this.message, this.phase, this.itemKind});

  /// 报告里的那一行原文（`<维度/条目>: <异常>`，与 `SyncRunReport.errors` 逐字相同）。
  final String message;

  /// 出错时这一轮所处的阶段（单本 / 合集这类无阶段的路径为 null）。
  final SyncPhase? phase;

  /// 出错时正在同步的条目种类（不知道时为 null）。
  final SyncItemKind? itemKind;

  @override
  bool operator ==(Object other) =>
      other is SyncTaskError &&
      other.message == message &&
      other.phase == phase &&
      other.itemKind == itemKind;

  @override
  int get hashCode => Object.hash(message, phase, itemKind);
}

/// 任务表里的一项（不可变快照）。
@immutable
class SyncTask {
  const SyncTask({
    required this.id,
    required this.kind,
    required this.startedAt,
    required this.stageSince,
    this.title,
    this.channel,
    this.progress,
    this.waitingOn = const <SyncActivityKind?>[],
    this.errors = const <SyncTaskError>[],
    this.finishedAt,
  });

  final int id;
  final SyncActivityKind kind;

  /// 单本同步的书名（拿到书之前为 null）。
  final String? title;

  /// 此刻在跑的通道（sweep 依次跑云备份 / 互联；不分通道的阶段为 null）。
  final SyncChannelScope? channel;

  /// 最近一个阶段 tick；还没进任何阶段时为 null。
  final SyncProgress? progress;

  /// 开始时刻（毫秒）。
  final int startedAt;

  /// 当前这一步（阶段或条目）从什么时候开始的（毫秒）。面板据此显示「这一步已经
  /// 多久」，用户才分得清「在慢慢传」和「卡住了」。
  final int stageSince;

  /// 正在排队等的那几轮同步的种类（空 = 没在等）。挡路的不是一轮登记过的同步
  /// （对比弹窗、复习同步）时对应项为 null。
  final List<SyncActivityKind?> waitingOn;

  /// 本轮至今记下的失败（按发生顺序）。
  final List<SyncTaskError> errors;

  /// 结束时刻；null = 仍在跑。结束了但有失败的那几轮会在表里多留一会儿
  /// （[kSyncTaskBoardFinishedKeep]），让面板还能看到它们的错误。
  final int? finishedAt;

  bool get isActive => finishedAt == null;
  bool get isWaiting => waitingOn.isNotEmpty;

  SyncTask _copy({
    String? title,
    SyncChannelScope? channel,
    bool clearChannel = false,
    SyncProgress? progress,
    int? stageSince,
    List<SyncActivityKind?>? waitingOn,
    List<SyncTaskError>? errors,
    int? finishedAt,
  }) => SyncTask(
    id: id,
    kind: kind,
    startedAt: startedAt,
    stageSince: stageSince ?? this.stageSince,
    title: title ?? this.title,
    channel: clearChannel ? null : (channel ?? this.channel),
    progress: progress ?? this.progress,
    waitingOn: waitingOn ?? this.waitingOn,
    errors: errors ?? this.errors,
    finishedAt: finishedAt ?? this.finishedAt,
  );
}

/// 结束后仍带错误的任务最多留几项。
const int kSyncTaskBoardFinishedKeep = 3;

/// 一轮同步在任务表里的句柄。同时也是这轮同步在锁表里的 owner（见
/// `SyncResourceLocks.withResources`）：排队方据此知道自己在等哪一轮。
class SyncTaskHandle {
  SyncTaskHandle._(this._board, this.id, this.kind);

  final _SyncTaskBoard _board;
  final int id;
  final SyncActivityKind kind;

  /// 补上书名（单本同步在入口只有 mediaIdentifier）。
  void setTitle(String? title) {
    if (title == null) return;
    _board._update(id, (SyncTask t) => t._copy(title: title));
  }

  /// 进入 / 离开一条通道。
  void setChannel(SyncChannelScope? channel) => _board._update(
    id,
    (SyncTask t) => t._copy(channel: channel, clearChannel: channel == null),
  );

  /// 一个阶段 tick。阶段或条目变了才重置「这一步已多久」的起点；同一条目上的字节
  /// 进度 tick 不算换步。
  void progress(SyncProgress p) => _board._update(id, (SyncTask t) {
    final SyncProgress? prev = t.progress;
    final bool newStage =
        prev == null ||
        prev.phase != p.phase ||
        prev.itemIndex != p.itemIndex ||
        prev.title != p.title;
    return t._copy(progress: p, stageSince: newStage ? _board._now() : null);
  });

  /// 这轮同步此刻在排的那几样（凭据 → 挡路者种类）。同一轮可能同时排好几样（退出书
  /// 并发排云通道与互联通道），各自记账，一样排到不清掉另一样的「在等」。
  final Map<Object, List<SyncActivityKind?>> _waits =
      <Object, List<SyncActivityKind?>>{};

  /// 开始排队：[holders] 是锁表报出的挡路者。返回凭据，排到时交给 [granted]。
  Object waiting(List<Object?> holders) {
    final Object token = Object();
    _waits[token] = <SyncActivityKind?>[
      for (final Object? h in holders) h is SyncTaskHandle ? h.kind : null,
    ];
    _publishWaits();
    return token;
  }

  /// [token] 那次排队排到了（null = 没排队，直接拿到的）。
  void granted(Object? token) {
    if (token == null || _waits.remove(token) == null) return;
    _publishWaits();
  }

  void _publishWaits() => _board._update(
    id,
    (SyncTask t) => t._copy(
      waitingOn: <SyncActivityKind?>[
        for (final List<SyncActivityKind?> kinds in _waits.values) ...kinds,
      ],
      stageSince: _board._now(),
    ),
  );

  /// 记一条失败；阶段与条目种类取此刻最近的那个 tick。
  void error(String message) => _board._update(id, (SyncTask t) {
    final SyncProgress? p = t.progress;
    return t._copy(
      errors: <SyncTaskError>[
        ...t.errors,
        SyncTaskError(message: message, phase: p?.phase, itemKind: p?.itemKind),
      ],
    );
  });

  /// 这轮结束。没有错误的直接移出表；有错误的标成已结束、多留一会儿。
  void finish() => _board._finish(id);
}

class _SyncTaskBoard {
  _SyncTaskBoard();

  final ValueNotifier<List<SyncTask>> tasks = ValueNotifier<List<SyncTask>>(
    const <SyncTask>[],
  );
  int _nextId = 1;
  int Function() _now = () => DateTime.now().millisecondsSinceEpoch;

  SyncTaskHandle begin(SyncActivityKind kind, {String? title}) {
    final int id = _nextId++;
    final int now = _now();
    tasks.value = <SyncTask>[
      ...tasks.value,
      SyncTask(
        id: id,
        kind: kind,
        title: title,
        startedAt: now,
        stageSince: now,
      ),
    ];
    _publish();
    return SyncTaskHandle._(this, id, kind);
  }

  void _update(int id, SyncTask Function(SyncTask) change) {
    bool changed = false;
    final List<SyncTask> next = <SyncTask>[];
    for (final SyncTask t in tasks.value) {
      if (t.id == id && t.isActive) {
        changed = true;
        next.add(change(t));
      } else {
        next.add(t);
      }
    }
    if (!changed) return;
    tasks.value = next;
    _publish();
  }

  void _finish(int id) {
    final int now = _now();
    final List<SyncTask> next = <SyncTask>[];
    for (final SyncTask t in tasks.value) {
      if (t.id != id) {
        next.add(t);
      } else if (t.errors.isNotEmpty) {
        next.add(
          t._copy(finishedAt: now, waitingOn: const <SyncActivityKind?>[]),
        );
      }
    }
    // 已结束的只留最近几项。
    final List<SyncTask> finished = <SyncTask>[
      for (final SyncTask t in next)
        if (!t.isActive) t,
    ];
    final int drop = finished.length - kSyncTaskBoardFinishedKeep;
    if (drop > 0) {
      final Set<int> dropped = <int>{
        for (final SyncTask t in finished.take(drop)) t.id,
      };
      next.removeWhere((SyncTask t) => dropped.contains(t.id));
    }
    tasks.value = next;
    _publish();
  }

  /// 主任务：全量 sweep 优先（「立即同步」那行讲的就是它），其次资产传输，再其次
  /// 最近开始的那一轮。
  SyncTask? _primary(List<SyncTask> active) {
    for (final SyncActivityKind kind in const <SyncActivityKind>[
      SyncActivityKind.fullSweep,
      SyncActivityKind.assetTransfer,
    ]) {
      for (final SyncTask t in active) {
        if (t.kind == kind) return t;
      }
    }
    return active.isEmpty ? null : active.last;
  }

  /// 由任务表派生三个旧全局值。
  void _publish() {
    final List<SyncTask> active = <SyncTask>[
      for (final SyncTask t in tasks.value)
        if (t.isActive) t,
    ];
    final SyncTask? primary = _primary(active);
    syncInProgress.value = active.isNotEmpty;
    syncActivity.value = primary == null
        ? null
        : SyncActivity(primary.kind, title: primary.title);
    syncProgress.value = primary?.progress;
  }
}

final _SyncTaskBoard _board = _SyncTaskBoard();

/// 在飞（与刚结束且有失败）的同步任务，按开始顺序。
ValueListenable<List<SyncTask>> get syncTasks => _board.tasks;

/// 登记一轮同步开始，返回它的句柄。每条同步路径必须成对调用 [SyncTaskHandle.finish]。
SyncTaskHandle beginSyncTask(SyncActivityKind kind, {String? title}) =>
    _board.begin(kind, title: title);

/// 测试用：清空任务表（模块级状态在测试间必须可复位）并可注入时钟。
@visibleForTesting
void resetSyncTasksForTest({int Function()? now}) {
  _board.tasks.value = const <SyncTask>[];
  _board._now = now ?? () => DateTime.now().millisecondsSinceEpoch;
  _board._publish();
}
