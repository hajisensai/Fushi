import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki/src/utils/misc/desktop_tts.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// Thin wrapper around the native Android TextToSpeech MethodChannel.
/// Calls are fire-and-forget; failures are silently swallowed.
/// Only functional on Android — all methods return no-op values on other platforms.
class TtsChannel {
  TtsChannel._();
  static final TtsChannel instance = TtsChannel._();

  static final bool _isSupported = Platform.isAndroid;

  /// Whether TTS is available on the current platform.
  /// UI code can use this to show/hide TTS buttons.
  static bool get isSupported => _isSupported;
  static const _channel = HibikiChannels.tts;

  Future<void> speak(String text, {String locale = 'ja-JP'}) async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod('speak', {
        'text': text,
        'locale': locale,
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.speak', e, stack);
    }
  }

  Future<bool> playUrl(String url) async {
    if (!_isSupported) return false;
    try {
      final result = await _channel.invokeMethod('playUrl', {'url': url});
      return result == true;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.playUrl', e, stack);
      return false;
    }
  }

  Future<bool> setLocalAudioDbs(List<String> paths) async {
    if (!_isSupported) return false;
    try {
      final result = await _channel.invokeMethod('setLocalAudioDb', {
        'paths': paths,
      });
      return result == true;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.setLocalAudioDbs', e, stack);
      return false;
    }
  }

  Future<bool> setLocalAudioDb(String path) =>
      setLocalAudioDbs(path.isEmpty ? [] : [path]);

  Future<Map<String, dynamic>?> queryLocalAudio(
      String expression, String reading) async {
    if (!_isSupported) return null;
    try {
      final result = await _channel.invokeMethod('queryLocalAudio', {
        'expression': expression,
        'reading': reading,
      });
      if (result == null) return null;
      return Map<String, dynamic>.from(result as Map);
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.queryLocalAudio', e, stack);
      return null;
    }
  }

  Future<String?> extractLocalAudio(String file, String source,
      {int dbIndex = 0}) async {
    if (!_isSupported) return null;
    try {
      final result = await _channel.invokeMethod('extractLocalAudio', {
        'file': file,
        'source': source,
        'dbIndex': dbIndex,
      });
      return result as String?;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.extractLocalAudio', e, stack);
      return null;
    }
  }

  Future<bool> playFile(String filePath) async {
    if (!_isSupported) return false;
    try {
      final result =
          await _channel.invokeMethod('playFile', {'path': filePath});
      return result == true;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.playFile', e, stack);
      return false;
    }
  }

  Future<String?> extractEmbeddedCover({
    required String audioPath,
    required String outputPath,
  }) async {
    if (!_isSupported) return null;
    try {
      final result = await _channel.invokeMethod('extractEmbeddedCover', {
        'audioPath': audioPath,
        'outputPath': outputPath,
      });
      return result as String?;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.extractEmbeddedCover', e, stack);
      return null;
    }
  }

  Future<String?> extractAudioSegment({
    required String inputPath,
    required int startMs,
    required int endMs,
    required String outputPath,
  }) async {
    if (!_isSupported) {
      // No native channel off Android: cut the sentence clip with ffmpeg so
      // desktop Anki cards still get audio (returns null if ffmpeg is absent).
      return extractAudioSegmentViaFfmpeg(
        inputPath: inputPath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
      );
    }
    try {
      final result = await _channel.invokeMethod('extractAudioSegment', {
        'inputPath': inputPath,
        'startMs': startMs,
        'endMs': endMs,
        'outputPath': outputPath,
      });
      return result as String?;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.extractAudioSegment', e, stack);
      return null;
    }
  }

  Future<String?> ttsToFile(String text, String outputPath,
      {String locale = 'ja-JP'}) async {
    if (!_isSupported) {
      // No native TextToSpeech off Android: use the OS speech engine
      // (macOS `say` / Windows SAPI). Returns null on Linux / failure.
      return ttsToFileDesktop(text: text, outputPath: outputPath);
    }
    try {
      final result = await _channel.invokeMethod('ttsToFile', {
        'text': text,
        'locale': locale,
        'outputPath': outputPath,
      });
      return result as String?;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.ttsToFile', e, stack);
      return null;
    }
  }

  Future<void> stop() async {
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.stop', e, stack);
      debugPrint('[Hibiki] TTS stop failed: $e');
    }
  }
}
