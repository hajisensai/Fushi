// 有意结束进程的唯一协调点（BUG：退出误报「前台意外退出」）。
//
// 过去「本次会话正常退出」只在几条退出链的**末尾**写（`exitApp` / 更新交接 /
// `detached`），而退出链本身要跑 flush、关库、原生 teardown，最长十几秒：
// - 退出看门狗（6s）比各步超时之和（~11s）短，到点直接 `exit(0)`，不标 clean；
// - 安装器 WM_CLOSE 后只等 2s 就强杀、系统关机 / 注销直接结束进程；
// - 备份导入 / 数据根迁移的兜底分支裸调 `exit(0)`。
// 这些全被下次启动判成「停在前台时没了，疑似闪退」（窗口已 hide，Windows 报的
// lifecycle 恰是 inactive）。
//
// 结构改为：
// 1. 每条有意退出的**第一步**、任何 await 之前调 [AppExitCoordinator.begin]，同步把
//    退出意图写进会话标记。此后进程不管怎么没的，下次启动都归为
//    `PreviousExitKind.exitInterrupted`（不上报，记下卡住的阶段）。
// 2. 退出链每步用 [AppExitCoordinator.enterStage] / [leaveStage] 记阶段（并行步骤记在飞
//    集合），被打断时知道卡在哪。
// 3. 看门狗时长由各串行阶段的预算推出（[watchdogTimeoutFor]），不再拍一个比预算还短的数。
// 4. 终止进程只经 [AppExitCoordinator.terminate]：先标 clean（带 terminatedBy），再
//    `exit`。`lib/` 下其余地方禁止裸 `exit(`（守卫
//    `test/build/process_exit_single_exit_guard_test.dart`）。

import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';

/// 退出意图 / 阶段 / clean 的落点。生产实现写 [PreviousExitLog] 的会话标记。
abstract interface class ExitMarkerSink {
  void exitRequested(String reason);
  void exitStage(String stage);
  void cleanExit(String terminatedBy);
}

class _PreviousExitLogSink implements ExitMarkerSink {
  const _PreviousExitLogSink();

  @override
  void exitRequested(String reason) =>
      PreviousExitLog.markExitRequested(reason);

  @override
  void exitStage(String stage) => PreviousExitLog.markExitStage(stage);

  @override
  void cleanExit(String terminatedBy) =>
      PreviousExitLog.markCleanExit(terminatedBy: terminatedBy);
}

void _systemExit(int code) => io.exit(code);

class AppExitCoordinator {
  AppExitCoordinator({
    ExitMarkerSink marker = const _PreviousExitLogSink(),
    void Function(int code) exitProcess = _systemExit,
  }) : _marker = marker,
       _exitProcess = exitProcess;

  /// 进程级单例。测试可替换（注入假 marker / 假 exit）。
  static AppExitCoordinator instance = AppExitCoordinator();

  final ExitMarkerSink _marker;
  final void Function(int code) _exitProcess;

  String? _reason;
  final List<String> _inFlight = <String>[];

  /// 本进程第一次发起退出的原因；没发起过为 null。
  String? get exitReason => _reason;

  /// 当前在飞的阶段（并行步骤按开始顺序 `+` 连接）；不在退出中为 null。
  String? get currentStage => _inFlight.isEmpty ? null : _inFlight.join('+');

  /// 看门狗留给自身调度与 `exit` 的余量。
  static const Duration watchdogMargin = Duration(seconds: 1);

  /// 一个并行阶段的预算 = 其中最长一步的预算。
  static Duration parallelBudget(Iterable<Duration> steps) =>
      steps.fold<Duration>(
        Duration.zero,
        (Duration a, Duration b) => Duration(
          microseconds: math.max(a.inMicroseconds, b.inMicroseconds),
        ),
      );

  /// 看门狗时长 = 各串行阶段预算之和 + [margin]。退出链每加一步超时，就把它加进
  /// 这张预算表，看门狗自动跟着变长——不会再出现「看门狗比步骤预算还短」。
  static Duration watchdogTimeoutFor(
    Iterable<Duration> serialBudgets, {
    Duration margin = watchdogMargin,
  }) => serialBudgets.fold<Duration>(margin, (Duration a, Duration b) => a + b);

  /// 退出链的**第一步**：同步落盘退出意图（调用方在任何 await 之前调）。返回 true =
  /// 这是本进程第一次发起退出；false = 已有退出在跑（意图保持第一次的原因）。
  bool begin(String reason) {
    if (_reason != null) return false;
    _reason = reason;
    _marker.exitRequested(reason);
    return true;
  }

  /// 进入一步（没 [begin] 过时只做内存记账，不写标记）。
  void enterStage(String label) {
    _inFlight.add(label);
    if (_reason != null) _marker.exitStage(currentStage!);
  }

  /// 离开一步。阶段只在进入时落盘：被打断时标记里留下的就是最后进入、可能还没走完的
  /// 那批步骤。
  void leaveStage(String label) {
    _inFlight.remove(label);
  }

  /// 在 [label] 阶段内跑 [step]，退出期的超时 / 异常都只记录、不外抛（退出清理失败不能
  /// 阻止退出），每步耗时打日志，下次「关闭慢」可直接定位。
  Future<void> runStep(String label, Future<void> Function() step) async {
    final Stopwatch watch = Stopwatch()..start();
    enterStage(label);
    try {
      await step();
      debugPrint(
        '[Fushi] exit step "$label" took ${watch.elapsedMilliseconds}ms',
      );
    } on TimeoutException {
      debugPrint(
        '[Fushi] exit step "$label" timed out after '
        '${watch.elapsedMilliseconds}ms; continuing',
      );
    } catch (e) {
      debugPrint(
        '[Fushi] exit step "$label" failed after '
        '${watch.elapsedMilliseconds}ms: $e',
      );
    } finally {
      leaveStage(label);
    }
  }

  /// 结束进程的唯一出口：先补 [begin]（直接走到这里的路径也留下意图），再标 clean
  /// （[terminatedBy] 记由谁结束），最后 `exit`。[exitWith] 只给已有测试缝的调用方
  /// （更新交接）透传假 exit。
  void terminate(
    String terminatedBy, {
    int code = 0,
    void Function(int code)? exitWith,
  }) {
    begin(terminatedBy);
    _marker.cleanExit(terminatedBy);
    (exitWith ?? _exitProcess)(code);
  }

  /// 移动端：进程由插件结束（`FlutterExitApp` / `Restart`）。同样先意图、再 clean，
  /// 最后 await 插件调用。
  Future<void> terminateVia(
    String terminatedBy,
    Future<void> Function() kill,
  ) async {
    begin(terminatedBy);
    _marker.cleanExit(terminatedBy);
    await kill();
  }
}
