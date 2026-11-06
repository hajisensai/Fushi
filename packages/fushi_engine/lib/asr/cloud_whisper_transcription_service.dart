/// 云端 Whisper 转录：把音频交给 OpenAI 兼容的 `/audio/transcriptions` 端点（Groq、
/// OpenAI 等），产物与设备端 ONNX 转录**同构**——同一个任务目录布局
/// （`state.json` / `transcript.srt` / `transcript.tokens.jsonl`）、同一套序列化函数，
/// 下游的匹配、对齐、「这份字幕是不是转录产物」判据一行都不用改。
///
/// **为什么在本仓而不是上游 `fushi_asr_core`**：上游只管设备端算法（VAD / 编码器 /
/// 解码 / 建 cue），不知道「AI 提供商」是什么；云端这条路的全部依赖——提供商配置、
/// key 轮换与限频（`AiChatClient`）、应用代理出站、ffmpeg 装配——都在本仓的引擎层。
/// 建 cue 仍用上游的 [AsrCueBuilder]（同一套句末标点 / 停顿 / 最长时长切句规则），
/// 所以不需要改上游。与系统语音（`AppleSpeechTranscriptionService`）同一形状：继承
/// [AsrTranscriptionService]、覆写弹层会调到的全部方法，内部不碰 ONNX。
///
/// 管线：
/// 1. 探每个文件的时长；超过 [CloudWhisperTranscriptionService.chunkMs] 的文件在
///    名义切点前 [CloudWhisperTranscriptionService.cutSearchMs] 的窗口里找最安静的
///    400 ms 下刀（只解这一小段 PCM），分片永不超过名义长度——切在词中间会让分片
///    两端各丢半个词；
/// 2. 每片用 ffmpeg 转成 16 kHz 单声道 Opus（WebM，32 kb/s，十分钟约 2.4 MB），远低于
///    Groq 免费档单次 25 MB 的上限；
/// 3. 逐片上传（`verbose_json` + 逐词时间），应答原样缓存进任务目录——暂停 / 失败后
///    重开从下一片接着传，已传的不再花钱；
/// 4. 按分片起点把时间折回文件内、再按文件累积时长折成单时间轴，逐词时间按字符
///    对齐到 segment 文本（Whisper 的 words 不带标点，segment 文本带），交给
///    [AsrCueBuilder] 切 cue。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/asr/asr_transcript_proofreader.dart'
    show asrCueWithProofreadText;
import 'package:path/path.dart' as p;

/// 云端转录在「模型选择」里的保留 id（与系统语音的保留 id 同一机制：不是
/// [AsrModelPack]，`buildAsrModelRegistry` 认不出会忽略，由 UI 层解释）。
const String kCloudWhisperEngineId = 'cloud-whisper';

/// 任务目录里缓存分片应答的子目录。
const String kCloudWhisperChunkCacheDir = 'cloud_chunks';

/// 单个分片上传的硬上限（Groq 免费档 25 MB，留 1 MB 余量给表单开销）。
const int kCloudWhisperMaxUploadBytes = 24 * 1024 * 1024;

/// Whisper「这段其实是静音」的经验判据（openai-whisper `transcribe.py` 的默认阈值）：
/// `no_speech_prob` 高且平均对数概率低 → 幻听（静音上的「ご視聴ありがとうございました」）。
const double kWhisperNoSpeechThreshold = 0.6;
const double kWhisperLogProbThreshold = -1.0;

/// 一个文件里的一片 `[startMs, endMs)`（相对文件起点）。
class CloudWhisperChunk {
  const CloudWhisperChunk({
    required this.fileIndex,
    required this.startMs,
    required this.endMs,
  });

  final int fileIndex;
  final int startMs;
  final int endMs;

  int get durationMs => endMs - startMs;

  /// 应答缓存文件名：文件下标 + 起止毫秒（切点确定性可复现，重开时命中同一份）。
  String get cacheName => 'f${fileIndex}_${startMs}_$endMs.json';

  @override
  bool operator ==(Object other) =>
      other is CloudWhisperChunk &&
      other.fileIndex == fileIndex &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(fileIndex, startMs, endMs);

  @override
  String toString() => 'CloudWhisperChunk($fileIndex, $startMs..$endMs)';
}

/// **纯函数**：在 16 kHz 单声道 [samples] 里找最安静的 400 ms（20 ms 帧电平取
/// 400 ms 滑动平均的最低点），返回该窗口中心相对 [samples] 起点的毫秒。
/// 样本不足一个窗口时返回 null。
int? quietestPointMs(Float32List samples, {int windowMs = 400}) {
  const int frameMs = 20;
  const int hop = kAsrSampleRate * frameMs ~/ 1000;
  final int frames = samples.length ~/ hop;
  final int k = math.max(1, windowMs ~/ frameMs);
  if (frames < k) return null;
  final Float64List energy = Float64List(frames);
  for (int f = 0; f < frames; f++) {
    double acc = 0;
    final int base = f * hop;
    for (int i = 0; i < hop; i++) {
      final double v = samples[base + i];
      acc += v * v;
    }
    energy[f] = acc / hop;
  }
  double window = 0;
  for (int f = 0; f < k; f++) {
    window += energy[f];
  }
  double best = window;
  int bestStart = 0;
  for (int f = k; f < frames; f++) {
    window += energy[f] - energy[f - k];
    // 严格小于：并列时取最早的窗口，结果可复现。
    if (window < best) {
      best = window;
      bestStart = f - k + 1;
    }
  }
  return (bestStart + k ~/ 2) * frameMs;
}

/// **纯函数**：Whisper `verbose_json` 应答 → 文件内绝对时间的转录段。
///
/// [chunkStartMs] 是这一片在文件里的起点（应答时间相对分片起点）。每段文本按字符
/// 成 token：Whisper 的逐词时间（`words`，顶层或段内）不带标点，段文本带——用
/// [asrCueWithProofreadText] 把词的时间按字符对齐到段文本上，标点继承相邻字的
/// 时间；没有逐词时间时按段时长线性分配。幻听段（[kWhisperNoSpeechThreshold]）
/// 与空段丢弃。
List<AsrTranscribedSegment> whisperVerboseJsonToSegments(
  Map<Object?, Object?> body, {
  required int audioFileIndex,
  required int chunkStartMs,
  int? chunkEndMs,
}) {
  final List<_WhisperWord> topWords = _parseWords(body['words']);
  final Object? rawSegments = body['segments'];
  final List<Map<Object?, Object?>> segments = <Map<Object?, Object?>>[
    if (rawSegments is List)
      for (final Object? s in rawSegments)
        if (s is Map) s,
  ];
  if (segments.isEmpty) {
    // 有的兼容端点只回 `text`（+ `duration`）：整片当一段。
    final Object? text = body['text'];
    if (text is String && text.trim().isNotEmpty) {
      final double? duration = _seconds(body['duration']);
      segments.add(<Object?, Object?>{
        'start': 0,
        'end': duration ?? ((chunkEndMs ?? chunkStartMs) - chunkStartMs) / 1000,
        'text': text,
      });
    }
  }
  final List<AsrTranscribedSegment> out = <AsrTranscribedSegment>[];
  for (final Map<Object?, Object?> seg in segments) {
    final Object? rawText = seg['text'];
    final String text = rawText is String ? rawText.trim() : '';
    if (text.isEmpty) continue;
    final double? noSpeech = _seconds(seg['no_speech_prob']);
    final double? logProb = _seconds(seg['avg_logprob']);
    if (noSpeech != null &&
        logProb != null &&
        noSpeech > kWhisperNoSpeechThreshold &&
        logProb < kWhisperLogProbThreshold) {
      continue;
    }
    final double start = _seconds(seg['start']) ?? 0;
    final double end = math.max(start, _seconds(seg['end']) ?? start);
    int startMs = chunkStartMs + (start * 1000).round();
    int endMs = chunkStartMs + (end * 1000).round();
    if (chunkEndMs != null) {
      startMs = math.min(startMs, chunkEndMs);
      endMs = math.min(endMs, chunkEndMs);
    }
    if (endMs <= startMs) endMs = startMs + 1;
    final List<_WhisperWord> segWords = seg['words'] is List
        ? _parseWords(seg['words'])
        : <_WhisperWord>[
            for (final _WhisperWord w in topWords)
              if (w.start >= start && w.start < end) w,
          ];
    // 先用词搭一条「临时 cue」（文本 = 词拼接、时间相对段起点），再换成带标点的
    // 段文本——时间按字符对齐继承，标点跟着相邻字走。
    final List<String> tokens = <String>[];
    final List<int> offsets = <int>[];
    final List<int> ends = <int>[];
    for (final _WhisperWord w in segWords) {
      if (w.word.isEmpty) continue;
      tokens.add(w.word);
      offsets.add(
        ((chunkStartMs + (w.start * 1000).round()) - startMs).clamp(
          0,
          endMs - startMs,
        ),
      );
      ends.add(
        ((chunkStartMs + (w.end * 1000).round()) - startMs).clamp(
          0,
          endMs - startMs,
        ),
      );
    }
    final AsrCue provisional = AsrCue(
      startMs: startMs,
      endMs: endMs,
      text: tokens.join(),
      audioFileIndex: audioFileIndex,
      tokens: tokens,
      tokenOffsetsMs: offsets,
      tokenEndOffsetsMs: ends,
    );
    final AsrCue aligned = asrCueWithProofreadText(provisional, text);
    out.add(
      AsrTranscribedSegment(
        audioFileIndex: audioFileIndex,
        startMs: startMs,
        endMs: endMs,
        tokens: aligned.tokens,
        tokenTimesMs: <int>[
          for (final int o in aligned.tokenOffsetsMs) startMs + o,
        ],
        tokenEndTimesMs: aligned.tokenEndOffsetsMs == null
            ? null
            : <int>[
                for (final int o in aligned.tokenEndOffsetsMs!) startMs + o,
              ],
      ),
    );
  }
  return out;
}

class _WhisperWord {
  const _WhisperWord(this.word, this.start, this.end);
  final String word;
  final double start;
  final double end;
}

List<_WhisperWord> _parseWords(Object? raw) {
  if (raw is! List) return const <_WhisperWord>[];
  final List<_WhisperWord> out = <_WhisperWord>[];
  for (final Object? w in raw) {
    if (w is! Map) continue;
    final Object? word = w['word'];
    final double? start = _seconds(w['start']);
    if (word is! String || start == null) continue;
    out.add(_WhisperWord(word, start, _seconds(w['end']) ?? start));
  }
  return out;
}

double? _seconds(Object? v) => switch (v) {
  final num n when n.isFinite => n.toDouble(),
  final String s => double.tryParse(s),
  _ => null,
};

/// **纯函数**：分片编码参数——只取第一条音轨、去章节 / 元数据（理由同上游
/// `buildAsrPcmChunkArgs`），16 kHz 单声道 Opus 32 kb/s 装 WebM。跳点做法同上游：
/// 输入端整秒粗跳（预滚 [preRollSeconds]），输出端精裁。
List<String> buildCloudWhisperChunkArgs({
  required String inputPath,
  required String outputPath,
  required int startMs,
  required int durationMs,
  int preRollSeconds = kAsrPcmSeekPreRollSeconds,
}) {
  final int inputSeekMs = math.max(
    0,
    (startMs - math.max(0, preRollSeconds) * 1000) ~/ 1000 * 1000,
  );
  final int outputSeekMs = startMs - inputSeekMs;
  String sec(int ms) => (ms / 1000).toStringAsFixed(3);
  return <String>[
    '-hide_banner',
    '-nostats',
    '-loglevel',
    'error',
    '-y',
    if (inputSeekMs > 0) ...<String>['-ss', sec(inputSeekMs)],
    '-i',
    inputPath,
    if (outputSeekMs > 0) ...<String>['-ss', sec(outputSeekMs)],
    '-t',
    sec(durationMs),
    '-map',
    '0:a:0',
    '-vn',
    '-sn',
    '-dn',
    '-map_chapters',
    '-1',
    '-map_metadata',
    '-1',
    '-ac',
    '1',
    '-ar',
    '$kAsrSampleRate',
    '-c:a',
    'libopus',
    '-b:a',
    '32k',
    '-application',
    'voip',
    '-f',
    'webm',
    outputPath,
  ];
}

/// 云端转录服务。弹层把它当「另一个引擎」，只与 [AsrTranscriptionService] 对话。
class CloudWhisperTranscriptionService extends AsrTranscriptionService {
  CloudWhisperTranscriptionService({
    required AiProviderConfig? Function() resolveProvider,
    required FfmpegBackend ffmpeg,
    AiChatClient Function()? clientFactory,
    Future<Directory> Function()? jobsRoot,
    this.chunkMs = 10 * 60 * 1000,
    this.cutSearchMs = 60 * 1000,
  }) : _resolveProvider = resolveProvider,
       _ffmpeg = ffmpeg,
       _clientFactory = clientFactory ?? AiChatClient.new,
       _jobsRootOverride = jobsRoot,
       super(
         // 父类构造要一个 backend，本服务把每个会用到它的方法都覆写了，ONNX
         // 那条路结构上不可达。
         backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),
         audioProfile: AsrAudioProfile.cleanSpeech,
       );

  final AiProviderConfig? Function() _resolveProvider;
  final FfmpegBackend _ffmpeg;
  final AiChatClient Function() _clientFactory;
  final Future<Directory> Function()? _jobsRootOverride;

  /// 名义分片长度（毫秒）。
  final int chunkMs;

  /// 名义切点之前找静音切点的窗口（毫秒）。
  final int cutSearchMs;

  static OnnxSessionFactory _unusedOnnxFactory() =>
      throw StateError('Cloud transcription never builds an ONNX session');

  /// 当前指派给云端转录的提供商（没配 / 配不全为 null）。
  AiProviderConfig? get provider => _resolveProvider();

  String get _modelKey {
    final AiProviderConfig? config = _resolveProvider();
    if (config == null) return kCloudWhisperEngineId;
    return '$kCloudWhisperEngineId:${config.baseUrl.host}:${config.model.trim()}';
  }

  Future<Directory> _jobsRoot() async {
    final Future<Directory> Function()? override = _jobsRootOverride;
    if (override != null) return override();
    final Directory support = await asrSupportRootDirectory();
    return Directory(p.join(support.path, 'asr_jobs'));
  }

  /// 纯函数：由文件名、字节数与「引擎 + 提供商主机 + 模型」派生稳定任务 id——
  /// 换提供商 / 模型就是另一个任务（与「换模型 = 换任务」同一条规则）。
  static String cloudJobId(
    List<String> audioPaths,
    AsrLanguage language,
    String modelKey,
  ) {
    final StringBuffer sb = StringBuffer();
    for (final String path in audioPaths) {
      final File f = File(path);
      sb
        ..write(p.basename(path))
        ..write('|')
        ..write(f.existsSync() ? f.lengthSync() : 0)
        ..write('\n');
    }
    sb
      ..write('model=')
      ..write(modelKey)
      ..write('@')
      ..write(language.tag)
      ..write('\n');
    return sha1.convert(utf8.encode(sb.toString())).toString();
  }

  @override
  Future<Directory> jobDirFor(
    List<String> audioPaths,
    AsrLanguage language, {
    List<AsrSegmentSpan>? segments,
  }) async {
    final Directory root = await _jobsRoot();
    return Directory(
      p.join(root.path, cloudJobId(audioPaths, language, _modelKey)),
    );
  }

  /// 没有模型要下：「就绪」恒为真。提供商没配好的情况由 [start] 以
  /// `provider_not_configured` 报出（弹层按 AI 失败短码给文案），不伪装成「需要下载」。
  @override
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async => AsrTranscribePlan(
    language: language,
    variant: AsrEncoderVariant.int8,
    expectedProvider: OnnxExecutionProvider.cpu,
    modelStatus: const AsrModelStatus(
      ready: true,
      diskBytes: 0,
      totalBytes: 0,
      obtainedBytes: 0,
    ),
  );

  @override
  Stream<ModelDownloadEvent> downloadModel({
    required AsrLanguage language,
    required AsrEncoderVariant variant,
  }) => const Stream<ModelDownloadEvent>.empty();

  @override
  Future<AsrJobState?> existingState(
    List<String> audioPaths,
    AsrLanguage language, {
    List<AsrSegmentSpan>? segments,
  }) async {
    final Directory dir = await jobDirFor(audioPaths, language);
    final File state = File(p.join(dir.path, AsrJobFiles.state));
    if (!state.existsSync()) return null;
    try {
      final Object? raw = jsonDecode(await state.readAsString());
      if (raw is! Map<String, Object?>) return null;
      final AsrJobState parsed = AsrJobState.fromJson(raw);
      if (parsed.audioPaths.length != audioPaths.length) return null;
      return parsed;
    } on Object {
      return null;
    }
  }

  @override
  Future<String?> finishedSrtPath(
    List<String> audioPaths,
    AsrLanguage language, {
    List<AsrSegmentSpan>? segments,
  }) async {
    final AsrJobState? state = await existingState(audioPaths, language);
    if (state == null || !state.finished) return null;
    final Directory dir = await jobDirFor(audioPaths, language);
    final File srt = File(p.join(dir.path, AsrJobFiles.srt));
    return srt.existsSync() ? srt.path : null;
  }

  @override
  Future<void> discard(
    List<String> audioPaths,
    AsrLanguage language, {
    List<AsrSegmentSpan>? segments,
  }) async {
    final Directory dir = await jobDirFor(audioPaths, language);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  @override
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
    List<AsrSegmentSpan>? segments,
  }) async {
    if (segments != null) {
      throw ArgumentError.value(
        segments,
        'segments',
        'Cloud transcription does not support caller-given segments',
      );
    }
    final AiProviderConfig? config = _resolveProvider();
    if (config == null) {
      throw const AiChatFailure('provider_not_configured');
    }
    if (config.protocol != AiWireProtocol.openAiCompatible) {
      throw const AiChatFailure(kAiTranscriptionUnsupportedProtocol);
    }
    final Directory dir = await jobDirFor(audioPaths, language);
    await dir.create(recursive: true);
    return CloudWhisperRunningTranscription(
      provider: config,
      client: _clientFactory(),
      ffmpeg: _ffmpeg,
      pcm: FfmpegAsrPcmSource(backend: _ffmpeg),
      audioPaths: List<String>.unmodifiable(audioPaths),
      language: language,
      jobDir: dir,
      modelKey: _modelKey,
      chunkMs: chunkMs,
      cutSearchMs: cutSearchMs,
    );
  }
}

/// 一次正在跑的云端转录。暂停在分片之间生效（在途那一片的请求被放弃，已完成的
/// 分片应答留在缓存里，重开只传剩下的）。
class CloudWhisperRunningTranscription implements AsrRunningTranscription {
  CloudWhisperRunningTranscription({
    required this.provider,
    required AiChatClient client,
    required FfmpegBackend ffmpeg,
    required FfmpegAsrPcmSource pcm,
    required this.audioPaths,
    required this.language,
    required this.jobDir,
    required this.modelKey,
    required this.chunkMs,
    required this.cutSearchMs,
  }) : _client = client,
       _ffmpeg = ffmpeg,
       _pcm = pcm;

  final AiProviderConfig provider;
  final AiChatClient _client;
  final FfmpegBackend _ffmpeg;
  final FfmpegAsrPcmSource _pcm;
  final List<String> audioPaths;
  final AsrLanguage language;
  final Directory jobDir;
  final String modelKey;
  final int chunkMs;
  final int cutSearchMs;

  bool _paused = false;
  bool _closed = false;

  @override
  OnnxProviderResolution get encoderResolution => const OnnxProviderResolution(
    requested: <OnnxExecutionProvider>[OnnxExecutionProvider.cpu],
    effective: OnnxExecutionProvider.cpu,
  );

  @override
  bool get greedyGraphAvailable => false;

  @override
  String? get greedyUnavailableReason => null;

  @override
  bool get encoderFp16 => false;

  @override
  AsrDecodeStats? get decodeStats => null;

  @override
  Stream<AsrTranscribeEvent> run() {
    final StreamController<AsrTranscribeEvent> events =
        StreamController<AsrTranscribeEvent>();
    events.onListen = () => unawaited(_drive(events));
    return events.stream;
  }

  Future<void> _drive(StreamController<AsrTranscribeEvent> events) async {
    final Stopwatch clock = Stopwatch()..start();
    void emit(AsrTranscribeEvent e) {
      if (!events.isClosed) events.add(e);
    }

    final List<int> durations = <int>[];
    int processedMs = 0;
    int segmentsDone = 0;
    int currentFile = 0;
    int totalMs = 0;
    AsrTranscribeProgress progress() => AsrTranscribeProgress(
      fileIndex: currentFile,
      filesTotal: audioPaths.length,
      processedMs: processedMs,
      totalMs: totalMs,
      speechMs: processedMs,
      segmentsDone: segmentsDone,
      elapsed: clock.elapsed,
    );

    final Directory tempDir = await Directory.systemTemp.createTemp(
      'fushi_cloud_asr_',
    );
    try {
      for (final String path in audioPaths) {
        final int? ms = await _pcm.probeDurationMs(path);
        if (ms == null || ms <= 0) {
          throw StateError('Cannot read audio duration: ${p.basename(path)}');
        }
        durations.add(ms);
      }
      totalMs = durations.fold(0, (int a, int b) => a + b);
      await _writeState(durations, finished: false);
      emit(AsrTranscribeProgressEvent(progress()));

      final Directory cache = Directory(
        p.join(jobDir.path, kCloudWhisperChunkCacheDir),
      );
      await cache.create(recursive: true);
      final List<AsrTranscribedSegment> segments = <AsrTranscribedSegment>[];
      for (int index = 0; index < audioPaths.length; index++) {
        currentFile = index;
        final List<CloudWhisperChunk> chunks = await _planChunks(
          index,
          durations[index],
          tempDir,
        );
        for (final CloudWhisperChunk chunk in chunks) {
          if (_paused) {
            emit(AsrTranscribePausedEvent(progress()));
            return;
          }
          final Map<Object?, Object?> body;
          try {
            body = await _transcribeChunk(chunk, cache, tempDir);
          } on AiChatFailure {
            // 暂停是我们关掉客户端造成的在途失败，不是转录失败。
            if (_paused) {
              emit(AsrTranscribePausedEvent(progress()));
              return;
            }
            rethrow;
          }
          final List<AsrTranscribedSegment> part = whisperVerboseJsonToSegments(
            body,
            audioFileIndex: index,
            chunkStartMs: chunk.startMs,
            chunkEndMs: chunk.endMs,
          );
          segments.addAll(part);
          segmentsDone += part.length;
          processedMs += chunk.durationMs;
          emit(AsrTranscribeProgressEvent(progress()));
        }
      }

      final List<AsrCue> cues = const AsrCueBuilder().build(
        segments,
        fileOffsetsMs: asrFileOffsetsFromDurations(durations),
      );
      final File srt = File(p.join(jobDir.path, AsrJobFiles.srt));
      final File tokens = File(p.join(jobDir.path, AsrJobFiles.cueTokens));
      await srt.writeAsString(serializeAsrCuesToSrt(cues), flush: true);
      await tokens.writeAsString(serializeAsrCueTokens(cues), flush: true);
      await _writeState(durations, finished: true);
      emit(
        AsrTranscribeFinishedEvent(
          AsrTranscribeResult(
            srtPath: srt.path,
            segmentsPath: p.join(jobDir.path, AsrJobFiles.segments),
            cueCount: cues.where((AsrCue c) => c.text.isNotEmpty).length,
            segmentCount: segments.length,
            totalMs: totalMs,
            fileDurationsMs: durations,
          ),
        ),
      );
    } catch (error, stack) {
      if (_paused) {
        emit(AsrTranscribePausedEvent(progress()));
      } else if (!events.isClosed) {
        events.addError(error, stack);
      }
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 临时目录删不掉不影响结果（系统临时目录会被清理）。
      }
      await events.close();
    }
  }

  Future<void> _writeState(List<int> durations, {required bool finished}) =>
      File(p.join(jobDir.path, AsrJobFiles.state)).writeAsString(
        jsonEncode(
          AsrJobState(
            audioPaths: audioPaths,
            modelId: modelKey,
            fileDurationsMs: durations,
            resumeSamples: List<int>.filled(audioPaths.length, 0),
            finished: finished,
          ).toJson(),
        ),
        flush: true,
      );

  /// 一个文件的分片：不超过 [chunkMs]；长文件在名义切点前 [cutSearchMs] 里找最
  /// 安静处下刀（找不到——解码失败 / 窗口太短——就切在名义点上）。
  Future<List<CloudWhisperChunk>> _planChunks(
    int fileIndex,
    int durationMs,
    Directory tempDir,
  ) async {
    final List<CloudWhisperChunk> out = <CloudWhisperChunk>[];
    int start = 0;
    while (durationMs - start > chunkMs) {
      final int nominal = start + chunkMs;
      final int windowStart = math.max(
        start + chunkMs ~/ 2,
        nominal - cutSearchMs,
      );
      final int? quiet = await _quietPointIn(
        audioPaths[fileIndex],
        windowStart,
        nominal - windowStart,
        tempDir,
      );
      final int cut = quiet == null ? nominal : windowStart + quiet;
      out.add(
        CloudWhisperChunk(fileIndex: fileIndex, startMs: start, endMs: cut),
      );
      start = cut;
    }
    out.add(
      CloudWhisperChunk(
        fileIndex: fileIndex,
        startMs: start,
        endMs: durationMs,
      ),
    );
    return out;
  }

  Future<int?> _quietPointIn(
    String path,
    int startMs,
    int durationMs,
    Directory tempDir,
  ) async {
    final File raw = File(p.join(tempDir.path, 'window.s16le'));
    final FfmpegRunResult result = await _ffmpeg.run(
      buildAsrPcmChunkArgs(
        inputPath: path,
        outputPath: raw.path,
        startMs: startMs,
        durationMs: durationMs,
        container: AsrPcmContainer.s16le,
      ),
      const Duration(minutes: 2),
    );
    if (!result.isSuccess || !raw.existsSync()) return null;
    final Uint8List bytes = await raw.readAsBytes();
    final ByteData view = ByteData.sublistView(bytes);
    final Float32List samples = Float32List(bytes.length ~/ 2);
    for (int i = 0; i < samples.length; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return quietestPointMs(samples);
  }

  Future<Map<Object?, Object?>> _transcribeChunk(
    CloudWhisperChunk chunk,
    Directory cache,
    Directory tempDir,
  ) async {
    final File cached = File(p.join(cache.path, chunk.cacheName));
    if (cached.existsSync()) {
      try {
        final Object? decoded = jsonDecode(await cached.readAsString());
        if (decoded is Map) return decoded;
      } on FormatException {
        // 半截缓存（写到一半被杀）：当没有，重新传。
      }
    }
    final File audio = File(p.join(tempDir.path, 'chunk.webm'));
    final FfmpegRunResult encoded = await _ffmpeg.run(
      buildCloudWhisperChunkArgs(
        inputPath: audioPaths[chunk.fileIndex],
        outputPath: audio.path,
        startMs: chunk.startMs,
        durationMs: chunk.durationMs,
      ),
      const Duration(minutes: 10),
    );
    if (!encoded.isSuccess || !audio.existsSync()) {
      throw StateError(
        'ffmpeg failed to encode audio: ${encoded.failureSummary}',
      );
    }
    final Uint8List bytes = await audio.readAsBytes();
    if (bytes.length > kCloudWhisperMaxUploadBytes) {
      throw StateError(
        'Audio chunk too large to upload (${bytes.length} bytes)',
      );
    }
    final Map<Object?, Object?> body = await _client.transcribeAudio(
      provider: provider,
      audioBytes: bytes,
      fileName: 'chunk.webm',
      contentType: 'audio/webm',
      language: language.tag,
    );
    // 先写临时文件再改名：被杀在半途也不会留下一份能被当成完整应答读回的缓存。
    final File tmp = File('${cached.path}.tmp');
    await tmp.writeAsString(jsonEncode(body), flush: true);
    await tmp.rename(cached.path);
    return body;
  }

  @override
  void requestPause({bool discardPending = false}) {
    _paused = true;
    // 关客户端 = 在途请求立即失败、排队中的放弃（见 AiChatClient.close）。
    _closeClient();
  }

  void _closeClient() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }

  @override
  Future<void> dispose() async {
    _paused = true;
    _closeClient();
  }
}
