import 'package:flutter/services.dart';

typedef FloatingLyricLookupHandler = void Function(String text);
typedef FloatingLyricControlHandler = void Function();

/// Android floating subtitle overlay channel.
class FloatingLyricChannel {
  FloatingLyricChannel._();

  static const MethodChannel _channel =
      MethodChannel('app.hibiki.reader/floating_lyric');

  static FloatingLyricLookupHandler? _onLookupText;
  static FloatingLyricControlHandler? _onPreviousCue;
  static FloatingLyricControlHandler? _onPlayPause;
  static FloatingLyricControlHandler? _onNextCue;
  static FloatingLyricControlHandler? _onClose;

  static void setEventHandlers({
    FloatingLyricLookupHandler? onLookupText,
    FloatingLyricControlHandler? onPreviousCue,
    FloatingLyricControlHandler? onPlayPause,
    FloatingLyricControlHandler? onNextCue,
    FloatingLyricControlHandler? onClose,
  }) {
    _onLookupText = onLookupText;
    _onPreviousCue = onPreviousCue;
    _onPlayPause = onPlayPause;
    _onNextCue = onNextCue;
    _onClose = onClose;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onLookupText = null;
    _onPreviousCue = null;
    _onPlayPause = null;
    _onNextCue = null;
    _onClose = null;
    _channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'lookupText':
        final Object? args = call.arguments;
        String text = '';
        if (args is Map) {
          text = args['text']?.toString() ?? '';
        }
        text = text.trim();
        if (text.isNotEmpty) {
          _onLookupText?.call(text);
        }
        break;
      case 'previousCue':
        _onPreviousCue?.call();
        break;
      case 'playPause':
        _onPlayPause?.call();
        break;
      case 'nextCue':
        _onNextCue?.call();
        break;
      case 'close':
        _onClose?.call();
        break;
      default:
        break;
    }
  }

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
