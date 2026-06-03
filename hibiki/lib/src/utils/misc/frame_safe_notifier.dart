import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 让 [ChangeNotifier] 的通知在帧渲染期（build / layout / paint）也能安全发出。
///
/// 错误水槽这类通知源会从 [FlutterError.onError] 在 **paint 阶段** 被回调
/// （例如 RenderFlex 溢出指示器在 paint 期间报错 → onError → 写日志 →
/// 通知监听者）。若此刻同步 [notifyListeners]，监听者的 `setState` 会在
/// 帧中途排程 build，被框架判定为 "Build scheduled during frame"，把一次
/// 无害事件升级成框架级错误；当溢出每帧复现时，更会引发"日志→重建→再日志"
/// 的每帧重建/文件 IO 风暴。
///
/// 本 mixin 仅在检测到处于 [SchedulerPhase.persistentCallbacks]
/// （build/layout/paint 窗口）时，把通知推迟到本帧渲染结束后的 post-frame
/// 回调里发出；其余阶段（idle / 动画 transient / post-frame）保持同步通知，
/// 对外行为不变。
mixin FrameSafeNotifier on ChangeNotifier {
  /// 与 [notifyListeners] 等价，但保证不会在 build/layout/paint 期间同步触发
  /// 监听者重建。
  void notifyListenersFrameSafe() {
    final SchedulerBinding scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      // 正处于本帧的渲染管线中；post-frame 回调会在本帧渲染结束后、
      // setState 安全的阶段运行。
      scheduler.addPostFrameCallback((Duration _) => notifyListeners());
    } else {
      notifyListeners();
    }
  }
}
