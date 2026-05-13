import 'package:flutter/services.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

typedef FloatingLyricLookupHandler = void Function(String text, int index);
typedef FloatingLyricControlHandler = void Function();
typedef FloatingLyricLockHandler = void Function(bool locked);

/// Android floating subtitle overlay channel.
class FloatingLyricChannel {
  FloatingLyricChannel._();

  static const MethodChannel _channel = HibikiChannels.floatingLyric;

  static FloatingLyricLookupHandler? _onLookupText;
  static FloatingLyricControlHandler? _onPreviousCue;
  static FloatingLyricControlHandler? _onPlayPause;
  static FloatingLyricControlHandler? _onNextCue;
  static FloatingLyricControlHandler? _onClose;
  static FloatingLyricLockHandler? _onLockChanged;

  static void setEventHandlers({
    FloatingLyricLookupHandler? onLookupText,
    FloatingLyricControlHandler? onPreviousCue,
    FloatingLyricControlHandler? onPlayPause,
    FloatingLyricControlHandler? onNextCue,
    FloatingLyricControlHandler? onClose,
    FloatingLyricLockHandler? onLockChanged,
  }) {
    _onLookupText = onLookupText;
    _onPreviousCue = onPreviousCue;
    _onPlayPause = onPlayPause;
    _onNextCue = onNextCue;
    _onClose = onClose;
    _onLockChanged = onLockChanged;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onLookupText = null;
    _onPreviousCue = null;
    _onPlayPause = null;
    _onNextCue = null;
    _onClose = null;
    _onLockChanged = null;
    _channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'lookupText':
        final Object? args = call.arguments;
        String text = '';
        int index = 0;
        if (args is Map) {
          text = args['text']?.toString() ?? '';
          final Object? indexValue = args['index'];
          if (indexValue is int) {
            index = indexValue;
          } else if (indexValue is num) {
            index = indexValue.toInt();
          }
        }
        if (text.trim().isNotEmpty) {
          _onLookupText?.call(text, index);
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
      case 'lockChanged':
        final Object? args = call.arguments;
        if (args is Map) {
          final bool locked = args['locked'] == true;
          _onLockChanged?.call(locked);
        }
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

  static Future<void> highlight({
    required int start,
    required int length,
  }) async {
    await _channel.invokeMethod<void>('highlight', {
      'start': start,
      'length': length,
    });
  }

  static Future<void> updateLabels({
    required String previous,
    required String playPause,
    required String next,
    required String lock,
    required String unlock,
    required String close,
  }) async {
    await _channel.invokeMethod<void>('updateLabels', {
      'previous': previous,
      'playPause': playPause,
      'next': next,
      'lock': lock,
      'unlock': unlock,
      'close': close,
    });
  }

  static Future<void> setPlaybackState({required bool playing}) async {
    await _channel.invokeMethod<void>('setPlaybackState', {
      'playing': playing,
    });
  }

  static Future<void> updateStyle({
    double fontSize = 16,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0xCC000000,
    int buttonTextColor = 0xFFFFFFFF,
    int buttonBgColor = 0x33000000,
    int highlightColor = 0x80FFD54F,
    int activeColor = 0xFFFFD54F,
  }) async {
    await _channel.invokeMethod<void>('updateStyle', {
      'fontSize': fontSize,
      'textColor': textColor,
      'bgColor': bgColor,
      'buttonTextColor': buttonTextColor,
      'buttonBgColor': buttonBgColor,
      'highlightColor': highlightColor,
      'activeColor': activeColor,
    });
  }

  static Future<void> setLocked(bool locked) async {
    await _channel.invokeMethod<void>('setLocked', {'locked': locked});
  }
}
