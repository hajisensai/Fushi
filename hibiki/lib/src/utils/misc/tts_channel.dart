import 'package:flutter/services.dart';

/// Thin wrapper around the native Android TextToSpeech MethodChannel.
/// Calls are fire-and-forget; failures are silently swallowed.
class TtsChannel {
  TtsChannel._();
  static final TtsChannel instance = TtsChannel._();

  static const _channel = MethodChannel('app.hibiki.reader/tts');

  /// Speak [text] using the given [locale] (e.g. "ja-JP").
  /// Returns immediately; errors are ignored.
  Future<void> speak(String text, {String locale = 'ja-JP'}) async {
    try {
      await _channel.invokeMethod('speak', {
        'text': text,
        'locale': locale,
      });
    } catch (_) {
      // TTS failure is non-critical — silently ignore.
    }
  }

  /// Stop any ongoing TTS playback.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
