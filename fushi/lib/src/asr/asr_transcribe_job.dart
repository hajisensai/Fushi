/// 有声书整本转录任务：PCM 分块 → VAD 切段 → 批量 RNN-T 解码 → 段落落盘 →
/// 生成 SRT。可暂停、可断点续跑、逐块持久化。
///
/// 数据流（每个音频文件顺序处理）：
///
/// ```text
/// AsrPcmSource.decode ──chunk(≤chunkSeconds)──▶ AsrSegmenter.feed ──段──▶ 待解码队列
///        ▲ 预取下一块（ffmpeg 子进程与解码重叠）        │
///        │                                        满 batchSize 或块结束
///        │                                                ▼
///   resumeSample ◀── checkpoint ◀── segments.jsonl ◀── AsrBatchDecoder.decodeBatch
/// ```
///
/// **断点续跑的不变式**：`state.json` 里每个文件记 `resumeSample`——最后一个已完成
/// 检查点时 VAD 「进行中语音」的起点（没有进行中语音就是块末尾）。恢复时从该样本
/// 重新解码并丢弃 `segments.jsonl` 中该文件起点 ≥ resumeSample 的段，因此不会
/// 重复、也不会把一句话切成两半（进行中语音之前一定是静默）。
///
/// 本文件不依赖具体的 VAD / 解码器实现，只依赖 [AsrSegmenter] / [AsrBatchDecoder]
/// 两个窄接口，单测用 fake；真实现由 `asr_transcription_service.dart` 装配。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr/asr_cue_builder.dart';
import 'package:fushi/src/asr/asr_types.dart';

/// 流式 VAD 切段器（`AsrVadSegmenter` 实现之）。
abstract interface class AsrSegmenter {
  Future<List<AsrSpeechSegment>> feed(AsrPcmChunk chunk);
  Future<List<AsrSpeechSegment>> flush();
  void reset();

  /// 正处于「语音中」时该段语音的起始样本（含 pad）；静默时 null。
  int? get inProgressSpeechStartSample;
}

/// 批量解码器（`AsrTransducerDecoder` 实现之）。
abstract interface class AsrBatchDecoder {
  Future<List<AsrDecodedSegment>> decodeBatch(List<AsrSpeechSegment> segments);
}

/// 任务进度快照。
@immutable
class AsrTranscribeProgress {
  const AsrTranscribeProgress({
    required this.fileIndex,
    required this.filesTotal,
    required this.processedMs,
    required this.totalMs,
    required this.speechMs,
    required this.segmentsDone,
    required this.elapsed,
  });

  /// 当前正在处理的文件下标（0 起）。
  final int fileIndex;
  final int filesTotal;

  /// 已处理的音频时长（毫秒，跨文件累计）。
  final int processedMs;

  /// 全部音频总时长（毫秒）；探测失败的文件按 0 计，此时 [fraction] 不可靠。
  final int totalMs;

  /// 已解码的语音时长（毫秒，VAD 段之和）。
  final int speechMs;
  final int segmentsDone;

  /// 本次 run 起算的墙钟时间（不含此前暂停的会话）。
  final Duration elapsed;

  double? get fraction =>
      totalMs <= 0 ? null : (processedMs / totalMs).clamp(0.0, 1.0);

  /// 实时因子：墙钟 / 已处理音频时长（越小越快）。
  double? get rtf {
    if (processedMs <= 0 || elapsed.inMilliseconds <= 0) return null;
    return elapsed.inMilliseconds / processedMs;
  }

  Duration? get eta {
    final double? f = fraction;
    final double? r = rtf;
    if (f == null || r == null || totalMs <= processedMs) return null;
    return Duration(milliseconds: ((totalMs - processedMs) * r).round());
  }
}

/// 任务完成结果。
@immutable
class AsrTranscribeResult {
  const AsrTranscribeResult({
    required this.srtPath,
    required this.segmentsPath,
    required this.cueCount,
    required this.segmentCount,
    required this.totalMs,
    required this.fileDurationsMs,
  });

  final String srtPath;
  final String segmentsPath;
  final int cueCount;
  final int segmentCount;
  final int totalMs;
  final List<int> fileDurationsMs;
}

/// 任务事件：进度 / 已暂停 / 完成。
sealed class AsrTranscribeEvent {
  const AsrTranscribeEvent();
}

class AsrTranscribeProgressEvent extends AsrTranscribeEvent {
  const AsrTranscribeProgressEvent(this.progress);
  final AsrTranscribeProgress progress;
}

class AsrTranscribePausedEvent extends AsrTranscribeEvent {
  const AsrTranscribePausedEvent(this.progress);
  final AsrTranscribeProgress progress;
}

class AsrTranscribeFinishedEvent extends AsrTranscribeEvent {
  const AsrTranscribeFinishedEvent(this.result);
  final AsrTranscribeResult result;
}

/// `state.json` 的持久化形态。
@immutable
class AsrJobState {
  const AsrJobState({
    required this.audioPaths,
    required this.modelId,
    required this.fileDurationsMs,
    required this.resumeSamples,
    required this.finished,
  });

  factory AsrJobState.fresh(
    List<String> audioPaths, {
    required String modelId,
  }) =>
      AsrJobState(
        audioPaths: List<String>.unmodifiable(audioPaths),
        modelId: modelId,
        fileDurationsMs: List<int?>.filled(audioPaths.length, null),
        resumeSamples: List<int>.filled(audioPaths.length, 0),
        finished: false,
      );

  factory AsrJobState.fromJson(Map<String, Object?> json) {
    final List<String> paths =
        (json['audioPaths'] as List<Object?>).cast<String>();
    final List<Object?> durations =
        (json['fileDurationsMs'] as List<Object?>?) ?? const <Object?>[];
    final List<Object?> resumes =
        (json['resumeSamples'] as List<Object?>?) ?? const <Object?>[];
    return AsrJobState(
      audioPaths: List<String>.unmodifiable(paths),
      modelId: (json['modelId'] as String?) ?? '',
      fileDurationsMs: List<int?>.generate(
        paths.length,
        (int i) =>
            i < durations.length ? (durations[i] as num?)?.toInt() : null,
      ),
      resumeSamples: List<int>.generate(
        paths.length,
        (int i) => i < resumes.length ? (resumes[i] as num).toInt() : 0,
      ),
      finished: json['finished'] == true,
    );
  }

  final List<String> audioPaths;

  /// 产出这些段落的模型包 id（`AsrModelPack.id`）：不同词表的段落不能混在一个
  /// `segments.jsonl` 里续跑，不符即整个任务重来。
  final String modelId;
  final List<int?> fileDurationsMs;

  /// 每个文件的恢复点（样本）。等于文件总样本数（或 -1）表示该文件已完成。
  final List<int> resumeSamples;
  final bool finished;

  /// 文件是否已处理完（resumeSample 用 -1 标记）。
  bool isFileDone(int i) => resumeSamples[i] < 0;

  /// `state.json` 的格式版本。**v1 产物一律作废**：v1 时期的 PCM 抽取会把 m4b 章节
  /// text 轨交错进 mdat（BUG-2148），带章节的有声书转出来的 transcript.srt 整章是
  /// 噪声识别出的「あ」，而任务已标 finished、UI 会直接进完成态复用它。升版让
  /// [AsrTranscribeJob.loadStateDetailed] 把旧目录当新任务重跑。
  ///
  /// v3：加 `modelId`（多语言模型包）。任务目录哈希同时也含包 id，故 v2 目录本就
  /// 找不到，升版只是让格式自描述。
  static const int currentVersion = 3;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': currentVersion,
        'audioPaths': audioPaths,
        'modelId': modelId,
        'fileDurationsMs': fileDurationsMs,
        'resumeSamples': resumeSamples,
        'finished': finished,
      };

  AsrJobState copyWith({
    List<int?>? fileDurationsMs,
    List<int>? resumeSamples,
    bool? finished,
  }) {
    return AsrJobState(
      audioPaths: audioPaths,
      modelId: modelId,
      fileDurationsMs: fileDurationsMs ?? this.fileDurationsMs,
      resumeSamples: resumeSamples ?? this.resumeSamples,
      finished: finished ?? this.finished,
    );
  }
}

/// 任务目录里的固定文件名。
abstract final class AsrJobFiles {
  static const String state = 'state.json';
  static const String segments = 'segments.jsonl';
  static const String srt = 'transcript.srt';
}

/// 整本转录任务。一个实例只跑一次 [run]；暂停后再跑请新建实例（读同一 jobDir）。
class AsrTranscribeJob {
  AsrTranscribeJob({
    required this.jobDir,
    required this.audioPaths,
    required this.modelId,
    required this.pcm,
    required this.segmenter,
    required this.decoder,
    this.batchSize = 8,
    this.chunkSeconds = 300,
    this.cueBuilder = const AsrCueBuilder(),
    this.progressInterval = const Duration(milliseconds: 500),
  })  : assert(audioPaths.isNotEmpty),
        assert(batchSize > 0),
        assert(chunkSeconds > 0);

  final Directory jobDir;
  final List<String> audioPaths;

  /// 见 [AsrJobState.modelId]。
  final String modelId;
  final AsrPcmSource pcm;
  final AsrSegmenter segmenter;
  final AsrBatchDecoder decoder;

  /// 一次 encoder 前向的段数。GPU 上越大越省往返；CPU 上受内存约束。
  final int batchSize;

  /// 每块 PCM 的时长（秒）。也是检查点粒度上限。
  final int chunkSeconds;
  final AsrCueBuilder cueBuilder;

  /// 进度事件的最小间隔（同一块内按批次发，防止刷屏）。
  final Duration progressInterval;

  bool _pauseRequested = false;
  bool _started = false;

  /// 请求在下一个检查点暂停（块边界，通常 ≤ chunkSeconds 音频的处理时间）。
  void requestPause() => _pauseRequested = true;

  bool get isPauseRequested => _pauseRequested;

  File get _stateFile => File(p.join(jobDir.path, AsrJobFiles.state));
  File get _segmentsFile => File(p.join(jobDir.path, AsrJobFiles.segments));
  File get _srtFile => File(p.join(jobDir.path, AsrJobFiles.srt));

  /// 读取（或初始化）任务状态。路径列表 / 模型包与磁盘状态不一致、文件缺失或
  /// 损坏时视为新任务（`fresh == true`，调用方据此清空旧产物）。
  static Future<({AsrJobState state, bool fresh})> loadStateDetailed(
    Directory jobDir,
    List<String> audioPaths, {
    required String modelId,
  }) async {
    final ({AsrJobState state, bool fresh}) fresh = (
      state: AsrJobState.fresh(audioPaths, modelId: modelId),
      fresh: true,
    );
    final File f = File(p.join(jobDir.path, AsrJobFiles.state));
    if (!f.existsSync()) return fresh;
    try {
      final Map<String, Object?> json =
          jsonDecode(await f.readAsString()) as Map<String, Object?>;
      // 版本不符（含缺失）= 旧格式或已知会产出坏产物的旧链路，整个任务重来。
      if ((json['version'] as num?)?.toInt() != AsrJobState.currentVersion) {
        return fresh;
      }
      final AsrJobState state = AsrJobState.fromJson(json);
      if (!listEquals(state.audioPaths, audioPaths)) return fresh;
      if (state.modelId != modelId) return fresh;
      return (state: state, fresh: false);
    } on FormatException {
      return fresh;
    } on TypeError {
      return fresh;
    }
  }

  /// [loadStateDetailed] 的简写。
  static Future<AsrJobState> loadState(
    Directory jobDir,
    List<String> audioPaths, {
    required String modelId,
  }) async =>
      (await loadStateDetailed(jobDir, audioPaths, modelId: modelId)).state;

  /// 已落盘的段落（顺序即写入顺序）。
  static Future<List<AsrTranscribedSegment>> loadSegments(
    Directory jobDir,
  ) async {
    final File f = File(p.join(jobDir.path, AsrJobFiles.segments));
    if (!f.existsSync()) return <AsrTranscribedSegment>[];
    final List<AsrTranscribedSegment> out = <AsrTranscribedSegment>[];
    for (final String line in await f.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(
          AsrTranscribedSegment.fromJson(
            jsonDecode(line) as Map<String, Object?>,
          ),
        );
      } on FormatException {
        // 崩溃时可能留下半行：丢弃该行，后续块会从检查点重跑补上。
        continue;
      }
    }
    return out;
  }

  /// 运行（或从检查点继续）。流以 [AsrTranscribeFinishedEvent] 或
  /// [AsrTranscribePausedEvent] 结束；异常直接抛给监听者（已落盘的进度不丢）。
  Stream<AsrTranscribeEvent> run() async* {
    if (_started) {
      throw StateError('AsrTranscribeJob.run() 只能调用一次');
    }
    _started = true;
    await jobDir.create(recursive: true);
    final Stopwatch clock = Stopwatch()..start();

    final ({AsrJobState state, bool fresh}) loaded = await loadStateDetailed(
      jobDir,
      audioPaths,
      modelId: modelId,
    );
    AsrJobState state = loaded.state;
    if (loaded.fresh) {
      // 新任务（或状态文件缺失/损坏/路径不符）：清掉残留的旧产物。
      if (_segmentsFile.existsSync()) await _segmentsFile.delete();
      if (_srtFile.existsSync()) await _srtFile.delete();
      await _writeState(state);
    }

    // 时长探测（只补缺的）。
    final List<int?> durations = List<int?>.of(state.fileDurationsMs);
    for (int i = 0; i < audioPaths.length; i++) {
      if (durations[i] != null) continue;
      durations[i] = await pcm.probeDurationMs(audioPaths[i]);
    }
    state = state.copyWith(fileDurationsMs: durations);
    await _writeState(state);
    final int totalMs = durations.fold<int>(
      0,
      (int acc, int? d) => acc + (d ?? 0),
    );

    // 已有段落：按各文件恢复点裁掉越界部分（恢复点之后的会被重跑）。
    final List<AsrTranscribedSegment> kept = <AsrTranscribedSegment>[];
    for (final AsrTranscribedSegment s in await loadSegments(jobDir)) {
      final int resume = state.resumeSamples[s.audioFileIndex];
      if (resume < 0 || s.startMs * kAsrSampleRate ~/ 1000 < resume) {
        kept.add(s);
      }
    }
    await _rewriteSegments(kept);
    int segmentsDone = kept.length;
    int speechMs = kept.fold<int>(
      0,
      (int acc, AsrTranscribedSegment s) => acc + (s.endMs - s.startMs),
    );

    int processedBeforeFileMs = 0;
    DateTime lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);

    AsrTranscribeProgress snapshot(int fileIndex, int inFileMs) {
      return AsrTranscribeProgress(
        fileIndex: fileIndex,
        filesTotal: audioPaths.length,
        processedMs: processedBeforeFileMs + inFileMs,
        totalMs: totalMs,
        speechMs: speechMs,
        segmentsDone: segmentsDone,
        elapsed: clock.elapsed,
      );
    }

    for (int fileIndex = 0; fileIndex < audioPaths.length; fileIndex++) {
      final int fileDurationMs = durations[fileIndex] ?? 0;
      if (state.isFileDone(fileIndex)) {
        processedBeforeFileMs += fileDurationMs;
        continue;
      }
      final String path = audioPaths[fileIndex];
      final int resumeSample = state.resumeSamples[fileIndex];
      segmenter.reset();
      final List<AsrSpeechSegment> pending = <AsrSpeechSegment>[];

      Future<void> drain({required bool all}) async {
        while (pending.length >= batchSize || (all && pending.isNotEmpty)) {
          final int take =
              pending.length >= batchSize ? batchSize : pending.length;
          final List<AsrSpeechSegment> batch = pending.sublist(0, take);
          pending.removeRange(0, take);
          final List<AsrDecodedSegment> decoded = await decoder.decodeBatch(
            batch,
          );
          final List<AsrTranscribedSegment> out = <AsrTranscribedSegment>[];
          for (int k = 0; k < batch.length; k++) {
            if (decoded[k].isEmpty) continue;
            out.add(
              AsrTranscribedSegment.fromDecoded(
                audioFileIndex: fileIndex,
                speech: batch[k],
                decoded: decoded[k],
              ),
            );
            speechMs += batch[k].lengthMs;
          }
          segmentsDone += out.length;
          await _appendSegments(out);
        }
      }

      // 预取：先向流要下一块，让 ffmpeg 与本块的 VAD/解码重叠。
      final StreamIterator<AsrPcmChunk> it = StreamIterator<AsrPcmChunk>(
        pcm.decode(path, startSample: resumeSample, chunkSeconds: chunkSeconds),
      );
      try {
        Future<bool> next = it.moveNext();
        int lastEndSample = resumeSample;
        while (await next) {
          final AsrPcmChunk chunk = it.current;
          next = it.moveNext();
          if (chunk.samples.isEmpty) continue;
          pending.addAll(await segmenter.feed(chunk));
          lastEndSample = chunk.endSample;
          // 块内按批解码并节流发进度。
          while (pending.length >= batchSize) {
            await drain(all: false);
            final DateTime now = DateTime.now();
            if (now.difference(lastProgressAt) >= progressInterval) {
              lastProgressAt = now;
              yield AsrTranscribeProgressEvent(
                snapshot(fileIndex, _samplesToMs(chunk.endSample)),
              );
            }
          }
          // 块结束：全部解码后落检查点。
          await drain(all: true);
          final int checkpoint =
              segmenter.inProgressSpeechStartSample ?? chunk.endSample;
          state = _withResume(state, fileIndex, checkpoint);
          await _writeState(state);
          yield AsrTranscribeProgressEvent(
            snapshot(fileIndex, _samplesToMs(chunk.endSample)),
          );
          if (_pauseRequested) {
            yield AsrTranscribePausedEvent(
              snapshot(fileIndex, _samplesToMs(chunk.endSample)),
            );
            return;
          }
        }
        // 文件结束：冲出尾段。
        pending.addAll(await segmenter.flush());
        await drain(all: true);
        state = _withResume(state, fileIndex, -1);
        // 探测失败的文件用实际解码到的样本数补时长，让偏移与进度有据可依。
        if (durations[fileIndex] == null) {
          durations[fileIndex] = _samplesToMs(lastEndSample);
          state = state.copyWith(fileDurationsMs: List<int?>.of(durations));
        }
        await _writeState(state);
      } finally {
        await it.cancel();
      }
      processedBeforeFileMs += durations[fileIndex] ?? 0;
      yield AsrTranscribeProgressEvent(snapshot(fileIndex, 0));
    }

    // 收尾：段落 → cue → SRT。
    final List<AsrTranscribedSegment> all = await loadSegments(jobDir);
    final List<int> fileDurationsMs = List<int>.generate(
      audioPaths.length,
      (int i) => durations[i] ?? _maxEndMs(all, i),
    );
    final List<AsrCue> cues = cueBuilder.build(
      all,
      fileOffsetsMs: asrFileOffsetsFromDurations(fileDurationsMs),
    );
    await _srtFile.writeAsString(serializeAsrCuesToSrt(cues), flush: true);
    state = state.copyWith(finished: true);
    await _writeState(state);
    yield AsrTranscribeFinishedEvent(
      AsrTranscribeResult(
        srtPath: _srtFile.path,
        segmentsPath: _segmentsFile.path,
        cueCount: cues.length,
        segmentCount: all.length,
        totalMs: fileDurationsMs.fold<int>(0, (int a, int b) => a + b),
        fileDurationsMs: fileDurationsMs,
      ),
    );
  }

  static int _samplesToMs(int samples) => samples * 1000 ~/ kAsrSampleRate;

  static int _maxEndMs(List<AsrTranscribedSegment> all, int fileIndex) {
    int m = 0;
    for (final AsrTranscribedSegment s in all) {
      if (s.audioFileIndex == fileIndex && s.endMs > m) m = s.endMs;
    }
    return m;
  }

  static AsrJobState _withResume(AsrJobState s, int fileIndex, int sample) {
    final List<int> resumes = List<int>.of(s.resumeSamples);
    resumes[fileIndex] = sample;
    return s.copyWith(resumeSamples: resumes);
  }

  Future<void> _writeState(AsrJobState state) async {
    // 先写临时文件再 rename，崩溃时不会留下半个 JSON。
    final File tmp = File('${_stateFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await tmp.rename(_stateFile.path);
  }

  Future<void> _appendSegments(List<AsrTranscribedSegment> segments) async {
    if (segments.isEmpty) return;
    final StringBuffer sb = StringBuffer();
    for (final AsrTranscribedSegment s in segments) {
      sb
        ..write(jsonEncode(s.toJson()))
        ..write('\n');
    }
    await _segmentsFile.writeAsString(
      sb.toString(),
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> _rewriteSegments(List<AsrTranscribedSegment> segments) async {
    final StringBuffer sb = StringBuffer();
    for (final AsrTranscribedSegment s in segments) {
      sb
        ..write(jsonEncode(s.toJson()))
        ..write('\n');
    }
    await _segmentsFile.writeAsString(sb.toString(), flush: true);
  }
}
