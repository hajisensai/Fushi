import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:macos_ui/macos_ui.dart' show WindowManipulator;

/// 隐藏 / 恢复 macOS 系统交通灯（关闭 / 最小化 / 缩放三个圆点）。
///
/// macOS 壳启动时开了透明标题栏 + 全尺寸内容视图（`main.dart` 的
/// `makeTitlebarTransparent` + `enableFullSizeContentView`），Flutter 内容一直画到
/// 窗口左上角，系统交通灯浮在其上（BUG-973：视频页的返回按钮 / 左上角 OSD 被遮）。
///
/// 现在（用户 2026-10-04 拍板）macOS **无论设计系统一律用系统原生红绿灯**：`main()`
/// 用 `setTitleBarStyle(hidden, windowButtonVisibility: Platform.isMacOS)` 隐藏原生
/// 标题栏但保留三个交通灯，自绘的 [FushiDesktopTitleBar] 在顶栏左侧给它们留位、不画
/// 自绘窗口按钮（Windows / Linux 才画 MD3 三键）。红绿灯的显隐只有一个真值：内容全屏
/// 收起顶栏时隐藏（否则三个圆点浮在视频 / 阅读内容左上角，BUG-973），其余时候显示。
/// 生产路径**只经** `FushiDesktopTitleBar.reassertMacTrafficLights()` 调用本函数，
/// 由它按内容全屏真值传 `hidden`；别处不要直接调（写死 true/false 会与真值打架）。
///
/// 底层是 `NSWindow.standardWindowButton(_).isHidden`（见 macos_window_utils 的
/// `MainFlutterWindowManipulator`），一个持久属性。只有 macOS 有交通灯，其它平台
/// （Windows / Linux 桌面、移动端）恒 no-op。任何 platform-channel 失败以 debug 日志
/// 吞掉，绝不因窗口按钮操作崩溃调用方。
///
/// ⚠️ 时序：AppKit 的 `toggleFullScreen` 进出原生全屏会重建标题栏视图、可能把
/// `isHidden` 复位。故不能「设一次」了事——退出原生全屏后需经
/// `reassertMacTrafficLights()` 按真值重申。重申点：内容全屏真值每次变化
/// （`setContentFullscreen`）、[FushiDesktopTitleBar] 监听 `MacosFullscreenState`
/// 的退全屏（覆盖快捷键 / 菜单 / 手势等**全部**入口，挂载时也跑一次），以及视频页
/// `_exitVideoNativeFullscreen`（media_kit 自己的退全屏路径，不经 app 的全屏开关）。
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
    debugPrint('[Fushi] macOS traffic light toggle skipped: $e');
  }
}
