import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudyClock;

import 'package:fushi/src/media/video/video_study_accrual_arbiter.dart';
import 'package:fushi/src/stats/study_clock_run_gate.dart';
import 'package:fushi/src/stats/study_cover_tracker.dart';

/// 视频页（本地视频页 / 网页档视频页）学习计时的装配：计时门 [gate] + 跨面入账仲裁
/// 登记 [claim] + 生命周期映射，两页同一份，不各写一遍。
///
/// - [gate] 的每次落定按「时钟是否在跑 + 本 app 是否持焦」向 [claim] 报到；
/// - 时钟的 `isActive` 读 [timeAllowed]（同时在播时只一边入账时长）；
/// - 生命周期经 [onAppLifecycleChanged] 喂门：`inactive` 只喂「失焦」（仍在播放照常
///   计、停着停表），`paused` / `hidden` 是真后台，`resumed` 两旗一起清、只落定一次；
/// - 页面 dispose 调 [dispose]（门不再回调 + 仲裁离场）。
///
/// 页面只负责喂其余输入（路由 [StudyClockRunGate.attach]、页内遮挡、播放态、开始方式）。
class VideoStudyClockSession {
  VideoStudyClockSession({
    required StudyClock? Function() clock,
    required Duration? Function() idleTimeout,
    required FutureOr<void> Function() settle,
    VideoStudyAccrualArbiter? arbiter,
    StudyCoverTracker? tracker,
  }) : claim = (arbiter ?? VideoStudyAccrualArbiter.instance).claim(
         surface: VideoStudySurface.inApp,
         settle: settle,
       ) {
    gate = StudyClockRunGate.forClock(
      clock,
      tracker: tracker,
      idleTimeout: idleTimeout,
      onApplied: (bool running, bool appForeground) =>
          claim.update(running: running, foreground: appForeground),
    );
  }

  /// 本页在 [VideoStudyAccrualArbiter] 里的登记。
  final VideoStudyAccrualClaim claim;

  /// 起停表的唯一判据持有者。
  late final StudyClockRunGate gate;

  /// 本页此刻能否入账时长（喂时钟的 `isActive`）。
  bool get timeAllowed => claim.timeAllowed;

  /// app 生命周期 → 计时门（视频面口径：失焦与真后台分开喂）。
  void onAppLifecycleChanged(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        gate.setUnfocused(true);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        gate.setLifecycleStopped(true);
      case AppLifecycleState.resumed:
        gate.setFocusedForeground();
      case AppLifecycleState.detached:
        break;
    }
  }

  /// 幂等：宿主的异常拆栈与正常离场可能各调一次。
  void dispose() {
    gate.dispose();
    claim.release();
  }
}
