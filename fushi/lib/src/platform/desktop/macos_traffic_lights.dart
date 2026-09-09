import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:macos_ui/macos_ui.dart' show WindowManipulator;

/// 隐藏 / 恢复 macOS 系统交通灯（关闭 / 最小化 / 缩放三个圆点）。
///
/// macOS 壳启动时开了透明标题栏 + 全尺寸内容视图（`main.dart` 的
/// `makeTitlebarTransparent` + `enableFullSizeContentView`），Flutter 内容一直画到
/// 窗口左上角，系统交通灯浮在其上（BUG-973：视频页的返回按钮 / 左上角 OSD 被遮）。
///
/// 现在交通灯是**启动即永久隐藏**：`main()` 用
/// `setTitleBarStyle(hidden, windowButtonVisibility: false)` 一次性关掉它们，窗口
/// 控制改由自绘的 [FushiDesktopTitleBar] MD3 顶栏提供。所以本函数只剩一个用途——
/// **重申隐藏**（见下面的时序告警）；`hidden: false` 分支只作为对称 API 保留，
/// 生产路径不再调用它（调了就等于把三个系统圆点放回顶栏之上）。
///
/// 底层是 `NSWindow.standardWindowButton(_).isHidden`（见 macos_window_utils 的
/// `MainFlutterWindowManipulator`），一个持久属性。只有 macOS 有交通灯，其它平台
/// （Windows / Linux 桌面、移动端）恒 no-op。任何 platform-channel 失败以 debug 日志
/// 吞掉，绝不因窗口按钮操作崩溃调用方。
///
/// ⚠️ 时序：AppKit 的 `toggleFullScreen` 进出原生全屏会重建标题栏视图、可能把
/// `isHidden` 复位。故不能「隐藏一次」了事——退出原生全屏后需重新调用本函数断言隐藏。
/// 两个重申点：[FushiDesktopTitleBar] 监听 `MacosFullscreenState`（覆盖快捷键 /
/// 菜单 / 手势等**全部**入口），视频页在 `_exitVideoNativeFullscreen` 里另有一次
/// （media_kit 自己的退全屏路径，不经 app 的全屏开关）。
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
