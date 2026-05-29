import 'dart:io' show Platform;

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

import 'package:hibiki/src/platform/android/android_directory_service.dart';
import 'package:hibiki/src/platform/android/android_lifecycle_service.dart';
import 'package:hibiki/src/platform/android/android_clipboard_service.dart';
import 'package:hibiki/src/platform/android/android_permission_service.dart';
import 'package:hibiki/src/platform/android/android_device_info_service.dart';
import 'package:hibiki/src/platform/desktop/desktop_directory_service.dart';
import 'package:hibiki/src/platform/desktop/desktop_lifecycle_service.dart';
import 'package:hibiki/src/platform/desktop/desktop_clipboard_service.dart';
import 'package:hibiki/src/platform/desktop/desktop_permission_service.dart';
import 'package:hibiki/src/platform/desktop/desktop_device_info_service.dart';
import 'package:hibiki/src/platform/ios/ios_directory_service.dart';
import 'package:hibiki/src/platform/ios/ios_lifecycle_service.dart';
import 'package:hibiki/src/platform/ios/ios_clipboard_service.dart';
import 'package:hibiki/src/platform/ios/ios_permission_service.dart';
import 'package:hibiki/src/platform/ios/ios_device_info_service.dart';

/// Holds all platform-specific service implementations.
///
/// Created once in `main()` before `runApp()` and passed to [AppModel] as a
/// constructor parameter. This avoids the need for `AppModel` to know which
/// platform it runs on or to hold a `Ref`.
class PlatformServices {
  final PlatformDirectoryService directory;
  final PlatformLifecycleService lifecycle;
  final PlatformClipboardService clipboard;
  final PlatformPermissionService permission;
  final PlatformDeviceInfoService deviceInfo;
  final BaseAnkiRepository Function() createAnkiRepository;

  /// Typed reference to the Android clipboard impl, when running on Android.
  /// Holding the concrete type here (rather than an `is`/`as` downcast in
  /// [init]) makes the SDK-version dependency explicit and turns an impl
  /// rename/swap into a compile error instead of a silent no-op (HBK-AUDIT-134).
  final AndroidClipboardService? _androidClipboard;

  PlatformServices({
    required this.directory,
    required this.lifecycle,
    required this.clipboard,
    required this.permission,
    required this.deviceInfo,
    required this.createAnkiRepository,
    AndroidClipboardService? androidClipboard,
  }) : _androidClipboard = androidClipboard;

  /// Cross-service wiring that requires async initialisation.
  ///
  /// Must be called once during app startup (e.g. in [AppModel.initialise])
  /// after all services are constructed.
  Future<void> init() async {
    await _androidClipboard?.init();
  }

  /// Constructs the correct service bundle for the current platform.
  factory PlatformServices.forCurrentPlatform() {
    if (Platform.isAndroid) {
      final AndroidDeviceInfoService deviceInfo = AndroidDeviceInfoService();
      final AndroidClipboardService clipboard =
          AndroidClipboardService(deviceInfo);
      return PlatformServices(
        directory: AndroidDirectoryService(),
        lifecycle: AndroidLifecycleService(),
        clipboard: clipboard,
        permission: AndroidPermissionService(),
        deviceInfo: deviceInfo,
        createAnkiRepository: AnkiRepository.new,
        androidClipboard: clipboard,
      );
    }
    if (Platform.isIOS) {
      return PlatformServices(
        directory: IosDirectoryService(),
        lifecycle: IosLifecycleService(),
        clipboard: IosClipboardService(),
        permission: IosPermissionService(),
        deviceInfo: IosDeviceInfoService(),
        createAnkiRepository: AnkiConnectRepository.new,
      );
    }
    return PlatformServices(
      directory: DesktopDirectoryService(),
      lifecycle: DesktopLifecycleService(),
      clipboard: DesktopClipboardService(),
      permission: DesktopPermissionService(),
      deviceInfo: DesktopDeviceInfoService(),
      createAnkiRepository: AnkiConnectRepository.new,
    );
  }
}
