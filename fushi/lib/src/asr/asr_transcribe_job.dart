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
import 'package:fushi/src/asr/asr_transducer_decoder.dart'
    show AsrBatchFeatures, AsrDecodeStats, AsrEncodedBatch;
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

/// 三段式解码器（可选实现）：fbank（Dart 同步）→ encoder（GPU）→ 搜索（CPU）
/// 拆开后任务可以把三者叠起来：GPU 编码第 i 批时 CPU 搜索第 i-1 批、Dart 算第
/// i+1 批的 fbank（`asr_transcribe_job.dart` 的流水线）。三段串起来必须与
/// [AsrBatchDecoder.decodeBatch] 逐字等价。
abstract interface class AsrPipelinedDecoder implements AsrBatchDecoder {
  AsrBatchFeatures computeFeatures(List<AsrSpeechSegment> segments);
  Future<AsrEncodedBatch> encode(
    List<AsrSpeechSegment> segments, {
    AsrBatchFeatures? features,
  });
  Future<List<AsrDecodedSegment>> search(AsrEncodedBatch encoded);
}

/// 解码器对成批形状的约束（可选实现）：GPU 静态 shape 桶一批**恰好** N 行，
/// 任务侧按最长段的桶封顶、攒够 N 行就发，不再按音频预算/半长规则切。
abstract interface class AsrBatchShaper {
  /// 最长段为 [longestSamples] 样本时一批最多几行；null = 无约束。
  int? batchCapFor(int longestSamples);

  /// [longestSamples] 样本的段落到哪个桶（桶的稳定标识，如帧数）；null = 无约束。
  /// 任务侧**按桶分组成批**：同一批只装同一个桶的段，短段不再被更大的桶顺手
  /// 带走（2026-09-06 实测那正是 280 帧桶「加了也没用」的原因）。
  int? bucketKeyFor(int longestSamples);
}

/// 一套引擎会话对应的完整解码器（三段式 + 成批约束 + 统计）：transducer
/// （`AsrTransducerDecoder`）与 CTC（`AsrCtcDecoder`）都实现它，任务侧与
/// isolate / 服务只认这个接口。
abstract interface class AsrSegmentDecoder
    implements AsrPipelinedDecoder, AsrBatchShaper {
  AsrDecodeStats get stats;
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
    this.decodeStats,
  });

  /// 当前正在处理的文件下标（0 起）。
  final int fileIndex;

  /// 解码器到此刻的分阶段统计（UI 据此显示是否在跑静态融合图等）；解码器不
  /// 提供时 null。
  final AsrDecodeStats? decodeStats;
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
  /// text 轨交错进 mdat（BUG-2164），带章节的有声书转出来的 transcript.srt 整章是
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

  /// 与 [srt] 同一份 cue 的逐 token 时间 sidecar（`serializeAsrCueTokens`）。
  static const String cueTokens = 'transcript.tokens.jsonl';
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
    this.statsProvider,
    this.usePipeline = true,
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

  /// **动态 shape 路径**的成批参考段数：一批的音频预算 = [batchSize] ×
  /// [kAsrBatchReferenceSeconds] 秒。段短时一批可以装比它多得多的段（上限
  /// [maxBatchSegments]），段都顶到 20 s 时恰好是 [batchSize] 段。GPU 上越大越省
  /// 往返；CPU 上受内存约束。
  ///
  /// 解码器实现了 [AsrBatchShaper]（GPU 静态 shape 桶）时**本参数与下面两项都不
  /// 生效**：一批的行数由最长段所在桶的容量决定（`batchCapFor`），攒够就发——桶
  /// 内每行成本相同，装满最划算，音频预算和 4 倍上限在那里没有意义。
  final int batchSize;

  /// 动态路径：一批最多装多少段（防止全是 1 s 短句时把一批撑到几百行）。
  int get maxBatchSegments => batchSize * 4;

  /// 动态路径：[batchSize] 对应的每段参考时长（= VAD 的 maxSegment 默认上限）。
  static const int kAsrBatchReferenceSeconds = 20;

  /// 每块 PCM 的时长（秒）。也是检查点粒度上限。
  final int chunkSeconds;
  final AsrCueBuilder cueBuilder;

  /// 进度事件的最小间隔（同一块内按批次发，防止刷屏）。
  final Duration progressInterval;

  /// 取解码器当前统计的钩子（进度事件随带）；null = 进度不带统计。
  final AsrDecodeStats Function()? statsProvider;

  /// 解码器支持三段式时是否走流水线（false = 逐批 decodeBatch，基准对照用）。
  final bool usePipeline;

  bool _pauseRequested = false;
  bool _started = false;

  /// 请求在下一个检查点暂停（块边界，通常 ≤ chunkSeconds 音频的处理时间）。
  void requestPause() => _pauseRequested = true;

  bool get isPauseRequested => _pauseRequested;

  File get _stateFile => File(p.join(jobDir.path, AsrJobFiles.state));
  File get _segmentsFile => File(p.join(jobDir.path, AsrJobFiles.segments));
  File get _srtFile => File(p.join(jobDir.path, AsrJobFiles.srt));
  File get _cueTokensFile => File(p.join(jobDir.path, AsrJobFiles.cueTokens));

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
      if (_cueTokensFile.existsSync()) await _cueTokensFile.delete();
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
        decodeStats: statsProvider?.call(),
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

      final int budgetSamples =
          batchSize * kAsrBatchReferenceSeconds * kAsrSampleRate;
      final AsrBatchShaper? shaper =
          decoder is AsrBatchShaper ? decoder as AsrBatchShaper : null;
      int pendingSamples() => pending.fold<int>(
            0,
            (int acc, AsrSpeechSegment s) => acc + s.samples.length,
          );
      int longestPending() => pending.fold<int>(
            0,
            (int acc, AsrSpeechSegment s) =>
                s.samples.length > acc ? s.samples.length : acc,
          );

      /// 静态桶模式：下一批该取哪些段（不从 pending 移除）。pending 已按段长降序，
      /// 同桶的段连续；优先取**第一个攒满的桶**（整批 cap 行、零空行），[all] 时
      /// 退而取最长段所在桶的残批。null = 没有可发的批。
      List<AsrSpeechSegment>? selectBucketBatch({required bool all}) {
        final AsrBatchShaper s = shaper!;
        int start = 0;
        List<AsrSpeechSegment>? firstGroup;
        while (start < pending.length) {
          final int longest = pending[start].samples.length;
          final int? key = s.bucketKeyFor(longest);
          // 超出最大桶的段（静态模式下 VAD 已切到 10 s，正常到不了）按动态上限成批。
          final int cap = s.batchCapFor(longest) ?? maxBatchSegments;
          int end = start + 1;
          while (end < pending.length &&
              s.bucketKeyFor(pending[end].samples.length) == key) {
            end++;
          }
          final int take = end - start < cap ? end - start : cap;
          final List<AsrSpeechSegment> group = pending.sublist(
            start,
            start + take,
          );
          if (take >= cap) return group;
          firstGroup ??= group;
          start = end;
        }
        return all ? firstGroup : null;
      }

      bool enoughPending() {
        if (pending.isEmpty) return false;
        if (shaper?.batchCapFor(longestPending()) != null) {
          return selectBucketBatch(all: false) != null;
        }
        return pending.length >= maxBatchSegments ||
            pendingSamples() >= budgetSamples;
      }

      final AsrPipelinedDecoder? pipe =
          usePipeline && decoder is AsrPipelinedDecoder
              ? decoder as AsrPipelinedDecoder
              : null;
      // 流水线状态（跨 drain 调用保留，块末 drain(all: true) 冲干净）。
      Future<AsrEncodedBatch>? inFlight;
      List<AsrSpeechSegment> inFlightSegments = const <AsrSpeechSegment>[];
      List<AsrSpeechSegment>? peeked;
      AsrBatchFeatures? peekedFeatures;

      Future<void> commit(
        List<AsrSpeechSegment> batch,
        List<AsrDecodedSegment> decoded,
      ) async {
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

      /// 下一批该取哪些段（不移除）：静态桶按桶分组（见 [selectBucketBatch]），
      /// 动态路径从最长段起按音频预算取（[pickBatchSize]）。
      List<AsrSpeechSegment> selectBatch({required bool all}) {
        if (shaper?.batchCapFor(pending.first.samples.length) != null) {
          return selectBucketBatch(all: all) ?? const <AsrSpeechSegment>[];
        }
        final int take = pickBatchSize(
          pending,
          budgetSamples: budgetSamples,
          maxSegments: maxBatchSegments,
        );
        return pending.sublist(0, take);
      }

      bool sameSegments(List<AsrSpeechSegment> a, List<AsrSpeechSegment> b) {
        if (a.length != b.length) return false;
        for (int k = 0; k < a.length; k++) {
          if (!identical(a[k], b[k])) return false;
        }
        return true;
      }

      /// 取下一批：若上一轮已经窥视过（并提前算了 fbank）且选中的段没变，就复用
      /// 同一个列表对象，让 encode 认出提前算好的特征。
      List<AsrSpeechSegment> takeBatch({required bool all}) {
        final List<AsrSpeechSegment> chosen = selectBatch(all: all);
        final List<AsrSpeechSegment>? p = peeked;
        peeked = null;
        final List<AsrSpeechSegment> batch;
        if (p != null && sameSegments(p, chosen)) {
          batch = p;
        } else {
          peekedFeatures = null;
          batch = chosen;
        }
        final Set<AsrSpeechSegment> taken = Set<AsrSpeechSegment>.identity()
          ..addAll(batch);
        pending.removeWhere(taken.contains);
        return batch;
      }

      Future<void> flushInFlight() async {
        final Future<AsrEncodedBatch>? f = inFlight;
        if (f == null || pipe == null) return;
        inFlight = null;
        final AsrEncodedBatch enc = await f;
        await commit(enc.segments, await pipe.search(enc));
        inFlightSegments = const <AsrSpeechSegment>[];
      }

      Future<void> drain({required bool all}) async {
        // 按段长降序、按音频预算成批：encoder 按批内最长 pad、Loop 图每一步都
        // 带着整批算，长短混批的 padding 全是白付（2026-09-06 实测：英语朗读段
        // 普遍顶到 20 s 上限、日语对话段几秒一段，固定 32 段一批时 padding
        // 2.7x / 2.2x，encoder 占 ASR 阶段九成）。段落顺序本身无意义：落盘按
        // startMs 恢复、cue 构造前会重排。
        pending.sort(
          (AsrSpeechSegment a, AsrSpeechSegment b) =>
              b.samples.length.compareTo(a.samples.length),
        );
        // 排序可能让窥视过的批失效（takeBatch 会按元素身份复核）。
        while (pending.isNotEmpty && (all || enoughPending())) {
          final List<AsrSpeechSegment> batch = takeBatch(all: all);
          if (pipe == null) {
            await commit(batch, await decoder.decodeBatch(batch));
            continue;
          }
          // 三级流水线：GPU 编码第 i 批 ‖ CPU 搜索第 i-1 批 ‖ Dart 算第 i+1 批
          // 的 fbank。插件把 GPU 会话与 CPU 会话放在两条工作线程上，三者才真能
          // 同时跑（2026-09-06：串行时 fbank + 搜索 + ffmpeg 占 30 分钟英语
          // 7.2 s 里的四成，GPU 那段时间全闲着）。
          final AsrBatchFeatures? ready = peekedFeatures;
          peekedFeatures = null;
          final Future<AsrEncodedBatch> encoding = pipe.encode(
            batch,
            features: ready,
          );
          Future<List<AsrDecodedSegment>>? searching;
          AsrEncodedBatch? previous;
          final Future<AsrEncodedBatch>? prevFuture = inFlight;
          inFlight = null;
          inFlightSegments = batch;
          if (prevFuture != null) {
            previous = await prevFuture;
            searching = pipe.search(previous);
          }
          // 趁 GPU / CPU 会话都在忙：窥视下一批并把它的 fbank 先算出来。
          if (pending.isNotEmpty && (all || enoughPending())) {
            final List<AsrSpeechSegment> next = selectBatch(all: all);
            if (next.isNotEmpty) {
              peeked = next;
              peekedFeatures = pipe.computeFeatures(next);
            }
          }
          if (searching != null) {
            await commit(previous!.segments, await searching);
          }
          inFlight = encoding;
        }
        if (all) await flushInFlight();
      }

      /// 检查点：最早一个**还没落盘**的段（攒批中 / 在飞的批）的起点；没有则
      /// [fallback]。恢复时从它重喂，被裁掉的已落盘段重跑一遍，绝不漏段。
      int checkpointSample(int fallback) {
        int earliest = fallback;
        for (final AsrSpeechSegment s in pending) {
          if (s.startSample < earliest) earliest = s.startSample;
        }
        for (final AsrSpeechSegment s in inFlightSegments) {
          if (s.startSample < earliest) earliest = s.startSample;
        }
        return earliest;
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
          while (enoughPending()) {
            await drain(all: false);
            final DateTime now = DateTime.now();
            if (now.difference(lastProgressAt) >= progressInterval) {
              lastProgressAt = now;
              yield AsrTranscribeProgressEvent(
                snapshot(fileIndex, _samplesToMs(chunk.endSample)),
              );
            }
          }
          // 块结束：只发攒满的批，半批留到下一块继续攒——静态桶一批固定 N 行，
          // 块末硬冲半批的空行是 2026-09-06 基线里 padding 2~3x 的最大来源
          // （30 分钟英语 331 段 / 18 批，平均 18 行占 32 行）。检查点取最早一个
          // 未落盘段的起点，恢复时从它重喂（见 [checkpointSample]）。
          await drain(all: false);
          // 在飞的批**不**在这里等它落盘：等 = 搜索它的那 ~50 ms 里 GPU 空转 +
          // 下一块首批的 fbank 没被提前算，每块一个气泡（30 分钟 6 块 ≈ 0.5 s，
          // 7 小时 84 块 ≈ 8 s）。检查点由 [checkpointSample] 把在飞批的起点也
          // 算进去，只是恢复点最多落后一批（≤ 桶行数 × 10 s 音频，崩溃后重跑
          // 一批 ≈ 零点几秒 GPU），换整条流水线跨块不断。
          state = _withResume(
            state,
            fileIndex,
            checkpointSample(
              segmenter.inProgressSpeechStartSample ?? chunk.endSample,
            ),
          );
          await _writeState(state);
          yield AsrTranscribeProgressEvent(
            snapshot(fileIndex, _samplesToMs(chunk.endSample)),
          );
          if (_pauseRequested) {
            // 暂停：把半批也冲干净再落检查点，恢复点 = 进行中语音起点，与暂停前
            // 落盘的段一一对应，续跑不重复解码。
            await drain(all: true);
            state = _withResume(
              state,
              fileIndex,
              segmenter.inProgressSpeechStartSample ?? chunk.endSample,
            );
            await _writeState(state);
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
    await _cueTokensFile.writeAsString(
      serializeAsrCueTokens(cues),
      flush: true,
    );
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

  /// 从**按段长降序**的 [sorted] 头部取一批的段数（纯函数）：
  /// - 段数 × 最长段 ≤ [budgetSamples]（encoder 真正要算的就是这个 pad 后面积）；
  /// - 不超过 [maxSegments]；
  /// - 遇到比批内最长段短一半以上的段就停（它和后面更短的段自成一批更划算，
  ///   否则整批的 padding 直接翻倍）；
  /// - 至少 1 段（超预算的单段也得解）。
  @visibleForTesting
  static int pickBatchSize(
    List<AsrSpeechSegment> sorted, {
    required int budgetSamples,
    required int maxSegments,
  }) {
    if (sorted.isEmpty) return 0;
    final int longest = sorted.first.samples.length;
    if (longest <= 0) return 1;
    int n = 1;
    while (n < sorted.length && n < maxSegments) {
      if ((n + 1) * longest > budgetSamples) break;
      if (sorted[n].samples.length * kDynamicBatchMinLengthRatioDen <
          longest * kDynamicBatchMinLengthRatioNum) {
        break;
      }
      n++;
    }
    return n;
  }

  /// 动态路径一批里最短段 / 最长段的下限（4/5 = 0.8）。
  ///
  /// CPU 上 padding 直接等于算力：encoder 与 Loop 图搜索都按批内最长段算满，
  /// 比它短的行全是白付。旧规则 1/2 让 padding 最坏 2×（2026-09-06 实测 CPU int8
  /// 30 分钟英语 1.4~2.2×）；0.8 把最坏值压到 1.25×，代价是批变小、ORT 往返变多
  /// ——CPU 动态 shape 每次 run 的规划开销只有几毫秒，远小于多算几成帧。
  /// 整数分子 / 分母写法避免浮点比较。
  static const int kDynamicBatchMinLengthRatioNum = 4;
  static const int kDynamicBatchMinLengthRatioDen = 5;

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
