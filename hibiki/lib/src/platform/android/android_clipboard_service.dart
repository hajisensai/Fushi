import 'package:flutter/services.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

class AndroidClipboardService implements PlatformClipboardService {
  int _sdkVersion = 0;

  void updateSdkVersion(int version) => _sdkVersion = version;

  @override
  Future<void> copyToClipboard(String text) async =>
      Clipboard.setData(ClipboardData(text: text));

  /// Android 13+ (SDK 33) shows its own copy confirmation toast,
  /// so we suppress our custom toast on those versions.
  @override
  bool get shouldShowCopyToast => _sdkVersion < 33;
}
