import 'dart:io';

import 'package:hibiki_platform/hibiki_platform.dart';

import 'package:hibiki/src/platform/desktop/windows_native_pre_exit.dart';

class DesktopLifecycleService implements PlatformLifecycleService {
  @override
  bool get supportsRestart => false;

  @override
  Future<void> restartApp() async {}

  @override
  Future<void> exitApp() async {
    await WindowsNativePreExit.prepareForExit();
    exit(0);
  }

  @override
  Future<void> moveTaskToBack() async {}
}
