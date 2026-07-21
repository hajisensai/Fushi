import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:macos_ui/macos_ui.dart' show WindowManipulator;

/// 隐藏 / 恢复 macOS 系统交通灯（关闭 / 最小化 / 缩放三个圆点）。
///
/// macOS 壳启动时开了透明标题栏 + 全尺寸内容视图（`main.dart` 的
/// `makeTitlebarTransparent` + `enableFullSizeContentView`），Flutter 内容一直画到
/// 窗口左上角，系统交通灯浮在其上。视频页把「退出 / 返回」按钮和左上角 OSD 提示画在
/// 同一位置会被交通灯遮住（BUG-973 用户报告）。视频页全程隐藏交通灯即根除遮挡——
/// 用户仍可用 Esc / 顶栏返回按钮 / Cmd+Q / 进原生全屏退出，不损失任何退出口。
///
/// 底层是 `NSWindow.standardWindowButton(_).isHidden`（见 macos_window_utils 的
/// `MainFlutterWindowManipulator`），一个持久属性。只有 macOS 有交通灯，其它平台
/// （Windows / Linux 桌面、移动端）恒 no-op。任何 platform-channel 失败以 debug 日志
/// 吞掉，绝不因窗口按钮操作崩溃调用方。
///
/// ⚠️ 时序：AppKit 的 `toggleFullScreen` 进出原生全屏会重建标题栏视图、可能把
/// `isHidden` 复位。故不能「隐藏一次」了事——退出原生全屏后需重新调用本函数断言隐藏
/// （视频页在 `_exitVideoNativeFullscreen` 处理）。
Future<void> setMacOSTrafficLightsHidden(bool hidden) async {
  if (!Platform.isMacOS) {
    return;
  }
  try {
    if (hidden) {
      await WindowManipulator.hideCloseButton();
      await WindowManipulator.hideMiniaturizeButton();
      await WindowManipulator.hideZoomButton();
    } else {
      await WindowManipulator.showCloseButton();
      await WindowManipulator.showMiniaturizeButton();
      await WindowManipulator.showZoomButton();
    }
  } catch (e) {
    debugPrint('[Hibiki] macOS traffic light toggle skipped: $e');
  }
}
