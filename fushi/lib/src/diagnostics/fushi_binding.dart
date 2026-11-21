// 生产启动用的 binding：在 [SchedulerBinding] 的两个要帧入口上给 [UiActivityProbe] 记账（BUG-4075）。
//
// 内存采样里 `build=` 只看得见经 BuildOwner 的重建要帧、`tick=` 只看得见元素树里 State 持有的
// ticker；#w-MhvbxSFc 停在牌组列表 120 fps 出帧时两者都是空的。剩下的要帧来源（State 已 dispose
// 却被异步回调重新启动的孤儿 ticker、非 State 的帧回调、render object 在帧外弄脏）全都经
// [scheduleFrameCallback] / [scheduleFrame]，这里是唯一能在 release 包里把它们点名的位置。
//
// 要帧入口只记账、不改行为：两个覆写都原样调 super。调度策略换成
// [ambientAwareSchedulingStrategy]（BUG-4387），见 [ensureInitialized]；被策略推迟的任务
// 按帧节拍重查、不零延迟空转（[FramePacedTaskScheduler]，BUG-4725）。副引擎入口用只带
// 调度修复的 [FushiSecondaryWidgetsFlutterBinding]。
//
// 另挂 [AxTreeDesyncSentinel]（BUG-4073）：桌面端逐帧复核发往引擎 AXTree 的语义更新，
// 让引擎失步的帧记进错误日志（引擎自己的报错只进 stderr）。只诊断、不改下发内容。
// 一个进程只能有一个 binding，所以要帧归因与语义哨兵都收在这一个类里。

import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/diagnostics/ui_activity_probe.dart';
import 'package:fushi/src/utils/misc/semantics_ax_tree_contract.dart';
import 'package:fushi/src/utils/scheduling/ambient_ticker.dart';
import 'package:fushi/src/utils/scheduling/frame_paced_task_scheduler.dart';

/// [WidgetsFlutterBinding] + 要帧归因 + AXTree 失步哨兵。仍是 [WidgetsFlutterBinding] 子类（`is WidgetsFlutterBinding`
/// 的判断不变）。
class FushiWidgetsFlutterBinding extends WidgetsFlutterBinding
    with FramePacedTaskScheduler {
  /// 还没有 binding 时建一个本类；已有（integration_test / flutter_test 先建了自己的 binding 再调
  /// `main()`）时原样返回已有的，不另建。
  ///
  /// 无论 binding 是谁建的，都把调度策略换成 [ambientAwareSchedulingStrategy]：常驻装饰
  /// 动画不算「忙」，否则 [Priority.idle] 任务让调度器零延迟定时器无限空转、Windows
  /// 主线程被 WM_NULL 唤醒淹没、输入全丢（BUG-4387）。集成测试走同一条入口，行为与生产一致。
  static WidgetsBinding ensureInitialized() =>
      _ensureSchedulingBinding(FushiWidgetsFlutterBinding.new);

  @override
  int scheduleFrameCallback(
    FrameCallback callback, {
    bool rescheduling = false,
    bool scheduleNewFrame = true,
  }) {
    UiActivityProbe.beginFrameCallbackRegistration(
      callback,
      rescheduling: rescheduling,
    );
    try {
      return super.scheduleFrameCallback(
        callback,
        rescheduling: rescheduling,
        scheduleNewFrame: scheduleNewFrame,
      );
    } finally {
      UiActivityProbe.endFrameCallbackRegistration();
    }
  }

  @override
  void scheduleFrame() {
    if (!hasScheduledFrame && framesEnabled) {
      UiActivityProbe.recordFrameRequest();
    }
    super.scheduleFrame();
  }

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      AxTreeDesyncSentinel.wrap(super.createSemanticsUpdateBuilder());
}

/// 副引擎入口（悬浮查词 `floatingDictMain`、弹窗 `popupMain`、副屏 `secondScreenMain`）
/// 用的 binding：只带调度修复（[FramePacedTaskScheduler] + [ambientAwareSchedulingStrategy]），
/// 不带主引擎的要帧归因与 AXTree 哨兵。
///
/// 副引擎各有自己的 isolate 与 binding；用裸 [WidgetsFlutterBinding] 的话，框架或三方包在
/// 那里排的低优先级任务碰上常驻动画照样零延迟空转（BUG-4725 / BUG-4893）。`lib` 下不许再调
/// `WidgetsFlutterBinding.ensureInitialized()`（守卫 `test/build/ui_idle_wait_guard_test.dart`）。
class FushiSecondaryWidgetsFlutterBinding extends WidgetsFlutterBinding
    with FramePacedTaskScheduler {
  /// 同 [FushiWidgetsFlutterBinding.ensureInitialized]：没有 binding 时建一个本类，
  /// 已有时原样返回；都装上 [ambientAwareSchedulingStrategy]。
  static WidgetsBinding ensureInitialized() =>
      _ensureSchedulingBinding(FushiSecondaryWidgetsFlutterBinding.new);
}

/// 还没有 binding 时用 [create] 建一个；无论 binding 是谁建的，都把调度策略换成
/// [ambientAwareSchedulingStrategy]。
WidgetsBinding _ensureSchedulingBinding(WidgetsBinding Function() create) {
  if (!_bindingExists()) create();
  final WidgetsBinding binding = WidgetsBinding.instance;
  binding.schedulingStrategy = ambientAwareSchedulingStrategy;
  return binding;
}

/// [WidgetsBinding.instance] 在没有 binding 时 debug 抛 [FlutterError]、release 抛空值
/// [TypeError]（框架判空用的私有字段读不到，这是唯一的公开探法）。
bool _bindingExists() {
  try {
    WidgetsBinding.instance;
    return true;
  } on Error {
    return false;
  }
}
