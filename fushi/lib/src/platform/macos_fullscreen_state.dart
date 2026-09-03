import 'dart:io';

import 'package:flutter/foundation.dart';
// macos_ui re-exports both（见 `global_navigation.dart` 同款写法）；直接依赖
// macos_window_utils 会触发 depend_on_referenced_packages（它只是传递依赖）。
import 'package:macos_ui/macos_ui.dart'
    show NSWindowDelegate, WindowManipulator;

/// BUG-1744：macOS 原生全屏状态的**唯一真相源**。
///
/// 背景：macOS 壳给 NSWindow 开了透明标题栏 + full-size content，阅读器为此在
/// 顶部保留了一条 [kMacTitleBarHeight] 高的可拖拽带（BUG-1343），并让正文同高
/// 让位。但那条带子的唯一条件是 `Platform.isMacOS`——进原生全屏后既没有标题栏
/// 也没有交通灯，这条不透明带和它的正文让位却仍在，就是用户看到的「顶部横带」。
///
/// 为什么不复用别的信号：
/// - `WindowManipulator.isWindowFullscreened()` 是**异步查询**，没有变化通知，
///   拿它只能轮询。
/// - `window_manager` 的 [WindowListener] 在 macOS 上收不到全屏通知：
///   macos_window_utils 持有 NSWindow.delegate 并把 window_manager 的 delegate
///   覆盖掉（见 `global_navigation.dart` 的 TODO-1375）。
/// - 只在应用自己的 F11 快捷键里记状态会漏掉绿灯按钮和「显示」菜单——那是用户
///   进全屏最常用的两条路。
///
/// 所以直接挂 [NSWindowDelegate]：`windowDidEnter/ExitFullScreen` 由 AppKit 在
/// **所有**入口上发出，是唯一能覆盖全部路径的信号。
///
/// 非 macOS 平台恒为 false，且不注册任何 delegate。
class MacosFullscreenState {
  MacosFullscreenState._();

  static final MacosFullscreenState instance = MacosFullscreenState._();

  final ValueNotifier<bool> _isFullscreen = ValueNotifier<bool>(false);

  bool _registered = false;

  /// 当前是否处于 macOS 原生全屏。非 macOS 恒为 false。
  ValueListenable<bool> get isFullscreen => _isFullscreen;

  /// 幂等注册 NSWindow delegate。多次调用只注册一次。
  ///
  /// 首帧之前无从得知窗口是否已在全屏（例如系统恢复了上次的全屏会话），所以还会
  /// 补一次异步查询作为初值。
  Future<void> ensureRegistered() async {
    if (!Platform.isMacOS || _registered) return;
    _registered = true;
    try {
      WindowManipulator.addNSWindowDelegate(
        _FushiFullscreenDelegate(_isFullscreen),
      );
    } catch (e) {
      // 平台通道不可用（测试 / 未初始化的壳）时降级成「非全屏」，与旧行为一致。
      debugPrint('[Fushi] macOS fullscreen delegate skipped: $e');
      return;
    }
    try {
      _isFullscreen.value = await WindowManipulator.isWindowFullscreened();
    } catch (e) {
      debugPrint('[Fushi] macOS fullscreen initial query skipped: $e');
    }
  }

  /// 测试用：直接置位，不碰平台通道。
  @visibleForTesting
  void debugSet({required bool fullscreen}) {
    _isFullscreen.value = fullscreen;
  }
}

class _FushiFullscreenDelegate extends NSWindowDelegate {
  _FushiFullscreenDelegate(this._sink);

  final ValueNotifier<bool> _sink;

  @override
  void windowDidEnterFullScreen() {
    _sink.value = true;
    super.windowDidEnterFullScreen();
  }

  @override
  void windowDidExitFullScreen() {
    _sink.value = false;
    super.windowDidExitFullScreen();
  }
}
