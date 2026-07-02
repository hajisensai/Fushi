import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki_platform/hibiki_platform.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/platform/desktop/windows_native_pre_exit.dart';

class DesktopLifecycleService implements PlatformLifecycleService {
  const DesktopLifecycleService();

  /// 重启时附加给新进程的命令行标志（TODO-959）。新进程的 [main] 见到它就在启动后
  /// 主动 `windowManager.show()` + `focus()` 抢前台——分离启动（detached）的新进程在
  /// Windows 上不一定自动获得前台焦点，否则数据迁移重启会出现短暂黑/不可见窗口。
  static const String restartMarkerArg = '--hibiki-restarted';

  /// 桌面端通过「分离启动自身可执行文件 + 退出当前进程」实现重启（TODO-935 E3）。
  /// 复用更新器同款手法（`platform_updater.dart` 的 `Process.start(detached)`）。
  @override
  bool get supportsRestart => true;

  /// 重启：先分离启动一份新进程，确认起来了再走与 [exitApp] 完全一致的干净退出序列。
  /// **只有新进程确认启动后才 `exit(0)`**——若 `Process.start` 抛错则**不退出**
  /// （避免「老进程没了、新进程也没起来」=用户感知为崩溃），把异常抛给调用方降级
  /// 提示用户手动重开。
  @override
  Future<void> restartApp() async {
    // 透传重启参数 + 重启标志（让新进程启动后抢前台，避免迁移重启出现黑/不可见窗口）。
    final List<String> args = <String>[
      restartMarkerArg,
      ...restartArgumentsOverride(),
    ];
    if (Platform.isMacOS) {
      final String appBundle =
          macOSAppBundlePathForExecutable(Platform.resolvedExecutable);
      // macOS sandboxed apps must be relaunched as an app bundle through
      // LaunchServices. Starting Contents/MacOS/<exe> directly from the
      // existing app process can crash in libsystem_secinit before Dart starts.
      await Process.start(
        '/usr/bin/open',
        <String>['-n', appBundle, '--args', ...args],
        mode: ProcessStartMode.detached,
      );
    } else {
      final String executable = Platform.resolvedExecutable;
      // 分离模式：新进程不随当前进程退出而被回收。Process.start 抛错则不退出。
      await Process.start(executable, args, mode: ProcessStartMode.detached);
    }
    // 新进程已成功 spawn（未抛错）→ 走与 exitApp 相同的退出闸门。
    await WindowsNativePreExit.prepareForExit(WindowsExitReason.windowClose);
    exit(0);
  }

  @visibleForTesting
  static String macOSAppBundlePathForExecutable(String executable) {
    Directory current = File(executable).absolute.parent;
    while (true) {
      if (p.extension(current.path) == '.app') {
        return current.path;
      }
      final Directory parent = current.parent;
      if (parent.path == current.path) {
        throw StateError(
          'Cannot find .app bundle for macOS executable: $executable',
        );
      }
      current = parent;
    }
  }

  /// 取重启后透传给新进程的命令行参数。默认空（桌面发布构建无应用级参数）。
  /// 暴露为可覆盖钩子仅供测试断言重启不附加意外参数。
  @visibleForTesting
  static List<String> Function() restartArgumentsOverride =
      _defaultRestartArguments;

  static List<String> _defaultRestartArguments() => const <String>[];

  @override
  Future<void> exitApp() async {
    await WindowsNativePreExit.prepareForExit(WindowsExitReason.windowClose);
    exit(0);
  }

  @override
  Future<void> moveTaskToBack() async {}
}
