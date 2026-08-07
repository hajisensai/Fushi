import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';
// TODO-757：把制卡媒体压缩档位 re-export 给只 import tts_channel 的调用方
// （阅读器句子音频走 TtsChannel 桌面回退，需要选档但没直接 import clipper）。
export 'package:fushi/src/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression, AudioMetadata;
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/src/utils/misc/desktop_tts.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/local_audio_db.dart';

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
/// extraction, and TTS-to-file.
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

  /// 桌面查词播放器冷启动预热（BUG-1015）。just_audio_media_kit 首次平台激活会吞掉
  /// 第一段播放输出，导致本次 app 启动后「第一次查词自动发音没声音、点第二次才响」。
  /// 启动时静音预热一次消除该空窗。Android 走原生 MediaPlayer 无此冷启动，直接 no-op。
  Future<void> warmUpLookupAudioPlayer() async {
    if (_isSupported) return;
    await DesktopAudioPlayback.warmUp();
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
      // 绑定期对每个库后台补一次查询索引（对齐 Android `TtsChannelHandler`
      // 在 `setLocalAudioDb` 时后台建索引的做法）。unawaited + Isolate.run：
      // 首次大库建索引可达数秒，不阻塞绑定调用方；建好后查询路径永远只读打开。
      for (final LocalAudioDbConfig cfg in dbs) {
        unawaited(LocalAudioDb.ensureIndexes(cfg.path));
      }
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
      final int end = dbIndex == null ? _desktopDbConfigs.length : start + 1;
      // 同步 SQLite 体挪进 Isolate.run：此前 async 函数体在首个 await 前跑完，
      // 调用方（lookup_audio_playback）的 `.timeout(500ms)` 是死代码，慢库会
      // 无上限阻塞调用者 isolate。闭包只捕获纯数据（路径/词/reading/order 快照），
      // sqlite3 句柄 per-isolate，Isolate.run 内自行开关（readOnly 开销小）。
      // 弹窗独立 isolate 也会调进来：Isolate.run 嵌套是允许的。
      final List<({String path, List<String> order})> configs =
          <({String path, List<String> order})>[
        for (final LocalAudioDbConfig c in _desktopDbConfigs)
          (path: c.path, order: List<String>.of(c.sourceOrder)),
      ];
      // 绑定期 [setLocalAudioDbs] 对同一批库文件 unawaited 派出了
      // [LocalAudioDb.ensureIndexes]——那是**我们自己**开的 readWrite 连接。
      // 在它收尾前发查询，两条连接就在同一个 inode 上抢锁：CREATE INDEX 提交
      // 阶段持独占锁，只读连接的 busy_timeout 一到点就 SQLITE_BUSY，被
      // [LocalAudioDb.queryMeta] 的 catch 吞成 null——与「库里真没这个词」
      // 完全同形，用户看到「暂无发音」（BUG-1365）。in-flight 写有现成的
      // per-path 完成信号，读端排在它后面即可，不靠 busy_timeout 赌赢。
      // 无在途任务时是一次立即完成的 Future，零额外成本。
      await Future.wait(<Future<void>>[
        for (int i = start; i < end && i < configs.length; i++)
          if (i >= 0) LocalAudioDb.waitForPendingIndexing(configs[i].path),
      ]);
      try {
        return await Isolate.run(() {
          for (int i = start; i < end && i < configs.length; i++) {
            if (i < 0) continue;
            final ({String path, List<String> order}) cfg = configs[i];
            final ({String file, String source})? meta = LocalAudioDb.queryMeta(
              cfg.path,
              expression,
              reading,
              order: cfg.order,
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
        });
      } on LocalAudioUnavailableError {
        // BUG-1413：库这次没答上（撞锁）必须穿透到 WordAudioResolver。在这里吞成
        // null 就又与「库里真没这个词」同形了——那正是本条要消除的东西。
        // 自定义异常可原样跨 Isolate.run 边界回到本 isolate（已实测）。
        rethrow;
      } catch (e, stack) {
        ErrorLogService.instance.log('TtsChannel.queryLocalAudio', e, stack);
        return null;
      }
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
      final String dbPath = _desktopDbPaths[dbIndex];
      // getTemporaryDirectory 走平台插件，必须留在调用方 isolate；同步 SQLite
      // blob 读取 + 写盘挪进 Isolate.run（同 [queryLocalAudio]，闭包只捕获纯
      // 字符串，Directory 在 worker isolate 内重建）。
      final Directory dir = await getTemporaryDirectory();
      final String cacheDirPath = dir.path;
      // 同 [queryLocalAudio]：blob 读取也必须排在自家绑定期建索引之后，否则
      // 撞上 CREATE INDEX 的独占锁 → busy 超时 → extractBlob catch 吞成 null
      // ＝已查到词条却「音频提取失败」（BUG-1365）。
      await LocalAudioDb.waitForPendingIndexing(dbPath);
      try {
        return await Isolate.run(() => LocalAudioDb.extractBlob(
              dbPath: dbPath,
              file: file,
              source: source,
              cacheDir: Directory(cacheDirPath),
            ));
      } on LocalAudioUnavailableError {
        rethrow; // 同 [queryLocalAudio]（BUG-1413）：没答上 ≠ 没有音频。
      } catch (e, stack) {
        ErrorLogService.instance.log('TtsChannel.extractLocalAudio', e, stack);
        return null;
      }
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

  /// TODO-1045：读音频容器（M4B/M4A/MP3…）的 title/artist/album tag，供导入对话框
  /// 仅填空自动回填标题/作者。**全平台统一走 ffprobe / ffmpeg-kit**——不经 Android
  /// 原生 `TtsChannelHandler`（P1 无原生实现）：桌面 CliFfmpegBackend 起 ffprobe、
  /// 移动端 KitFfmpegBackend 走 `FFprobeKit.executeWithArguments`。缺 ffprobe / 无 tag
  /// 时返回 null（[extractAudioMetadataViaFfprobe] 内部吞异常降级），调用方保留文件名
  /// 兜底，绝不崩。
  Future<AudioMetadata?> extractAudioMetadata({
    required String audioPath,
  }) {
    return extractAudioMetadataViaFfprobe(inputPath: audioPath);
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
