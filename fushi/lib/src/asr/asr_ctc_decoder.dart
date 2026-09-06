/// CTC 解码：原始波形 → 单个编码器 → 逐帧 argmax → 折叠。给 Omnilingual ASR
/// （`asr_model_manifest.dart` 的 [AsrModelArchitecture.ctc] 包）。
///
/// 与 transducer 路径共用任务流水线（[AsrPipelinedDecoder] 三段）与静态桶池
/// （`asr_encoder_buckets.dart`，桶以**样本数**为时间轴、无哨兵行）：
/// 1. [computeFeatures]：逐段零均值单位方差归一化（对齐 sherpa-onnx
///    `OfflineOmnilingualAsrCtcModel::NormalizeFeatures`），这一步就是本架构的
///    「特征」——没有 fbank；
/// 2. [encode]：有静态桶就把整批填成 `[N_b, S_b]`（多余行喂零、输出丢弃），否则
///    **逐段**动态会话跑精确长度（CPU 上 padding 直接等于算力，不值得为批处理付）；
///    读回 `logits[N, T, V]` 后立刻逐帧 argmax 成 `int32[T]`，主机侧只留 id；
/// 3. [search]：CTC 折叠（去重复、去 blank），token 时间 = 帧号 × 每帧样本数。
///
/// 每帧样本数从输出反推（`num_samples / num_frames`，Omnilingual 为 320 = 20 ms），
/// 不写死——换模型不必改代码。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/asr/asr_encoder_buckets.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart'
    show
        AsrBatchDecoder,
        AsrBatchShaper,
        AsrPipelinedDecoder,
        AsrSegmentDecoder;
import 'package:fushi/src/asr/asr_transducer_decoder.dart'
    show AsrBatchFeatures, AsrDecodeStats, AsrEncodedBatch;
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

/// CTC 模型在 GPU 上的静态桶（时间轴 = 样本数；无哨兵行）：6 / 12 / 21 s，
/// 盖住 VAD 默认 20 s 段上限 + 两侧 pad。行数随长度递减，`N × S` 面积相近。
const List<AsrEncoderBucket> kAsrCtcGpuBuckets = <AsrEncoderBucket>[
  AsrEncoderBucket(frames: 6 * kAsrSampleRate, batch: 8, sentinel: false),
  AsrEncoderBucket(frames: 12 * kAsrSampleRate, batch: 4, sentinel: false),
  AsrEncoderBucket(frames: 21 * kAsrSampleRate, batch: 2, sentinel: false),
];

/// Omnilingual 导出的两个符号维名（`x[N, num_samples]`，已用 onnx 核实）。
const String kAsrCtcBatchDim = 'N';
const String kAsrCtcSamplesDim = 'num_samples';

class AsrCtcDecoder
    implements
        AsrBatchDecoder,
        AsrBatchShaper,
        AsrPipelinedDecoder,
        AsrSegmentDecoder {
  AsrCtcDecoder({
    required OnnxSession model,
    required AsrTokenTable tokens,
    AsrStaticEncoderPool? staticSessions,
  })  : _model = model,
        _tokens = tokens,
        _static = staticSessions {
    if (tokens.blankId < 0) {
      throw ArgumentError.value(tokens, 'tokens', '词表缺少 blank 记号');
    }
  }

  final OnnxSession _model;
  final AsrTokenTable _tokens;
  final AsrStaticEncoderPool? _static;

  AsrDecodeStats _stats = const AsrDecodeStats();

  @override
  AsrDecodeStats get stats => _stats;

  @override
  int? batchCapFor(int longestSamples) => _static?.batchCapFor(longestSamples);

  @override
  int? bucketKeyFor(int longestSamples) =>
      _static?.bucketFor(longestSamples)?.frames;

  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async {
    if (segments.isEmpty) return <AsrDecodedSegment>[];
    final int? cap = _capFor(segments);
    if (cap != null && segments.length > cap) {
      final List<AsrDecodedSegment> out = <AsrDecodedSegment>[];
      for (int i = 0; i < segments.length; i += cap) {
        final int end = math.min(i + cap, segments.length);
        out.addAll(await decodeBatch(segments.sublist(i, end)));
      }
      return out;
    }
    return search(await encode(segments));
  }

  int? _capFor(List<AsrSpeechSegment> segments) {
    final AsrStaticEncoderPool? pool = _static;
    if (pool == null || segments.length <= 1) return null;
    int longest = 0;
    for (final AsrSpeechSegment s in segments) {
      longest = math.max(longest, s.samples.length);
    }
    return pool.batchCapFor(longest);
  }

  /// 逐段零均值单位方差归一化（double 累加，float32 输出）。
  @override
  AsrBatchFeatures computeFeatures(List<AsrSpeechSegment> segments) {
    final Stopwatch clock = Stopwatch()..start();
    final List<Float32List> features = <Float32List>[];
    final Int64List counts = Int64List(segments.length);
    int maxSamples = 0;
    int total = 0;
    for (int i = 0; i < segments.length; i++) {
      final Float32List x = segments[i].samples;
      features.add(normalizeWaveform(x));
      counts[i] = x.length;
      total += x.length;
      maxSamples = math.max(maxSamples, x.length);
    }
    return AsrBatchFeatures.raw(
      segments: segments,
      features: features,
      frameCounts: counts,
      maxFrames: maxSamples,
      realFrames: total,
      fbankTime: clock.elapsed,
    );
  }

  /// `(x - mean) / sqrt(var + 1e-5)`；方差用中心化后的值算（float32 下
  /// `E[x²] - E[x]²` 会灾难性抵消，sherpa-onnx 同样这么做）。
  @visibleForTesting
  static Float32List normalizeWaveform(Float32List x) {
    if (x.isEmpty) return Float32List(0);
    double sum = 0;
    for (final double v in x) {
      sum += v;
    }
    final double mean = sum / x.length;
    double sq = 0;
    for (final double v in x) {
      final double d = v - mean;
      sq += d * d;
    }
    final double inv = 1 / math.sqrt(sq / x.length + 1e-5);
    final Float32List out = Float32List(x.length);
    for (int i = 0; i < x.length; i++) {
      out[i] = (x[i] - mean) * inv;
    }
    return out;
  }

  @override
  Future<AsrEncodedBatch> encode(
    List<AsrSpeechSegment> segments, {
    AsrBatchFeatures? features,
  }) async {
    if (segments.isEmpty) {
      throw ArgumentError.value(segments, 'segments', '空批');
    }
    final AsrBatchFeatures feats =
        features != null && identical(features.segments, segments)
            ? features
            : computeFeatures(segments);
    if (feats.maxFrames == 0) {
      return AsrCtcEncodedBatch._empty(segments, feats.fbankTime);
    }
    final Stopwatch clock = Stopwatch()..start();
    final AsrStaticEncoderPool? pool = _static;
    final AsrStaticEncoderSession? fixed =
        pool == null ? null : await pool.sessionFor(feats.maxFrames);
    if (fixed != null && segments.length > fixed.bucket.realRows) {
      throw ArgumentError.value(
        segments.length,
        'segments',
        '超过静态桶容量 ${fixed.bucket.realRows}（调用方按 batchCapFor 封顶，或用 decodeBatch）',
      );
    }
    final List<Int32List> ids = <Int32List>[];
    int paddedSamples = 0;
    bool usedStatic = false;
    if (fixed != null) {
      final int rows = fixed.bucket.batch;
      final int cols = fixed.bucket.frames;
      final Float32List x = Float32List(rows * cols);
      for (int i = 0; i < segments.length; i++) {
        x.setRange(
            i * cols, i * cols + feats.features[i].length, feats.features[i]);
      }
      try {
        ids.addAll(
          await _runArgmax(fixed.session, x, rows, cols, segments.length),
        );
        usedStatic = true;
        paddedSamples = rows * cols;
      } catch (error, stack) {
        // 桶建得起来但跑不动：标不可用、本批回退动态会话，任务不中断。
        pool!.markUnavailable(fixed.bucket, error, stack);
        return encode(segments, features: feats);
      }
    } else {
      // 动态会话逐段跑精确长度：零 padding。
      for (int i = 0; i < segments.length; i++) {
        final Float32List f = feats.features[i];
        ids.addAll(await _runArgmax(_model, f, 1, f.length, 1));
        paddedSamples += f.length;
      }
    }
    // 每帧样本数：从首段反推（同一模型恒定）。
    int frameSamples = 1;
    for (int i = 0; i < segments.length; i++) {
      if (ids[i].isNotEmpty) {
        final int cols = fixed?.bucket.frames ?? feats.features[i].length;
        frameSamples = math.max(1, cols ~/ ids[i].length);
        break;
      }
    }
    return AsrCtcEncodedBatch._(
      segments: segments,
      frameIds: ids,
      frameSamples: frameSamples,
      realFrames: feats.realFrames ~/ frameSamples,
      paddedFrames: paddedSamples ~/ frameSamples,
      fbankTime: feats.fbankTime,
      encoderTime: clock.elapsed,
      isStatic: usedStatic,
    );
  }

  /// 一段波形一次 run（动态会话、精确长度），返回完整的原始 `logits[T, V]`
  /// 与每帧样本数——强制对齐（`asr_ctc_align.dart`）要整张矩阵做 Viterbi，
  /// 不能像转录那样当场 argmax。20 s 段 ≈ 1000 帧 × 10288 × 4 B ≈ 41 MB，
  /// 调用方逐段拿、用完即弃。
  Future<AsrCtcLogits> runLogits(Float32List samples) async {
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', '空段');
    }
    final Float32List x = normalizeWaveform(samples);
    final Map<String, OnnxTensor> out = await _model.run(<String, OnnxTensor>{
      AsrModelIo.ctcInputX: OnnxTensor.float32(x, <int>[1, x.length]),
    });
    final OnnxTensor? logits = out[AsrModelIo.ctcOutputLogits];
    if (logits == null) {
      throw StateError('模型没有输出 ${AsrModelIo.ctcOutputLogits}：${out.keys}');
    }
    if (logits.shape.length != 3 || logits.shape[0] != 1) {
      throw StateError('logits 形状异常：${logits.shape}');
    }
    final Float32List? data = logits.floatData;
    if (data == null) {
      throw StateError('logits 不是 float32：${logits.type}');
    }
    final int frames = logits.shape[1];
    return AsrCtcLogits(
      logits: data,
      frames: frames,
      vocab: logits.shape[2],
      frameSamples: frames == 0 ? 1 : math.max(1, x.length ~/ frames),
    );
  }

  /// 跑一次模型并对前 [realRows] 行逐帧 argmax。
  Future<List<Int32List>> _runArgmax(
    OnnxSession session,
    Float32List x,
    int rows,
    int cols,
    int realRows,
  ) async {
    final Map<String, OnnxTensor> out = await session.run(<String, OnnxTensor>{
      AsrModelIo.ctcInputX: OnnxTensor.float32(x, <int>[rows, cols]),
    });
    final OnnxTensor? logits = out[AsrModelIo.ctcOutputLogits];
    if (logits == null) {
      throw StateError('模型没有输出 ${AsrModelIo.ctcOutputLogits}：${out.keys}');
    }
    if (logits.shape.length != 3 || logits.shape[0] != rows) {
      throw StateError('logits 形状异常：${logits.shape}（rows=$rows）');
    }
    final Float32List? data = logits.floatData;
    if (data == null) {
      throw StateError('logits 不是 float32：${logits.type}');
    }
    final int frames = logits.shape[1];
    final int vocab = logits.shape[2];
    final List<Int32List> result = <Int32List>[];
    for (int r = 0; r < realRows; r++) {
      final Int32List ids = Int32List(frames);
      int base = r * frames * vocab;
      for (int t = 0; t < frames; t++, base += vocab) {
        ids[t] = _argmax(data, base, vocab);
      }
      result.add(ids);
    }
    return result;
  }

  static int _argmax(Float32List data, int offset, int length) {
    int best = 0;
    double bestValue = data[offset];
    for (int v = 1; v < length; v++) {
      final double value = data[offset + v];
      if (value > bestValue) {
        bestValue = value;
        best = v;
      }
    }
    return best;
  }

  /// CTC 折叠：连续相同 id 只算一次，blank / 特殊符号不发射。
  @override
  Future<List<AsrDecodedSegment>> search(AsrEncodedBatch encodedBatch) async {
    final AsrCtcEncodedBatch encoded = encodedBatch as AsrCtcEncodedBatch;
    final Stopwatch clock = Stopwatch()..start();
    final List<AsrDecodedSegment> out = <AsrDecodedSegment>[];
    for (int i = 0; i < encoded.segments.length; i++) {
      final Int32List ids =
          i < encoded.frameIds.length ? encoded.frameIds[i] : Int32List(0);
      final List<int> emitted = <int>[];
      final List<int> offsets = <int>[];
      int prev = -1;
      for (int t = 0; t < ids.length; t++) {
        final int id = ids[t];
        if (id != prev && !_tokens.isSpecial(id)) {
          emitted.add(id);
          offsets.add(t * encoded.frameSamples * 1000 ~/ kAsrSampleRate);
        }
        prev = id;
      }
      out.add(
        AsrDecodedSegment.fromTokenIds(
          table: _tokens,
          ids: emitted,
          offsetsMs: offsets,
        ),
      );
    }
    _stats = _stats.add(
      segments: encoded.segments.length,
      realFrames: encoded.realFrames,
      paddedFrames: encoded.paddedFrames,
      fbank: encoded.fbankTime,
      encoder: encoded.encoderTime,
      search: clock.elapsed,
      usedStaticBucket: encoded.isStatic,
    );
    return out;
  }
}

/// [AsrCtcDecoder.runLogits] 的产物：一段的原始 `logits[frames × vocab]`
/// （行主序、未 softmax）与每帧样本数（Omnilingual 320 = 20 ms）。
class AsrCtcLogits {
  const AsrCtcLogits({
    required this.logits,
    required this.frames,
    required this.vocab,
    required this.frameSamples,
  });

  final Float32List logits;
  final int frames;
  final int vocab;
  final int frameSamples;

  /// 一帧的毫秒数。
  double get frameMs => frameSamples * 1000 / kAsrSampleRate;
}

/// [AsrCtcDecoder.encode] 的产物：每段逐帧 argmax 后的 id 与每帧样本数。
class AsrCtcEncodedBatch extends AsrEncodedBatch {
  AsrCtcEncodedBatch._({
    required super.segments,
    required this.frameIds,
    required this.frameSamples,
    required super.realFrames,
    required super.paddedFrames,
    required super.fbankTime,
    required super.encoderTime,
    required super.isStatic,
  }) : super(isEmpty: frameIds.isEmpty);

  AsrCtcEncodedBatch._empty(List<AsrSpeechSegment> segments, Duration fbankTime)
      : this._(
          segments: segments,
          frameIds: const <Int32List>[],
          frameSamples: 1,
          realFrames: 0,
          paddedFrames: 0,
          fbankTime: fbankTime,
          encoderTime: Duration.zero,
          isStatic: false,
        );

  final List<Int32List> frameIds;
  final int frameSamples;
}
