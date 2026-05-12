import 'package:flutter/services.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

class FloatingDictChannel {
  FloatingDictChannel._();

  static const MethodChannel _channel = HibikiChannels.floatingDict;

  static Future<bool> canDrawOverlays() async {
    final bool? result = await _channel.invokeMethod<bool>('canDrawOverlays');
    return result ?? false;
  }

  static Future<bool> show() async {
    final bool? result = await _channel.invokeMethod<bool>('show');
    return result ?? false;
  }

  static Future<void> hide() async {
    await _channel.invokeMethod<void>('hide');
  }

  static Future<bool> isShowing() async {
    final bool? result = await _channel.invokeMethod<bool>('isShowing');
    return result ?? false;
  }

  static Future<void> openAccessibilitySettings() async {
    await _channel.invokeMethod<void>('openAccessibilitySettings');
  }

  static Future<bool> isAccessibilityEnabled() async {
    final bool? result =
        await _channel.invokeMethod<bool>('isAccessibilityEnabled');
    return result ?? false;
  }
}
