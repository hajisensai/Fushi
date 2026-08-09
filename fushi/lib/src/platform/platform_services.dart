import 'dart:io' show Platform;

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_platform/fushi_platform.dart';

import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi/src/platform/android/android_directory_service.dart';
import 'package:fushi/src/platform/android/android_lifecycle_service.dart';
import 'package:fushi/src/platform/android/android_clipboard_service.dart';
import 'package:fushi/src/platform/android/android_permission_service.dart';
import 'package:fushi/src/platform/android/android_device_info_service.dart';
import 'package:fushi/src/platform/desktop/desktop_directory_service.dart';
import 'package:fushi/src/platform/desktop/desktop_lifecycle_service.dart';
import 'package:fushi/src/platform/desktop/desktop_clipboard_service.dart';
import 'package:fushi/src/platform/desktop/desktop_permission_service.dart';
import 'package:fushi/src/platform/desktop/desktop_device_info_service.dart';
import 'package:fushi/src/platform/ios/ios_directory_service.dart';
import 'package:fushi/src/platform/ios/ios_lifecycle_service.dart';
import 'package:fushi/src/platform/ios/ios_clipboard_service.dart';
import 'package:fushi/src/platform/ios/ios_permission_service.dart';
import 'package:fushi/src/platform/ios/ios_device_info_service.dart';

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
  final BaseAnkiRepository Function() _createDefaultAnkiRepository;
  final BaseAnkiRepository Function()? _createAndroidAnkiConnectRepository;
  final bool _isAndroid;
  bool _useAnkiConnectOnAndroid = false;

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
    required BaseAnkiRepository Function() createAnkiRepository,
    BaseAnkiRepository Function()? createAndroidAnkiConnectRepository,
    bool isAndroid = false,
    AndroidClipboardService? androidClipboard,
  })  : _createDefaultAnkiRepository = createAnkiRepository,
        _createAndroidAnkiConnectRepository =
            createAndroidAnkiConnectRepository,
        _isAndroid = isAndroid,
        _androidClipboard = androidClipboard,
        assert(
          !isAndroid || createAndroidAnkiConnectRepository != null,
          'Android requires an AnkiConnect repository factory.',
        );

  /// Creates the active Anki backend. Android keeps AnkiDroid as the upgrade-
  /// safe default, but may explicitly opt into a reachable AnkiConnect server.
  BaseAnkiRepository createAnkiRepository() {
    if (_isAndroid && _useAnkiConnectOnAndroid) {
      return _createAndroidAnkiConnectRepository!();
    }
    return _createDefaultAnkiRepository();
  }

  bool get useAnkiConnectOnAndroid => _isAndroid && _useAnkiConnectOnAndroid;

  void setUseAnkiConnectOnAndroid(
    bool value, {
    String apiKey = '',
  }) {
    if (!_isAndroid) return;
    _useAnkiConnectOnAndroid = value && apiKey.trim().isNotEmpty;
  }

  /// Cross-service wiring that requires async initialisation.
  ///
  /// Must be called once during app startup (e.g. in [AppModel.initialise])
  /// after all services are constructed.
  Future<void> init() async {
    await _androidClipboard?.init();
    if (_isAndroid) {
      final AnkiSettings settings =
          await _createDefaultAnkiRepository().loadSettings();
      setUseAnkiConnectOnAndroid(
        settings.useAnkiConnectOnAndroid,
        apiKey: settings.ankiConnectApiKey,
      );
      if (settings.useAnkiConnectOnAndroid && !_useAnkiConnectOnAndroid) {
        await _createDefaultAnkiRepository().updateSettings(
          (AnkiSettings current) =>
              current.copyWith(useAnkiConnectOnAndroid: false),
        );
      }
    }
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
        permission: AndroidPermissionService(deviceInfo),
        deviceInfo: deviceInfo,
        createAnkiRepository: AnkiRepository.new,
        createAndroidAnkiConnectRepository: AnkiConnectRepository.new,
        isAndroid: true,
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
        createAnkiRepository: AnkiMobileRepository.new,
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
