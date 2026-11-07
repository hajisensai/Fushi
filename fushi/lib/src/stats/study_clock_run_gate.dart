import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudyClock;

import 'package:fushi/src/stats/reader_study_clock_start_mode.dart';
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
///
/// 桌面查词窗不是输入：它在三端都拿不到焦点（Windows `WS_EX_NOACTIVATE` + 激活守卫、
/// macOS nonactivating `NSPanel` 且 `canBecomeKey == false`、Linux GTK
/// `accept_focus = FALSE`），在本 app 里查词时主窗仍持焦、不会报 `inactive`，「暂停
/// 查词也算时间」由此自然成立；主窗报 `inactive` 就是焦点去了别的 app。曾用「桌面
/// 查词路由仍有效」冒充「焦点在本 app 的查词窗」，把切走误判成在场（PR #3020 审查）。
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

/// 把门的结论落到 [clock] 上（null = 还没开始计时，跳过）。起表前从设置刷一次空闲门
/// [idleTimeout]（与阅读器 `_ensureStudyClock` 同律，BUG-2213：不在建时钟时快照——
/// 学习中改了设置，下次起表即生效；改设置要开设置面板 / 设置页，那会先停表）。
/// 返回时钟此刻是否在跑。
bool applyStudyClockRun(
  StudyClock? clock,
  bool mayRun, {
  Duration? Function()? idleTimeout,
}) {
  if (clock == null) return false;
  if (mayRun) {
    if (idleTimeout != null) clock.idleTimeout = idleTimeout();
    clock.start();
    return true;
  }
  unawaited(clock.stop());
  return false;
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

  /// 门的结论直接落到 [clock] 返回的时钟上（为 null = 还没开始计时，跳过），起表时
  /// 从 [idleTimeout] 刷空闲门（见 [applyStudyClockRun]）。
  ///
  /// [onApplied] 在每次落定后回报「时钟此刻是否在跑」与 [appForeground]（视频面据此
  /// 向跨面入账仲裁 `VideoStudyAccrualArbiter` 报到）。
  factory StudyClockRunGate.forClock(
    StudyClock? Function() clock, {
    StudyCoverTracker? tracker,
    Duration? Function()? idleTimeout,
    void Function(bool running, bool appForeground)? onApplied,
  }) {
    late final StudyClockRunGate gate;
    gate = StudyClockRunGate(
      tracker: tracker,
      apply: (bool mayRun) {
        final bool running = applyStudyClockRun(
          clock(),
          mayRun,
          idleTimeout: idleTimeout,
        );
        onApplied?.call(running, gate.appForeground);
      },
    );
    return gate;
  }

  final void Function(bool mayRun) _apply;
  late final StudyCoverWatch _watch;
  bool _lifecycleStopped = false;
  bool _locallyCovered = false;
  bool _unfocused = false;
  bool _playing = false;
  bool _disposed = false;

  /// 「首次开始播放后自动起表」还在等（[applyStartMode] 的 onPageTurn 对视频的解释）。
  bool _awaitingFirstPlay = false;

  /// 手动暂停旗的唯一持有者；UI（计时键图标 / 文案）经 [manualPauseListenable] 重建。
  final ValueNotifier<bool> _manualPause = ValueNotifier<bool>(false);

  /// 当前结论。
  bool get mayRun => studyClockGateMayRun(
    lifecycleStopped: _lifecycleStopped,
    covered: _watch.covered,
    manualPause: _manualPause.value,
    locallyCovered: _locallyCovered,
    unfocused: _unfocused,
    playing: _playing,
  );

  /// 本 app 此刻持有焦点（主窗没报失焦；查词窗不抢焦点，见 [studyClockGateMayRun]）。
  bool get appForeground => !_unfocused;

  /// 用户手动暂停着计时（UI 据此画计时键的图标）。
  bool get manualPause => _manualPause.value;

  /// [manualPause] 的监听口（开始方式的自动起表也会翻它，UI 不能只在点按时重建）。
  ValueListenable<bool> get manualPauseListenable => _manualPause;

  /// 是否仍在等首次开始播放自动起表。
  bool get awaitingFirstPlay => _awaitingFirstPlay;

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
  void toggleManualPause() => setManualPause(!_manualPause.value);

  /// 用户亲手停 / 续：同时结束「等首次播放」——用户已决定，之后开播不再替他起表
  /// （同 `ReaderStudyClockStartGate.toggleManualPause`）。
  void setManualPause(bool paused) {
    _awaitingFirstPlay = false;
    if (_manualPause.value == paused) return;
    _manualPause.value = paused;
    sync();
  }

  /// 按「计时开始方式」偏好（`stats_reading_clock_start_mode`，与小说同一设置）设定
  /// 打开时的状态：manual = 打开即手动暂停；onOpen = 照常；onPageTurn 对视频解释为
  /// 「打开时暂停，首次开始播放（[setPlaying] true）自动起表」。页面打开时调一次。
  void applyStartMode(ReaderStudyClockStartMode mode) {
    _awaitingFirstPlay = mode.awaitsFirstPageTurn;
    _manualPause.value = mode.startsPaused;
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

  /// 回到前台且持焦（`resumed`）：失焦与后台两旗一起清，只落定一次（分两步清会先按
  /// 「仍在后台」落定一次停表，再起表）。
  void setFocusedForeground() {
    _unfocused = false;
    _lifecycleStopped = false;
    sync();
  }

  /// 视频播放态（只影响失焦时的结论）。
  void setPlaying(bool playing) {
    if (_playing == playing) return;
    _playing = playing;
    if (playing && _awaitingFirstPlay) {
      _awaitingFirstPlay = false;
      _manualPause.value = false;
      sync();
      return;
    }
    if (_unfocused) sync();
  }

  /// 按当前结论对齐一次（时钟刚建好时调）。
  void sync() {
    if (_disposed) return;
    _apply(mayRun);
  }

  /// 幂等：宿主的异常拆栈与正常离场可能各调一次。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _watch.dispose();
    _manualPause.dispose();
  }
}
