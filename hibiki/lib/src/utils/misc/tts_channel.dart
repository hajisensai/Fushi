import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_playback.dart';
import 'package:hibiki/src/utils/misc/desktop_tts.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/local_audio_db.dart';

/// 一个本地音频库推给查询层的配置：库路径 + 启用子来源的优先级序。
///
/// [sourceOrder] 只含**启用**的子来源（如 `['nhk16','forvo']`），按优先级从高到低；
/// 空表示「该库不限制」——退回 DB 自然顺序、全部启用（向后兼容无配置的旧库）。
@immutable
class LocalAudioDbConfig {
  const LocalAudioDbConfig(
      {required this.path, this.sourceOrder = const <String>[]});

  final String path;
  final List<String> sourceOrder;
}

/// Audio/TTS bridge. On Android these go through the native MethodChannel
/// (`TtsChannelHandler`); off Android they fall back to pure-Dart / OS-tool
/// implementations so the desktop builds (Windows/macOS/Linux) have working
/// local-audio lookup, preview playback, sentence-clip extraction, cover
/// extraction, and TTS-to-file. `speak` (TTS aloud) has no callers and stays
/// Android-only.
class TtsChannel {
  TtsChannel._();
  static final TtsChannel instance = TtsChannel._();

  static final bool _isSupported = Platform.isAndroid;

  /// Whether TTS is available on the current platform.
  /// UI code can use this to show/hide TTS buttons.
  static bool get isSupported => _isSupported;
  static const _channel = HibikiChannels.tts;

  /// Desktop only: the configured local-audio SQLite DB configs (path +
  /// per-db enabled source order), mirrored here by [setLocalAudioDbs]
  /// (Android keeps them in the native handler instead).
  List<LocalAudioDbConfig> _desktopDbConfigs = const <LocalAudioDbConfig>[];

  List<String> get _desktopDbPaths =>
      _desktopDbConfigs.map((LocalAudioDbConfig c) => c.path).toList();

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
    if (!_isSupported) return DesktopAudioPlayback.playUrl(url);
    try {
      final result = await _channel.invokeMethod('playUrl', {'url': url});
      return result == true;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.playUrl', e, stack);
      return false;
    }
  }

  Future<bool> setLocalAudioDbs(List<LocalAudioDbConfig> dbs) async {
    if (!_isSupported) {
      _desktopDbConfigs = List<LocalAudioDbConfig>.of(dbs);
      return true;
    }
    try {
      final result = await _channel.invokeMethod('setLocalAudioDb', {
        // 'paths' 保留兼容旧逻辑；'dbConfigs' 携带每库启用源优先级。
        'paths': dbs.map((LocalAudioDbConfig c) => c.path).toList(),
        'dbConfigs': dbs
            .map((LocalAudioDbConfig c) => <String, Object?>{
                  'path': c.path,
                  'order': c.sourceOrder,
                })
            .toList(),
      });
      return result == true;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.setLocalAudioDbs', e, stack);
      return false;
    }
  }

  Future<bool> setLocalAudioDb(String path) => setLocalAudioDbs(path.isEmpty
      ? const <LocalAudioDbConfig>[]
      : <LocalAudioDbConfig>[LocalAudioDbConfig(path: path)]);

  /// 枚举一个本地音频库内的全部子来源名（`SELECT DISTINCT source`）。
  /// Android 走 native；桌面直接读 sqlite。返回空表示库为空 / 读失败。
  Future<List<String>> listLocalAudioSources(String dbPath) async {
    if (!_isSupported) return LocalAudioDb.listSources(dbPath);
    try {
      final Object? r = await _channel.invokeMethod(
          'listLocalAudioSources', <String, Object?>{'path': dbPath});
      return (r as List<Object?>?)?.cast<String>() ?? const <String>[];
    } catch (e, stack) {
      ErrorLogService.instance
          .log('TtsChannel.listLocalAudioSources', e, stack);
      return const <String>[];
    }
  }

  Future<Map<String, dynamic>?> queryLocalAudio(
    String expression,
    String reading, {
    int? dbIndex,
  }) async {
    if (!_isSupported) {
      final int start = dbIndex ?? 0;
      final int end = dbIndex == null ? _desktopDbPaths.length : start + 1;
      for (int i = start; i < end && i < _desktopDbConfigs.length; i++) {
        if (i < 0) continue;
        final LocalAudioDbConfig cfg = _desktopDbConfigs[i];
        final ({String file, String source})? meta = LocalAudioDb.queryMeta(
          cfg.path,
          expression,
          reading,
          order: cfg.sourceOrder,
        );
        if (meta != null) {
          return <String, dynamic>{
            'file': meta.file,
            'source': meta.source,
            'dbIndex': i,
          };
        }
      }
      return null;
    }
    try {
      final result = await _channel.invokeMethod('queryLocalAudio', {
        'expression': expression,
        'reading': reading,
        if (dbIndex != null) 'dbIndex': dbIndex,
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
    if (!_isSupported) {
      if (dbIndex < 0 || dbIndex >= _desktopDbPaths.length) return null;
      final Directory dir = await getTemporaryDirectory();
      return LocalAudioDb.extractBlob(
        dbPath: _desktopDbPaths[dbIndex],
        file: file,
        source: source,
        cacheDir: dir,
      );
    }
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
    if (!_isSupported) return DesktopAudioPlayback.playFile(filePath);
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
    if (!_isSupported) {
      return extractEmbeddedCoverViaFfmpeg(
        audioPath: audioPath,
        outputPath: outputPath,
      );
    }
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
    if (!_isSupported) {
      await DesktopAudioPlayback.stop();
      return;
    }
    try {
      await _channel.invokeMethod('stop');
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.stop', e, stack);
      debugPrint('[Hibiki] TTS stop failed: $e');
    }
  }
}
