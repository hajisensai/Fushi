import 'dart:io';

import 'package:hibiki_platform/hibiki_platform.dart';

class DesktopLifecycleService implements PlatformLifecycleService {
  @override
  bool get supportsRestart => false;

  @override
  Future<void> restartApp() async {}

  @override
  Future<void> exitApp() async => exit(0);

  @override
  Future<void> moveTaskToBack() async {}
}
