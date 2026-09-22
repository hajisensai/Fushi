import 'package:flutter/services.dart';

/// Windows bridge for the game-stream host input target.
///
/// The native side keeps the bound HWND and rejects every event unless that
/// window still exists, is visible, is not minimized, and is foreground.
/// Callers should treat [PlatformException] as an input rejection and surface
/// the returned code (for example `window_not_foreground`) to the session
/// acknowledgement path.
abstract final class GameStreamInputChannel {
  static const MethodChannel _channel = MethodChannel(
    'app.fushi/game_stream_input',
  );

  static Future<void> bind(int hwnd) async {
    await _channel.invokeMethod<void>('bind', <String, Object?>{'hwnd': hwnd});
  }

  static Future<void> send(Map<String, Object?> event) async {
    await _channel.invokeMethod<void>('send', event);
  }

  /// Transfers focus to the bound game during an explicit local start only.
  static Future<void> activate() async {
    await _channel.invokeMethod<void>('activate');
  }

  static Future<Map<String, Object?>> inspect([int? hwnd]) async {
    final Map<Object?, Object?>? value = await _channel
        .invokeMethod<Map<Object?, Object?>>(
          'inspect',
          hwnd == null ? null : <String, Object?>{'hwnd': hwnd},
        );
    final Map<String, Object?> result = <String, Object?>{};
    value?.forEach((Object? key, Object? item) {
      if (key is String) result[key] = item;
    });
    return result;
  }

  static Future<void> release() async {
    await _channel.invokeMethod<void>('release');
  }

  static Future<void> unbind() async {
    await _channel.invokeMethod<void>('unbind');
  }
}
