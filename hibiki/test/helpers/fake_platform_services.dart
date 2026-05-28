import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

// ── Recording fakes ────────────────────────────────────────────────────────
// Each fake records calls so tests can assert on platform interactions.
// Defaults mirror the old _Stub* behaviour: no I/O, no platform channels.

class FakeDirectoryService implements PlatformDirectoryService {
  String exportDir = '/tmp/hibiki-test';

  @override
  Future<String> getHibikiExportDirectory() async => exportDir;

  @override
  Future<List<String>> getExternalStorageDirectories() async => const [];

  @override
  Future<List<String>> getDefaultPickerDirectories(String mediaType) async =>
      const [];

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
  bool overlaysAllowed = false;
  bool requestOverlayCalled = false;

  @override
  Future<bool> hasExternalStoragePermission() async => hasExternalStorage;

  @override
  Future<bool> requestExternalStoragePermission() async => hasExternalStorage;

  @override
  Future<bool> hasCameraPermission() async => hasCamera;

  @override
  Future<bool> requestCameraPermission() async => hasCamera;

  @override
  Future<bool> canDrawOverlays() async => overlaysAllowed;

  @override
  Future<void> requestOverlayPermission() async {
    requestOverlayCalled = true;
  }
}

class FakeDeviceInfoService implements PlatformDeviceInfoService {
  int? sdk;
  String? model = 'test-device';
  String? os = 'test-os';

  @override
  Future<int?> get sdkVersion async => sdk;

  @override
  Future<String?> get deviceModel async => model;

  @override
  Future<String?> get osVersion async => os;
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
}) {
  return PlatformServices(
    directory: directory ?? FakeDirectoryService(),
    lifecycle: lifecycle ?? FakeLifecycleService(),
    clipboard: clipboard ?? FakeClipboardService(),
    permission: permission ?? FakePermissionService(),
    deviceInfo: deviceInfo ?? FakeDeviceInfoService(),
    createAnkiRepository: AnkiConnectRepository.new,
  );
}
