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
  final BaseAnkiRepository Function()? _createMobileAnkiConnectRepository;

  /// 本平台的原生 Anki 后端是否受限、因而提供「改用 AnkiConnect」这条路
  /// （Android 的 AnkiDroid / iOS 的 AnkiMobile 都是）。桌面本来就走 AnkiConnect，
  /// 没有这条支路。
  final bool _isMobile;
  bool _useAnkiConnectOnMobile = false;

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
    BaseAnkiRepository Function()? createMobileAnkiConnectRepository,
    bool isMobile = false,
    AndroidClipboardService? androidClipboard,
  })  : _createDefaultAnkiRepository = createAnkiRepository,
        _createMobileAnkiConnectRepository = createMobileAnkiConnectRepository,
        _isMobile = isMobile,
        _androidClipboard = androidClipboard,
        assert(
          !isMobile || createMobileAnkiConnectRepository != null,
          'Mobile requires an AnkiConnect repository factory.',
        );

  /// Creates the active Anki backend. 移动端保留各自的原生后端（AnkiDroid /
  /// AnkiMobile）作为升级安全的默认值，但可显式改用一台可达的 AnkiConnect。
  BaseAnkiRepository createAnkiRepository() {
    if (_isMobile && _useAnkiConnectOnMobile) {
      return _createMobileAnkiConnectRepository!();
    }
    return _createDefaultAnkiRepository();
  }

  bool get useAnkiConnectOnMobile => _isMobile && _useAnkiConnectOnMobile;

  /// 本平台是否提供「改用 AnkiConnect」这个选项（设置页据此显示开关）。
  bool get offersMobileAnkiConnectChoice => _isMobile;

  /// 运行时后端选择。判据只有 [AnkiSettings.ankiConnectUsableOnMobile] 一份——
  /// 这里不再自己写一遍 `value && apiKey.isNotEmpty`，否则与 UI 门控、启动期修复
  /// 三处迟早漂开（BUG-1608）。
  void setUseAnkiConnectOnMobile(
    bool value, {
    String apiKey = '',
  }) {
    if (!_isMobile) return;
    _useAnkiConnectOnMobile = AnkiSettings(
      useAnkiConnectOnMobile: value,
      ankiConnectApiKey: apiKey,
    ).ankiConnectUsableOnMobile;
  }

  /// Cross-service wiring that requires async initialisation.
  ///
  /// Must be called once during app startup (e.g. in [AppModel.initialise])
  /// after all services are constructed.
  Future<void> init() async {
    await _androidClipboard?.init();
    if (_isMobile) {
      final AnkiSettings settings =
          await _createDefaultAnkiRepository().loadSettings();
      setUseAnkiConnectOnMobile(
        settings.useAnkiConnectOnMobile,
        apiKey: settings.ankiConnectApiKey,
      );
      // 存量坏状态修复：开关记着 true 但 key 空（BUG-1608 之前的版本允许出现这种
      // 组合）。把存储对齐到运行时事实——运行时已经回落原生后端了，存储再声称
      // 「开着」只会让设置页显示一个不生效的开关。
      //
      // 这条**只**为老数据兜底：BUG-1608 之后，清空 key 的那一刻设置页就会立即
      // 关掉开关并明确告知用户，正常路径不再产生这种组合，所以这里静默改写不会
      // 再在用户眼皮底下发生。
      if (settings.useAnkiConnectOnMobile && !_useAnkiConnectOnMobile) {
        await _createDefaultAnkiRepository().updateSettings(
          (AnkiSettings current) =>
              current.copyWith(useAnkiConnectOnMobile: false),
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
        createMobileAnkiConnectRepository: AnkiConnectRepository.new,
        isMobile: true,
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
        // AnkiMobile 仍是默认（装了 Anki 的 iPhone 上开箱即用，升级安全）。
        // AnkiConnect 走纯 HTTP，iOS 上与 Android 一样可用——指向局域网里那台跑着
        // Anki 桌面版的机器即可。接上它，iOS 才第一次拥有 Lapis 样式客制化等
        // 「要改已存在 note type」的能力（AnkiMobile 只有加卡的 URL scheme）。
        createAnkiRepository: AnkiMobileRepository.new,
        createMobileAnkiConnectRepository: AnkiConnectRepository.new,
        isMobile: true,
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
