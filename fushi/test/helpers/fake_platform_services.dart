import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_platform/fushi_platform.dart';

// ── Recording fakes ────────────────────────────────────────────────────────
// Each fake records calls so tests can assert on platform interactions.
// Defaults mirror the old _Stub* behaviour: no I/O, no platform channels.

class FakeDirectoryService implements PlatformDirectoryService {
  @override
  Future<List<String>> getExternalStorageDirectories() async => const [];

  @override
  Future<List<String>> getDefaultPickerDirectories() async => const [];

  @override
  Future<void> excludeFromMediaScanner(String directoryPath) async {}
}

class FakeLifecycleService implements PlatformLifecycleService {
  bool restartCalled = false;
  bool exitCalled = false;
  bool moveTaskToBackCalled = false;
  bool supportsRestartValue = false;

  @override
  bool get supportsRestart => supportsRestartValue;

  @override
  Future<void> restartApp() async {
    restartCalled = true;
  }

  @override
  Future<void> exitApp() async {
    exitCalled = true;
  }

  @override
  Future<void> moveTaskToBack() async {
    moveTaskToBackCalled = true;
  }
}

class FakeClipboardService implements PlatformClipboardService {
  String? lastCopied;
  bool shouldShowCopyToastValue = false;

  @override
  Future<void> copyToClipboard(String text) async {
    lastCopied = text;
  }

  @override
  bool get shouldShowCopyToast => shouldShowCopyToastValue;
}

class FakePermissionService implements PlatformPermissionService {
  bool hasExternalStorage = true;
  bool hasCamera = true;

  @override
  Future<bool> hasExternalStoragePermission() async => hasExternalStorage;

  @override
  Future<bool> requestExternalStoragePermission() async => hasExternalStorage;

  @override
  Future<bool> hasCameraPermission() async => hasCamera;

  @override
  Future<bool> requestCameraPermission() async => hasCamera;
}

class FakeDeviceInfoService implements PlatformDeviceInfoService {
  int? sdk;
  String? model = 'test-device';
  String? maker;

  @override
  Future<int?> get sdkVersion async => sdk;

  @override
  Future<String?> get deviceModel async => model;

  @override
  Future<String?> get manufacturer async => maker;
}

// ── Builder ────────────────────────────────────────────────────────────────

/// Builds a [PlatformServices] from recording fakes. Pass in pre-configured
/// fakes to assert interactions, or omit to use fresh defaults.
PlatformServices fakePlatformServices({
  FakeDirectoryService? directory,
  FakeLifecycleService? lifecycle,
  FakeClipboardService? clipboard,
  FakePermissionService? permission,
  FakeDeviceInfoService? deviceInfo,
  BaseAnkiRepository Function()? createAnkiRepository,
  BaseAnkiRepository Function()? createMobileAnkiConnectRepository,
  // 需要感知注入的设置存储（按配置视图建仓库）的测试用这个；与
  // [createAnkiRepository] 二选一。
  AnkiRepositoryFactory? ankiRepositoryFactory,
  bool isMobile = false,
  bool? isWindows,
  bool? isDesktop,
  bool? isIOS,
  bool? isAndroid,
}) {
  return PlatformServices(
    directory: directory ?? FakeDirectoryService(),
    lifecycle: lifecycle ?? FakeLifecycleService(),
    clipboard: clipboard ?? FakeClipboardService(),
    permission: permission ?? FakePermissionService(),
    deviceInfo: deviceInfo ?? FakeDeviceInfoService(),
    createAnkiRepository:
        ankiRepositoryFactory ??
        (createAnkiRepository == null
            ? AnkiConnectRepository.new
            : ({AnkiSettingsStore? settingsStore}) => createAnkiRepository()),
    createMobileAnkiConnectRepository: createMobileAnkiConnectRepository == null
        ? null
        : ({AnkiSettingsStore? settingsStore}) =>
              createMobileAnkiConnectRepository(),
    isMobile: isMobile,
    isWindows: isWindows,
    isDesktop: isDesktop,
    isIOS: isIOS,
    isAndroid: isAndroid,
  );
}
