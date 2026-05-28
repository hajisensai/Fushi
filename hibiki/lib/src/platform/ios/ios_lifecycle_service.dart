import 'package:flutter_exit_app/flutter_exit_app.dart';
import 'package:hibiki_platform/hibiki_platform.dart';
import 'package:restart_app/restart_app.dart';

class IosLifecycleService implements PlatformLifecycleService {
  @override
  bool get supportsRestart => true;

  @override
  Future<void> restartApp() async => Restart.restartApp();

  @override
  Future<void> exitApp() async => FlutterExitApp.exitApp();

  @override
  Future<void> moveTaskToBack() async {}
}
