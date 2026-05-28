import 'dart:io' show Platform;

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

  const PlatformServices({
    required this.directory,
    required this.lifecycle,
    required this.clipboard,
    required this.permission,
    required this.deviceInfo,
  });

  /// Constructs the correct service bundle for the current platform.
  factory PlatformServices.forCurrentPlatform() {
    if (Platform.isAndroid) {
      return PlatformServices(
        directory: AndroidDirectoryService(),
        lifecycle: AndroidLifecycleService(),
        clipboard: AndroidClipboardService(),
        permission: AndroidPermissionService(),
        deviceInfo: AndroidDeviceInfoService(),
      );
    }
    // iOS will be added later — for now, desktop defaults cover all
    // non-Android platforms (Windows, macOS, Linux, iOS fallback).
    return PlatformServices(
      directory: DesktopDirectoryService(),
      lifecycle: DesktopLifecycleService(),
      clipboard: DesktopClipboardService(),
      permission: DesktopPermissionService(),
      deviceInfo: DesktopDeviceInfoService(),
    );
  }
}
