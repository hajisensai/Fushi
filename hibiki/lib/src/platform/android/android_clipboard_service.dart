import 'package:flutter/services.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

class AndroidClipboardService implements PlatformClipboardService {
  /// SDK version is resolved from [_deviceInfo] during [init], making the
  /// dependency explicit at construction instead of via a runtime downcast in
  /// PlatformServices.init (HBK-AUDIT-134).
  AndroidClipboardService(this._deviceInfo);

  final PlatformDeviceInfoService _deviceInfo;
  int _sdkVersion = 0;

  /// Resolves and caches the running SDK version. Must be awaited once during
  /// startup (via PlatformServices.init) before [shouldShowCopyToast] is read.
  Future<void> init() async {
    final int? sdk = await _deviceInfo.sdkVersion;
    if (sdk != null) _sdkVersion = sdk;
  }

  @override
  Future<void> copyToClipboard(String text) async =>
      Clipboard.setData(ClipboardData(text: text));

  /// Android 13+ (SDK 33) shows its own copy confirmation toast,
  /// so we suppress our custom toast on those versions.
  @override
  bool get shouldShowCopyToast => _sdkVersion < 33;
}
