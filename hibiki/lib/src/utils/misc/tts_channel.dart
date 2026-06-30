import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
// TODO-757：把制卡媒体压缩档位 re-export 给只 import tts_channel 的调用方
// （阅读器句子音频走 TtsChannel 桌面回退，需要选档但没直接 import clipper）。
export 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;
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

/// How a resolved audio reference should be played, decided purely from its
/// string form (see [TtsChannel.classifyAudioRef]).
enum ResolvedAudioPlayback { none, url, file }

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

  Future<bool> playUrl(String url, {double volume = 1.0}) async {
    if (!_isSupported) return DesktopAudioPlayback.playUrl(url, volume: volume);
    try {
      final result = await _channel.invokeMethod('playUrl', {
        'url': url,
        'volume': volume.clamp(0.0, 1.0),
      });
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

  Future<bool> playFile(String filePath, {double volume = 1.0}) async {
    if (!_isSupported) {
      return DesktopAudioPlayback.playFile(filePath, volume: volume);
    }
    try {
      final result = await _channel.invokeMethod('playFile', {
        'path': filePath,
        'volume': volume.clamp(0.0, 1.0),
      });
      return result == true;
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsChannel.playFile', e, stack);
      return false;
    }
  }

  /// Classifies a resolved audio reference produced by [WordAudioResolver],
  /// decided purely from its string form so it is unit-testable without an
  /// audio backend.
  ///
  /// - empty → [ResolvedAudioPlayback.none]
  /// - `http(s)://…` → [ResolvedAudioPlayback.url] (streamed via [playUrl])
  /// - everything else → [ResolvedAudioPlayback.file]: a `file://` URI **or** a
  ///   bare absolute filesystem path. The path may be Unix (`/…`) **or** Windows
  ///   (`C:\…`). The old call sites only recognised `/…` and silently dropped
  ///   Windows drive-letter paths, so local-audio playback never fired on
  ///   Windows (BUG-046). Treating any non-URL ref as a file removes that
  ///   special case instead of bolting on another `startsWith` branch.
  @visibleForTesting
  static ResolvedAudioPlayback classifyAudioRef(String ref) {
    if (ref.isEmpty) return ResolvedAudioPlayback.none;
    if (ref.startsWith('http')) return ResolvedAudioPlayback.url;
    return ResolvedAudioPlayback.file;
  }

  /// Plays a resolved audio reference (remote URL or local file path) on every
  /// platform. Single home for the URL-vs-path branching so no caller
  /// re-hand-rolls it (which is how Windows local audio regressed). Returns
  /// whether playback started.
  Future<bool> playAudioRef(String ref, {double volume = 1.0}) async {
    switch (classifyAudioRef(ref)) {
      case ResolvedAudioPlayback.none:
        return false;
      case ResolvedAudioPlayback.url:
        return playUrl(ref, volume: volume);
      case ResolvedAudioPlayback.file:
        final String path =
            ref.startsWith('file://') ? Uri.parse(ref).toFilePath() : ref;
        return playFile(path, volume: volume);
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

  /// 句子音频裁剪：**全平台**统一走 ffmpeg（[extractAudioSegmentViaFfmpeg]）。
  ///
  /// TODO-970 根因修：以前 Android 走原生 MethodChannel（`extractAudioSegment` →
  /// `TtsChannelHandler`），用 `androidx.media3.transformer.Transformer` 重编码 +
  /// 手写 `AacAdtsCueAudioRewriter` 解析非分片 MP4 成裸 ADTS `.aac`。这条原生链路
  /// 有三类结构性失败：① Transformer 依赖设备 MediaCodec 能解码输入容器，`.m4b /
  /// .opus / .flac / HE-AAC` 常解不了；② 手写 MP4 box 解析器任一 box 缺失即失败、
  /// HE-AAC SBR 还会产坏文件；③ 输出裸 ADTS `.aac` 部分 Anki 播放器不识别。桌面端
  /// 走 ffmpeg 完全不经过它们——这就是「桌面有句子音频、手机没有」的根因。
  ///
  /// 仓库已有 [FfmpegBackend] 抽象 + 移动端自编捆绑的 ffmpeg-kit
  /// （`KitFfmpegBackend` 进程内 `FFmpegKit.executeWithArguments`，与桌面 CLI 后端
  /// 同契约）；视频制卡的句子音频在 Android 上早已直接走 ffmpeg。统一到 ffmpeg 后
  /// ①② 一次消除：ffmpeg 天然支持任意输入容器/编码（`.m4b/.opus/.flac/HE-AAC` 都能
  /// 解），不再依赖设备 MediaCodec / 手写 MP4 box 解析器。输出仍是 `.aac`（adts 容器）
  /// ——这是桌面 ffmpeg-min 极简构建唯一能 mux 的音频容器（BUG-460，无 mp4/ipod/m4a
  /// muxer），全平台统一不改。桌面行为逐字节不变（同一函数）。
  Future<String?> extractAudioSegment({
    required String inputPath,
    required int startMs,
    required int endMs,
    required String outputPath,
    FfmpegFailureReporter? onFailure,
    // TODO-757 压缩开关：默认压缩档（单声道 64k = 现状）；关闭压缩传立体声 128k。
    // 全平台同走 ffmpeg，两端都受压缩开关影响（不再有 Android 原生无损 re-mux 特例）。
    int audioChannels = 1,
    String audioBitrate = '64k',
  }) {
    // 全平台一律 ffmpeg 裁剪：桌面 CliFfmpegBackend、移动端 KitFfmpegBackend
    // （resolveFfmpegBackend 按平台分流），消除原 Android 原生 Transformer +
    // AacAdtsCueAudioRewriter 的三类失败模式（TODO-970）。
    return extractAudioSegmentViaFfmpeg(
      inputPath: inputPath,
      startMs: startMs,
      endMs: endMs,
      outputPath: outputPath,
      onFailure: onFailure,
      audioChannels: audioChannels,
      audioBitrate: audioBitrate,
    );
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
