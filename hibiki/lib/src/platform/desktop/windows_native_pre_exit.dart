import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowsNativePreExit {
  static const MethodChannel _channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_manager');

  static bool _prepared = false;

  static Future<void> prepareForExit() async {
    if (!Platform.isWindows) return;
    if (_prepared) return;
    _prepared = true;

    try {
      await _channel.invokeMethod<void>('prepareForProcessExit');
    } on MissingPluginException catch (e) {
      debugPrint('[Hibiki] Windows native pre-exit hook unavailable: $e');
    } on PlatformException catch (e) {
      debugPrint('[Hibiki] Windows native pre-exit hook failed: $e');
    } catch (e) {
      debugPrint('[Hibiki] Windows native pre-exit hook failed: $e');
    }
  }
}
