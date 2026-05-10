import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

/// Thin wrapper around the native Android TextToSpeech MethodChannel.
/// Calls are fire-and-forget; failures are silently swallowed.
class TtsChannel {
  TtsChannel._();
  static final TtsChannel instance = TtsChannel._();

  static const _channel = HibikiChannels.tts;

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

  /// Play audio from a URL (e.g. mp3 from jpod101/forvo).
  Future<bool> playUrl(String url) async {
    try {
      final result = await _channel.invokeMethod('playUrl', {'url': url});
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Set the path to a local audio SQLite database (android.db from Yomitan).
  Future<bool> setLocalAudioDb(String path) async {
    try {
      final result = await _channel.invokeMethod('setLocalAudioDb', {'path': path});
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Query the local audio database for a word's pronunciation.
  /// Returns {file, source} metadata if found, or null.
  Future<Map<String, String>?> queryLocalAudio(String expression, String reading) async {
    try {
      final result = await _channel.invokeMethod('queryLocalAudio', {
        'expression': expression,
        'reading': reading,
      });
      if (result == null) return null;
      return Map<String, String>.from(result as Map);
    } catch (_) {
      return null;
    }
  }

  /// Extract audio blob from local DB and write to temp file.
  /// Returns the temp file path, or null on failure.
  Future<String?> extractLocalAudio(String file, String source) async {
    try {
      final result = await _channel.invokeMethod('extractLocalAudio', {
        'file': file,
        'source': source,
      });
      return result as String?;
    } catch (_) {
      return null;
    }
  }

  /// Play a local file path via MediaPlayer.
  Future<bool> playFile(String filePath) async {
    try {
      final result = await _channel.invokeMethod('playFile', {'path': filePath});
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Extract a segment from an audio file using Android MediaExtractor/MediaMuxer.
  /// Returns the output file path on success, null on failure.
  Future<String?> extractAudioSegment({
    required String inputPath,
    required int startMs,
    required int endMs,
    required String outputPath,
  }) async {
    try {
      final result = await _channel.invokeMethod('extractAudioSegment', {
        'inputPath': inputPath,
        'startMs': startMs,
        'endMs': endMs,
        'outputPath': outputPath,
      });
      return result as String?;
    } catch (_) {
      return null;
    }
  }

  /// Synthesize [text] to a WAV file at [outputPath] using Android TTS.
  /// Returns the output path on success, null on failure.
  Future<String?> ttsToFile(String text, String outputPath, {String locale = 'ja-JP'}) async {
    try {
      final result = await _channel.invokeMethod('ttsToFile', {
        'text': text,
        'locale': locale,
        'outputPath': outputPath,
      });
      return result as String?;
    } catch (_) {
      return null;
    }
  }

  /// Stop any ongoing TTS or URL audio playback.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[Hibiki] TTS stop failed: $e');
    }
  }
}
