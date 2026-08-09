abstract class PlatformLifecycleService {
  Future<void> restartApp();
  Future<void> exitApp();
  Future<void> moveTaskToBack();
  bool get supportsRestart;
}
