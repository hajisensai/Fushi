import 'package:flutter_exit_app/flutter_exit_app.dart';
import 'package:fushi_platform/fushi_platform.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';
import 'package:restart_app/restart_app.dart';

class IosLifecycleService implements PlatformLifecycleService {
  @override
  bool get supportsRestart => true;

  @override
  Future<void> restartApp() async {
    PreviousExitLog.markCleanExit();
    await Restart.restartApp();
  }

  @override
  Future<void> exitApp() async {
    PreviousExitLog.markCleanExit();
    await FlutterExitApp.exitApp();
  }

  @override
  Future<void> moveTaskToBack() async {}
}
