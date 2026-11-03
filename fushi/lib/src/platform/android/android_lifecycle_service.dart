import 'package:flutter_exit_app/flutter_exit_app.dart';
import 'package:fushi_platform/fushi_platform.dart';
import 'package:fushi/src/platform/app_exit_coordinator.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:restart_app/restart_app.dart';

class AndroidLifecycleService implements PlatformLifecycleService {
  @override
  bool get supportsRestart => true;

  @override
  Future<void> restartApp() async {
    await AppExitCoordinator.instance.terminateVia('restart', () async {
      await Restart.restartApp();
    });
  }

  @override
  Future<void> exitApp() async {
    await AppExitCoordinator.instance.terminateVia('exitApp', () async {
      await FlutterExitApp.exitApp();
    });
  }

  @override
  Future<void> moveTaskToBack() async =>
      FushiChannels.lifecycle.invokeMethod<void>('moveTaskToBack');
}
