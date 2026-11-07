import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudyClock;

import 'package:fushi/src/stats/study_cover_tracker.dart';

/// 漫画 / PDF / 视频学习计时「此刻可跑」的唯一判据。
///
/// 小说阅读器的同类判据是 `studyClockMayRun`（多了有声书后台豁免）；这里是其余学习面
/// 共用的一份，输入全部由 [StudyClockRunGate] 持有：
///
/// - [manualPause]：用户手动暂停计时（统计侧栏 / 控制条计时键），任何时候一票否决；
/// - [lifecycleStopped]：真后台 / 熄屏 / 最小化（BUG-892 切屏暂停）；
/// - [covered]：根导航上本页路由之上压着未豁免的模态路由（整页 / 对话框 / 侧板 /
///   菜单，BUG-3994），由 [StudyCoverTracker] 判；
/// - [locallyCovered]：页内非路由的遮挡层（视频的设置 / 章节 / 画质侧板、剧集列表）——
///   它们不是路由，[StudyCoverTracker] 看不见，由页面显式喂；
/// - [unfocused] + [playing]：窗口失焦（`inactive`）。阅读面失焦即停；视频面失焦时
///   **仍在播放**就照常计（用户拍板：切走仍在播照常计时），停着则停表。
bool studyClockGateMayRun({
  required bool lifecycleStopped,
  required bool covered,
  bool manualPause = false,
  bool locallyCovered = false,
  bool unfocused = false,
  bool playing = false,
}) {
  if (manualPause || lifecycleStopped || covered || locallyCovered) {
    return false;
  }
  return !unfocused || playing;
}

/// 漫画 / PDF / 视频共用的学习计时门：持有 [studyClockGateMayRun] 的全部输入，任一
/// 变化都按它把结论交给 [apply]（起表 / 停表）。
///
/// 两页只负责喂输入，不各写一份判据：
/// - `didChangeDependencies` 里 [attach] 本页路由；
/// - `didChangeAppLifecycleState` 里 [setLifecycleStopped]；
/// - 页内遮挡层开 / 关时 [setLocallyCovered]，手动暂停键 [toggleManualPause]，
///   失焦 [setUnfocused]、播放态翻转 [setPlaying]（只有视频面喂后两路）；
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
  bool _manualPause = false;
  bool _locallyCovered = false;
  bool _unfocused = false;
  bool _playing = false;
  bool _disposed = false;

  /// 当前结论。
  bool get mayRun => studyClockGateMayRun(
    lifecycleStopped: _lifecycleStopped,
    covered: _watch.covered,
    manualPause: _manualPause,
    locallyCovered: _locallyCovered,
    unfocused: _unfocused,
    playing: _playing,
  );

  /// 用户手动暂停着计时（UI 据此画计时键的图标）。
  bool get manualPause => _manualPause;

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

  /// 手动暂停 / 继续计时。切后台期间点「继续」只是清旗、回前台再起表（同小说的
  /// BUG-2209 统一判据）。
  void toggleManualPause() => setManualPause(!_manualPause);

  void setManualPause(bool paused) {
    if (_manualPause == paused) return;
    _manualPause = paused;
    sync();
  }

  /// 页内非路由遮挡层（侧板 / 列表）是否压着学习内容。
  void setLocallyCovered(bool covered) {
    if (_locallyCovered == covered) return;
    _locallyCovered = covered;
    sync();
  }

  /// 窗口失焦（`AppLifecycleState.inactive`）。与 [setLifecycleStopped] 分开：失焦时
  /// 视频仍在播放就照常计（[studyClockGateMayRun]）。
  void setUnfocused(bool unfocused) {
    if (_unfocused == unfocused) return;
    _unfocused = unfocused;
    sync();
  }

  /// 视频播放态（只影响失焦时的结论）。
  void setPlaying(bool playing) {
    if (_playing == playing) return;
    _playing = playing;
    if (_unfocused) sync();
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
