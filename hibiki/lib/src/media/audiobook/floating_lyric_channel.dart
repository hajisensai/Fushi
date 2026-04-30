import 'package:flutter/services.dart';

/// 悬浮字幕 MethodChannel 封装。
///
/// 通过原生 Android WindowManager overlay 在其他应用上层显示当前 cue 文本。
class FloatingLyricChannel {
  FloatingLyricChannel._();

  static const MethodChannel _channel =
      MethodChannel('app.hibiki.reader/floating_lyric');

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

  static Future<void> updateText(String text) async {
    await _channel.invokeMethod<void>('updateText', {'text': text});
  }

  static Future<void> updateStyle({
    double fontSize = 16,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0xCC000000,
  }) async {
    await _channel.invokeMethod<void>('updateStyle', {
      'fontSize': fontSize,
      'textColor': textColor,
      'bgColor': bgColor,
    });
  }

  static Future<void> setLocked(bool locked) async {
    await _channel.invokeMethod<void>('setLocked', {'locked': locked});
  }
}
