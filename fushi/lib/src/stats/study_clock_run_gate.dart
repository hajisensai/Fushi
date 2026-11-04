import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudyClock;

import 'package:fushi/src/stats/study_cover_tracker.dart';

/// 漫画 / PDF 阅读器学习计时「此刻可跑」的唯一判据：在前台、且没被路由盖住。
///
/// 小说阅读器的同类判据是 `studyClockMayRun`（多了手动暂停 / 面板层数 / 有声书豁免）；
/// 漫画与 PDF 没有那些状态，只剩这两条（BUG-892 切屏暂停 + BUG-3994 被盖住停表）。
bool studyClockGateMayRun({
  required bool lifecycleStopped,
  required bool covered,
}) => !lifecycleStopped && !covered;

/// 漫画 / PDF 共用的学习计时门：持有「生命周期停着」与「被盖住」两路输入，任一变化
/// 都按 [studyClockGateMayRun] 把结论交给 [apply]（起表 / 停表）。
///
/// 两页只负责喂输入，不各写一份判据：
/// - `didChangeDependencies` 里 [attach] 本页路由；
/// - `didChangeAppLifecycleState` 里 [setLifecycleStopped]；
/// - 时钟建好时调 [sync]——建表时已在后台 / 已被盖住就不起表；
/// - `dispose` 里 [dispose]（之后不再回调）。
///
/// [apply] 可能在 Navigator 刷新历史期间同步触发（见 [StudyCoverWatch]），里面只做
/// 起表 / 停表，不 `setState`。
class StudyClockRunGate {
  StudyClockRunGate({
    required void Function(bool mayRun) apply,
    StudyCoverTracker? tracker,
  }) : _apply = apply {
    _watch = StudyCoverWatch(tracker: tracker, onChanged: sync);
  }

  /// 门的结论直接落到 [clock] 返回的时钟上（为 null = 还没开始计时，跳过）。
  factory StudyClockRunGate.forClock(
    StudyClock? Function() clock, {
    StudyCoverTracker? tracker,
  }) => StudyClockRunGate(
    tracker: tracker,
    apply: (bool mayRun) {
      final StudyClock? current = clock();
      if (current == null) return;
      if (mayRun) {
        current.start();
      } else {
        unawaited(current.stop());
      }
    },
  );

  final void Function(bool mayRun) _apply;
  late final StudyCoverWatch _watch;
  bool _lifecycleStopped = false;
  bool _disposed = false;

  /// 当前结论。
  bool get mayRun => studyClockGateMayRun(
    lifecycleStopped: _lifecycleStopped,
    covered: _watch.covered,
  );

  /// 当前是否被路由盖住。
  bool get covered => _watch.covered;

  /// 喂本页路由（`ModalRoute.of(context)`）。路由之上已压着东西时立刻按「被盖住」
  /// 对齐。
  void attach(Route<dynamic>? route) => _watch.attach(route);

  /// 切后台 / 失焦（true）或回到前台（false）。回前台时仍被盖住就不续表。
  void setLifecycleStopped(bool stopped) {
    _lifecycleStopped = stopped;
    sync();
  }

  /// 按当前结论对齐一次（时钟刚建好时调）。
  void sync() {
    if (_disposed) return;
    _apply(mayRun);
  }

  void dispose() {
    _disposed = true;
    _watch.dispose();
  }
}
