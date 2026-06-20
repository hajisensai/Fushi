import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows 进程退出前的 native teardown 钩子。
///
/// 同一个 native `prepareForProcessExit`（清空 webViews / 释放共享合成资源）被两条
/// 互不相交的退出路径触发：
///   - 更新路径：`PlatformUpdater` 启动 launcher 后让出本进程（`platform_updater.dart`）。
///   - 关窗路径：用户直接关闭窗口走 `DesktopLifecycleService.exitApp`（经 `main.dart`
///     的 `exitApp`）。
///
/// 两条路径**各自**需要一次性保护（避免同一路径内重复触发 channel），但**不能**共享同一个
/// 一次性守卫——否则走过更新预检（置位守卫）后再关窗，关窗路径会被静默短路，native
/// teardown 落空，触发退出期 `Unknown Hard Error`（TODO-618 根因 A1）。
///
/// 因此这里按「退出原因」拆成独立守卫：每条路径首次进入都会真正发出一次 channel 调用。
/// native 端 `prepareForProcessExit` 本身对重复调用幂等
/// （`releaseSharedCompositionResources`/`composition_released_` 幂等 + fix3 的
/// `g_process_exiting` 进程级总闸），所以即使两条路径都被触发，重复的 native 调用也是
/// 安全的 no-op。
enum WindowsExitReason {
  /// 应用更新：启动 launcher 后让出本进程。
  update,

  /// 用户关闭窗口 / 正常退出应用。
  windowClose,
}

class WindowsNativePreExit {
  static const MethodChannel _channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_manager');

  /// 每条退出路径独立的一次性守卫。同一路径内重复调用短路，但不同路径互不影响。
  static final Set<WindowsExitReason> _preparedReasons = <WindowsExitReason>{};

  /// 平台判定钩子。生产恒为 `Platform.isWindows`；测试可覆盖以在任意平台验证守卫解耦逻辑。
  @visibleForTesting
  static bool Function() isWindows = () => Platform.isWindows;

  @visibleForTesting
  static void resetForTesting() {
    _preparedReasons.clear();
    isWindows = () => Platform.isWindows;
  }

  static Future<void> prepareForExit(WindowsExitReason reason) async {
    if (!isWindows()) return;
    // 仅短路同一退出路径的重复触发；走过更新路径后关窗路径仍会真正发出 channel 调用。
    if (!_preparedReasons.add(reason)) return;

    try {
      await _channel.invokeMethod<void>('prepareForProcessExit');
    } on MissingPluginException catch (e) {
      debugPrint('[Hibiki] Windows native pre-exit hook unavailable: $e');
    } on PlatformException catch (e) {
      debugPrint('[Hibiki] Windows native pre-exit hook failed: $e');
    } catch (e) {
      debugPrint('[Hibiki] Windows native pre-exit hook failed: $e');
    }
  }
}
