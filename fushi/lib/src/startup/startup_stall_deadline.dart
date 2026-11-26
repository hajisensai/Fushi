import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

import 'package:fushi/src/startup/startup_timeline.dart';
import 'package:fushi/src/utils/misc/hang_watchdog_log.dart';

/// 启动期限（Dart 侧）：`main()` 起跑 [kStartupStallDeadline] 后主窗仍没显示，就把
/// [StartupTimeline] 已经走到的阶段写进 `crashdumps\hang_watchdog.log`。
///
/// 起因（反馈：Surface Pro 7+ 升级 3.4 后进程常驻后台、窗口永远不出）：普通启动主窗
/// 一直藏着，等首页 / 错误页第一帧上屏才显窗；中间任何一步 await 不返回、或首帧光栅化
/// 不出来，进程就一直隐形。用户那份 dump 里所有线程都在空闲等待——Dart 在等一个永远
/// 不完成的 Future，但 dump 说不出是哪一个；`StartupTimeline` 原本只在显窗后才落盘，
/// 卡住时恰好什么都不写。
///
/// 这里只在 Dart 事件循环还活着时有用（卡在 await 正是这种形态）；同步 FFI 把
/// isolate 堵死的情形由原生启动期限（`windows/runner/startup_reveal_policy.h`，45 s：
/// 抓全线程栈 dump + 强制显窗）兜住。两条写进同一个日志，下次启动由
/// [HangWatchdogLog.foldIntoErrorLog] 一起折进错误日志。比原生期限早 5 s，dump 抓到
/// 的那一刻 Dart 这条已经在盘上。
///
/// 只在 Windows 挂：日志路径与原生看门狗共用（`%LOCALAPPDATA%\Fushi\crashdumps`），
/// 原生期限也只有 Windows runner 有。
const Duration kStartupStallDeadline = Duration(seconds: 40);

/// 期限到点时的取证行（纯函数，便于单测）。[reachedPhases] 是 [StartupTimeline.describe]
/// 的结果；最后一个阶段之后的那一步就是卡住的 await。
String describeStartupStall({
  required Duration after,
  required String? lastPhase,
  required bool? firstFrameRasterized,
  required String reachedPhases,
}) {
  final String frame = firstFrameRasterized == null
      ? 'unknown'
      : firstFrameRasterized.toString();
  return 'startup: window still hidden ${after.inSeconds}s after main() '
      '(Dart side); last phase reached=${lastPhase ?? '(none)'} '
      'firstFrameRasterized=$frame; timeline: $reachedPhases';
}

/// 在 `main()` 里 [StartupTimeline.begin] 之后立刻调用（仅 Windows 生效）。返回的
/// [Timer] 供测试取消；生产不用管——显窗后到点时 [StartupTimeline.isSealed] 为真，
/// 回调什么都不做。
Timer? armStartupStallDeadline({
  bool? isWindows,
  Duration after = kStartupStallDeadline,
  File? Function()? resolveLogFile,
  bool Function()? isSealed,
  DateTime Function()? now,
}) {
  if (!(isWindows ?? Platform.isWindows)) return null;
  return Timer(after, () {
    if ((isSealed ?? () => StartupTimeline.isSealed)()) return;
    final File? file =
        (resolveLogFile ??
                () => HangWatchdogLog.resolveLogFile(
                  isWindows: Platform.isWindows,
                  localAppData: Platform.environment['LOCALAPPDATA'],
                ))
            .call();
    if (file == null) return;
    final List<StartupMark> marks = StartupTimeline.marks;
    final String line = describeStartupStall(
      after: after,
      lastPhase: marks.isEmpty ? null : marks.last.phase,
      firstFrameRasterized: _firstFrameRasterizedOrNull(),
      reachedPhases: StartupTimeline.describe(),
    );
    HangWatchdogLog.appendLine(file, line, now: (now ?? DateTime.now)());
    debugPrint('[Fushi] $line');
  });
}

bool? _firstFrameRasterizedOrNull() {
  try {
    return WidgetsBinding.instance.firstFrameRasterized;
  } catch (_) {
    // binding 还没初始化（卡在 ensureInitialized 之前）。
    return null;
  }
}
