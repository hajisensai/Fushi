import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

/// Returns a [PlatformServices] suitable for unit tests.
///
/// All services are no-op desktop stubs that do not require a running Android
/// environment.
PlatformServices testPlatformServices() => PlatformServices(
      directory: const _StubDirectoryService(),
      lifecycle: const _StubLifecycleService(),
      clipboard: const _StubClipboardService(),
      permission: const _StubPermissionService(),
      deviceInfo: const _StubDeviceInfoService(),
      createAnkiRepository: AnkiConnectRepository.new,
    );

// ── Lightweight stubs ──────────────────────────────────────────────────────
// These are intentionally minimal: no I/O, no platform channels, no state.

class _StubDirectoryService implements PlatformDirectoryService {
  const _StubDirectoryService();

  @override
  Future<String> getHibikiExportDirectory() async => '/tmp/hibiki-test';

  @override
  Future<List<String>> getExternalStorageDirectories() async => const [];

  @override
  Future<List<String>> getDefaultPickerDirectories(String mediaType) async =>
      const [];

  @override
  Future<void> excludeFromMediaScanner(String directoryPath) async {}
}

class _StubLifecycleService implements PlatformLifecycleService {
  const _StubLifecycleService();

  @override
  bool get supportsRestart => false;

  @override
  Future<void> restartApp() async {}

  @override
  Future<void> exitApp() async {}

  @override
  Future<void> moveTaskToBack() async {}
}

class _StubClipboardService implements PlatformClipboardService {
  const _StubClipboardService();

  @override
  Future<void> copyToClipboard(String text) async {}

  @override
  bool get shouldShowCopyToast => false;
}

class _StubPermissionService implements PlatformPermissionService {
  const _StubPermissionService();

  @override
  Future<bool> hasExternalStoragePermission() async => true;

  @override
  Future<bool> requestExternalStoragePermission() async => true;

  @override
  Future<bool> hasCameraPermission() async => true;

  @override
  Future<bool> requestCameraPermission() async => true;

  @override
  Future<bool> canDrawOverlays() async => false;

  @override
  Future<void> requestOverlayPermission() async {}
}

class _StubDeviceInfoService implements PlatformDeviceInfoService {
  const _StubDeviceInfoService();

  @override
  Future<int?> get sdkVersion async => null;

  @override
  Future<String?> get deviceModel async => 'test-device';

  @override
  Future<String?> get osVersion async => 'test-os';
}
