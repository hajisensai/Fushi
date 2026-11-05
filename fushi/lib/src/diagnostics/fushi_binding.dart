// 生产启动用的 binding：在 [SchedulerBinding] 的两个要帧入口上给 [UiActivityProbe] 记账（BUG-4075）。
//
// 内存采样里 `build=` 只看得见经 BuildOwner 的重建要帧、`tick=` 只看得见元素树里 State 持有的
// ticker；#w-MhvbxSFc 停在牌组列表 120 fps 出帧时两者都是空的。剩下的要帧来源（State 已 dispose
// 却被异步回调重新启动的孤儿 ticker、非 State 的帧回调、render object 在帧外弄脏）全都经
// [scheduleFrameCallback] / [scheduleFrame]，这里是唯一能在 release 包里把它们点名的位置。
//
// 只记账、不改行为：两个覆写都原样调 super。

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/diagnostics/ui_activity_probe.dart';

/// [WidgetsFlutterBinding] + 要帧归因。仍是 [WidgetsFlutterBinding] 子类（`is WidgetsFlutterBinding`
/// 的判断不变）。
class FushiWidgetsFlutterBinding extends WidgetsFlutterBinding {
  /// 还没有 binding 时建一个本类；已有（integration_test / flutter_test 先建了自己的 binding 再调
  /// `main()`）时原样返回已有的，不另建。
  static WidgetsBinding ensureInitialized() {
    if (!_bindingExists()) FushiWidgetsFlutterBinding();
    return WidgetsBinding.instance;
  }

  /// [WidgetsBinding.instance] 在没有 binding 时 debug 抛 [FlutterError]、release 抛空值
  /// [TypeError]（框架判空用的私有字段读不到，这是唯一的公开探法）。
  static bool _bindingExists() {
    try {
      WidgetsBinding.instance;
      return true;
    } on Error {
      return false;
    }
  }

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
}
