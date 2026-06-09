import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/platform/floating_overlay_channel.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

typedef FloatingLyricLookupHandler = void Function(String text, int index);
typedef FloatingLyricControlHandler = void Function();
typedef FloatingLyricLockHandler = void Function(bool locked);

/// Android floating subtitle overlay channel.
class FloatingLyricChannel extends FloatingOverlayChannel {
  FloatingLyricChannel._() : super(HibikiChannels.floatingLyric);

  static final FloatingLyricChannel _instance = FloatingLyricChannel._();

  @visibleForTesting
  static bool? platformOverride;

  @override
  bool get isSupported => platformOverride ?? Platform.isAndroid;

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
    _instance.channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onLookupText = null;
    _onPreviousCue = null;
    _onPlayPause = null;
    _onNextCue = null;
    _onClose = null;
    _onLockChanged = null;
    _instance.channel.setMethodCallHandler(null);
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

  // ---------------------------------------------------------------------------
  // Static delegation — call sites like FloatingLyricChannel.show() keep working
  // ---------------------------------------------------------------------------

  static Future<bool> canDrawOverlays() => _instance.canDrawOverlaysImpl();

  static Future<bool> show({
    double fontSize = 16,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0xCC000000,
    int buttonTextColor = 0xFFFFFFFF,
    int buttonBgColor = 0x33000000,
    int highlightColor = 0x80FFD54F,
    int activeColor = 0xFFFFD54F,
    bool? locked,
    bool clickLookupEnabled = true,
  }) {
    final Map<String, Object?> arguments = <String, Object?>{
      'fontSize': fontSize,
      'textColor': textColor,
      'bgColor': bgColor,
      'buttonTextColor': buttonTextColor,
      'buttonBgColor': buttonBgColor,
      'highlightColor': highlightColor,
      'activeColor': activeColor,
      'clickLookupEnabled': clickLookupEnabled,
    };
    if (locked != null) {
      arguments['locked'] = locked;
    }
    return _instance.showImpl(arguments);
  }

  static Future<void> hide() => _instance.hideImpl();

  static Future<bool> isShowing() => _instance.isShowingImpl();

  static Future<void> updateText(String text) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateText', {'text': text});
  }

  static Future<void> highlight({
    required int start,
    required int length,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('highlight', {
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
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateLabels', {
      'previous': previous,
      'playPause': playPause,
      'next': next,
      'lock': lock,
      'unlock': unlock,
      'close': close,
    });
  }

  static Future<void> setPlaybackState({required bool playing}) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('setPlaybackState', {
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
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateStyle', {
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
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('setLocked', {'locked': locked});
  }

  static Future<void> setClickLookupEnabled(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setClickLookupEnabled',
      {'enabled': enabled},
    );
  }
}
