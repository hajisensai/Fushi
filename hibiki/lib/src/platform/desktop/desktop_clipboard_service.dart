import 'package:flutter/services.dart';
import 'package:fushi_platform/fushi_platform.dart';

class DesktopClipboardService implements PlatformClipboardService {
  @override
  Future<void> copyToClipboard(String text) async =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  bool get shouldShowCopyToast => true;
}
