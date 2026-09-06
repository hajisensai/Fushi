/// 批量贪心 RNN-T（transducer）解码：fbank → encoder → 逐帧 joiner/decoder。
///
/// 算法对齐 sherpa-onnx `OfflineTransducerGreedySearchDecoder`：
/// - 每条假设初始上下文 `[blank, blank]`（`context_size=2`），decoder_out 先算一次；
/// - 对每个编码帧 t：`logit = joiner(encoder_out[i,t], decoder_out[i])`，取 argmax；
///   `y != blank && y != unk` 才发射：追加 token、记帧 t、上下文换成最后两个 token、
///   重算该条的 decoder_out；unk 与 blank 都不发射、不更新上下文；
/// - **每帧最多发射一个符号**（无 max_sym_per_frame 循环）。
///
/// 与 sherpa-onnx 的两点实现差异（结果等价）：
/// 1. 每帧只把「仍有剩余帧（t < encoder_out_lens[i]）」的样本拼成一次 joiner 调用，
///    已结束的样本不再参与；
/// 2. 每帧只把「本帧发射了新 token」的样本拼成一次 decoder 调用，其余样本沿用旧
///    decoder_out（decoder 无状态，结果与整批重算一致）。
///
/// encoder 输入按 batch 内最长帧数 pad，pad 值与 sherpa-onnx `PadSequence` 相同
/// （`log(1e-10) ≈ -23.0259`），`x_lens` 给真实帧数。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/asr/asr_encoder_buckets.dart';
import 'package:fushi/src/asr/asr_fbank.dart';
import 'package:fushi/src/asr/asr_greedy_graph.dart' show AsrGreedyGraphIo;
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart'
    show AsrBatchDecoder, AsrBatchShaper, AsrPipelinedDecoder;
import 'package:fushi/src/onnx/onnx_inference.dart';

/// 解码器累计的分阶段耗时与帧数（诊断用，进度 UI / 集成测试打印）。
///
/// [paddedFrames] 是 encoder 实际算过的帧数（batch × 批内最长），[realFrames] 是
/// 各段真实帧数之和；两者之比就是 padding 浪费——批内段长参差时 Loop 图每一步都
/// 要带着已结束的行一起算。
@immutable
class AsrDecodeStats {
  const AsrDecodeStats({
    this.batches = 0,
    this.segments = 0,
    this.realFrames = 0,
    this.paddedFrames = 0,
    this.fbank = Duration.zero,
    this.encoder = Duration.zero,
    this.search = Duration.zero,
    this.staticBatches = 0,
  });

  final int batches;

  /// 其中走 GPU 静态 shape 桶的批数（其余走动态会话）。
  final int staticBatches;
  final int segments;
  final int realFrames;
  final int paddedFrames;
  final Duration fbank;
  final Duration encoder;
  final Duration search;

  /// encoder 实际算过的帧数 / 真实帧数。两条路径口径一致：都是「喂给 encoder 的
  /// 张量面积 ÷ 各段真实帧数之和」——动态路径的面积是 batch × 批内最长，静态路径
  /// 是桶的 N × T（含哨兵行）。1.0 = 零浪费。
  double get paddingRatio => realFrames == 0 ? 1 : paddedFrames / realFrames;

  AsrDecodeStats add({
    required int segments,
    required int realFrames,
    required int paddedFrames,
    required Duration fbank,
    required Duration encoder,
    required Duration search,
    bool usedStaticBucket = false,
  }) {
    return AsrDecodeStats(
      batches: batches + 1,
      staticBatches: staticBatches + (usedStaticBucket ? 1 : 0),
      segments: this.segments + segments,
      realFrames: this.realFrames + realFrames,
      paddedFrames: this.paddedFrames + paddedFrames,
      fbank: this.fbank + fbank,
      encoder: this.encoder + encoder,
      search: this.search + search,
    );
  }

  @override
  String toString() =>
      'AsrDecodeStats(batches=$batches static=$staticBatches segments=$segments '
      'frames=$realFrames padded=$paddedFrames '
      'padding=${paddingRatio.toStringAsFixed(2)}x '
      'fbank=${fbank.inMilliseconds}ms encoder=${encoder.inMilliseconds}ms '
      'search=${search.inMilliseconds}ms)';
}

class AsrTransducerDecoder
    implements AsrBatchDecoder, AsrBatchShaper, AsrPipelinedDecoder {
  AsrTransducerDecoder({
    required OnnxSession encoder,
    required OnnxSession decoder,
    required OnnxSession joiner,
    required AsrTokenTable tokens,
    AsrFbank fbank = const AsrFbank(),
    this.lookaheadFrames = kDefaultLookaheadFrames,
    OnnxSession? greedy,
    AsrStaticEncoderPool? staticEncoders,
  }) : _encoder = encoder,
       _decoder = decoder,
       _joiner = joiner,
       _greedy = greedy,
       _staticEncoders = staticEncoders,
       _tokens = tokens,
       _fbank = fbank {
    if (tokens.blankId < 0) {
      throw ArgumentError.value(tokens, 'tokens', '词表缺少 <blk>');
    }
    if (lookaheadFrames < 1) {
      throw ArgumentError.value(lookaheadFrames, 'lookaheadFrames', '至少 1');
    }
  }

  /// sherpa-onnx `PadSequence` 的填充值：`log(1e-10)`。
  static const double kFeaturePadValue = -23.025850929940457;

  /// 前瞻帧数默认值。1 = 经典逐帧贪心；越大往返越少，但每次 joiner 的行数与
  /// 读回的 logit（rows × 5224 float）随之变大，且发射后多算的帧作废。
  ///
  /// 2026-09-05 真机扫描（`integration_test/asr_directml_session_lifecycle_itest.dart`，
  /// 无職転生 01 前 10 分钟、185 段）：GPU/DirectML 编码器 + CPU joiner 下 K=1 5.78 s、
  /// K=4 5.86 s、K=8 5.97 s、K=16 7.68 s、K=32 9.58 s；CPU int8 K=1 18.9 s、K=8 17.6 s、
  /// K=16 19.0 s。往返次数确实降了，但耗时与 joiner **行数**成正比而不是与调用次数
  /// 成正比——前瞻多算的帧全是白付。故默认 1；机制保留给后续「argmax 融进 joiner
  /// 图」之类把逐行成本压下去之后再评估。
  static const int kDefaultLookaheadFrames = 1;

  /// 每轮 joiner 对每条假设最多前瞻的编码器帧数（结果与逐帧贪心逐字等价）。
  final int lookaheadFrames;

  final OnnxSession _encoder;
  final OnnxSession _decoder;
  final OnnxSession _joiner;

  /// 派生的贪心 Loop 图（`asr_greedy_graph.dart`）：给了就整批一次调用完成
  /// 逐帧贪心，decoder/joiner 会话不再被调用；null 走 Dart 逐帧循环。两条路径
  /// 语义逐字等价（等价性由 `tool/asr/verify_greedy_graph.py` 真模型对拍钉住）。
  final OnnxSession? _greedy;

  /// GPU 静态 shape 编码器桶（`asr_encoder_buckets.dart`）；null 或桶建失败时
  /// 用动态会话 [_encoder]。
  final AsrStaticEncoderPool? _staticEncoders;
  final AsrTokenTable _tokens;
  final AsrFbank _fbank;

  /// 当前是否走 Loop 图路径。
  bool get usesGreedyGraph => _greedy != null;

  /// 静态桶对一批的行数封顶（最长段决定桶）；没有静态桶时 null。
  @override
  int? batchCapFor(int longestSamples) =>
      _staticEncoders?.batchCapFor(AsrFbank.frameCount(longestSamples));

  AsrDecodeStats _stats = const AsrDecodeStats();

  /// 自构造起累计的分阶段耗时与帧数。
  AsrDecodeStats get stats => _stats;

  /// 一次 encoder 前向 + 整批逐帧贪心解码；返回与 [segments] 等长、同序的结果。
  ///
  /// 等价于 `search(await encode(segments))`；行数超过静态桶容量时拆成多批。
  /// 要把 GPU 编码、CPU 搜索与 Dart fbank 叠起来跑，用 [computeFeatures] /
  /// [encode] / [search] 三段（`asr_transcribe_job.dart` 的流水线）。
  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async {
    if (segments.isEmpty) return <AsrDecodedSegment>[];
    // 静态桶的行数封顶：超过就拆成多批（任务侧已按 batchCapFor 封顶，这里只是
    // 兜底，保证直接调用者也不会把 64 行塞进 N=32 的桶）。
    final int? cap = _capFor(segments);
    if (cap != null && segments.length > cap) {
      final List<AsrDecodedSegment> out = <AsrDecodedSegment>[];
      for (int i = 0; i < segments.length; i += cap) {
        final int end = i + cap > segments.length ? segments.length : i + cap;
        out.addAll(await decodeBatch(segments.sublist(i, end)));
      }
      return out;
    }
    return search(await encode(segments));
  }

  int? _capFor(List<AsrSpeechSegment> segments) {
    final AsrStaticEncoderPool? pool = _staticEncoders;
    if (pool == null || segments.length <= 1) return null;
    int longest = 0;
    for (final AsrSpeechSegment s in segments) {
      if (s.samples.length > longest) longest = s.samples.length;
    }
    return pool.batchCapFor(AsrFbank.frameCount(longest));
  }

  /// 第一段：fbank（纯 Dart，同步）。流水线里趁 GPU / CPU 会话都在忙时算下一批。
  @override
  AsrBatchFeatures computeFeatures(List<AsrSpeechSegment> segments) {
    final Stopwatch clock = Stopwatch()..start();
    final int batch = segments.length;
    final List<Float32List> features = <Float32List>[];
    final Int64List frameCounts = Int64List(batch);
    int maxFrames = 0;
    int realFrames = 0;
    for (int i = 0; i < batch; i++) {
      final Float32List f = _fbank.compute(segments[i].samples);
      features.add(f);
      final int frames = f.length ~/ kAsrFeatureDim;
      frameCounts[i] = frames;
      realFrames += frames;
      if (frames > maxFrames) maxFrames = frames;
    }
    return AsrBatchFeatures._(
      segments: segments,
      features: features,
      frameCounts: frameCounts,
      maxFrames: maxFrames,
      realFrames: realFrames,
      fbankTime: clock.elapsed,
    );
  }

  /// 第二段：encoder 前向（GPU 会话；静态桶或动态会话）。[features] 缺省现算。
  /// 返回后 encoder 输出已读回主机，可立刻发起下一批的 encoder 而不等搜索。
  @override
  Future<AsrEncodedBatch> encode(
    List<AsrSpeechSegment> segments, {
    AsrBatchFeatures? features,
  }) async {
    if (segments.isEmpty) {
      throw ArgumentError.value(segments, 'segments', '空批');
    }
    final int? cap = _capFor(segments);
    if (cap != null && segments.length > cap) {
      throw ArgumentError.value(
        segments.length,
        'segments',
        '超过静态桶容量 $cap（调用方按 batchCapFor 封顶，或用 decodeBatch）',
      );
    }
    final AsrBatchFeatures feats =
        features != null && identical(features.segments, segments)
        ? features
        : computeFeatures(segments);
    final int batch = segments.length;
    final int maxFrames = feats.maxFrames;
    if (maxFrames == 0) {
      return AsrEncodedBatch._empty(segments, feats.fbankTime);
    }
    final Stopwatch clock = Stopwatch()..start();

    // encoder：有静态桶就填成桶的 [N_b, T_b, 80]——多出的行喂 pad 值、
    // x_lens = T_b（哨兵行，让 x_lens.max() 恒等于 T_b，见
    // `asr_encoder_buckets.dart` 文件头），否则按批内最长 pad 走动态会话。
    final AsrStaticEncoderPool? pool = _staticEncoders;
    final AsrStaticEncoderSession? fixed = pool == null
        ? null
        : await pool.sessionFor(maxFrames);
    final int rows = fixed?.bucket.batch ?? batch;
    final int cols = fixed?.bucket.frames ?? maxFrames;
    assert(rows > batch || fixed == null, '静态桶至少留一行哨兵');
    assert(cols >= maxFrames);
    final Float32List x = Float32List(rows * cols * kAsrFeatureDim);
    final Int64List xLens = Int64List(rows);
    for (int i = 0; i < rows; i++) {
      final int base = i * cols * kAsrFeatureDim;
      final Float32List? f = i < batch ? feats.features[i] : null;
      if (f != null) x.setRange(base, base + f.length, f);
      x.fillRange(
        base + (f?.length ?? 0),
        base + cols * kAsrFeatureDim,
        kFeaturePadValue,
      );
      xLens[i] = f == null ? cols : feats.frameCounts[i];
    }
    // run 与**输出契约校验**必须在同一个 try 里：融合图少给一个输出 key、或回来
    // 的行数与 rows 对不上，同样是「这个静态桶跑不动」的表现形态，而且正是全新
    // 代码路径最可能出问题的地方。留在 try 外的话，本该「标桶不可用 + 回退动态」
    // 的情形会直接把整条转录任务抛异常终止 —— 与设计意图相反。
    late final OnnxTensor encoderOutAll;
    late final OnnxTensor encoderLens;
    try {
      final Map<String, OnnxTensor> encOut = await (fixed?.session ?? _encoder)
          .run(<String, OnnxTensor>{
            AsrModelIo.encoderInputX: OnnxTensor.float32(x, <int>[
              rows,
              cols,
              kAsrFeatureDim,
            ]),
            AsrModelIo.encoderInputXLens: OnnxTensor.int64(xLens, <int>[rows]),
          });
      encoderOutAll = _require(encOut, AsrModelIo.encoderOutput);
      encoderLens = _require(encOut, AsrModelIo.encoderOutputLens);
      if (encoderOutAll.shape.length != 3 || encoderOutAll.shape[0] != rows) {
        throw StateError('encoder_out 形状异常：${encoderOutAll.shape}（rows=$rows）');
      }
    } catch (error, stack) {
      // 静态桶建得起来但跑不动（DML 对某些静态 shape 的算子实现有缺陷）：把
      // 这个桶标为不可用、本批回退动态会话，任务不中断；原因留在池子里。
      if (fixed == null || pool == null) rethrow;
      pool.markUnavailable(fixed.bucket, error, stack);
      return encode(segments, features: feats);
    }
    final int encFrames = encoderOutAll.shape[1];
    final int encDim = encoderOutAll.shape[2];
    // 只保留真实行（填充行排在后面，是连续前缀）。
    final Float32List encData = rows == batch
        ? _floatData(encoderOutAll, AsrModelIo.encoderOutput)
        : Float32List.sublistView(
            _floatData(encoderOutAll, AsrModelIo.encoderOutput),
            0,
            batch * encFrames * encDim,
          );
    final List<int> encLens = List<int>.generate(batch, (int i) {
      final int len = _lengthAt(encoderLens, i);
      if (len < 0 || len > encFrames) {
        throw StateError(
          'encoder_out_lens[$i]=$len 超出 encoder_out 帧数 $encFrames',
        );
      }
      return len;
    });
    return AsrEncodedBatch._(
      segments: segments,
      encData: encData,
      encFrames: encFrames,
      encDim: encDim,
      encLens: encLens,
      realFrames: feats.realFrames,
      paddedFrames: rows * cols,
      fbankTime: feats.fbankTime,
      encoderTime: clock.elapsed,
      isStatic: fixed != null,
    );
  }

  /// 第三段：逐帧贪心搜索（CPU 会话：Loop 图或 decoder/joiner 逐帧）。
  @override
  Future<List<AsrDecodedSegment>> search(AsrEncodedBatch encoded) async {
    final int batch = encoded.segments.length;
    if (encoded.isEmpty) {
      _stats = _stats.add(
        segments: batch,
        realFrames: 0,
        paddedFrames: 0,
        fbank: encoded.fbankTime,
        encoder: Duration.zero,
        search: Duration.zero,
      );
      return List<AsrDecodedSegment>.filled(batch, AsrDecodedSegment.empty);
    }
    final Stopwatch clock = Stopwatch()..start();
    final Float32List encData = encoded.encData;
    final int encFrames = encoded.encFrames;
    final int encDim = encoded.encDim;
    final List<int> encLens = encoded.encLens;

    void account() {
      _stats = _stats.add(
        segments: batch,
        realFrames: encoded.realFrames,
        paddedFrames: encoded.paddedFrames,
        fbank: encoded.fbankTime,
        encoder: encoded.encoderTime,
        search: clock.elapsed,
        usedStaticBucket: encoded.isStatic,
      );
    }

    final OnnxSession? greedy = _greedy;
    if (greedy != null) {
      final List<AsrDecodedSegment> out = await _decodeWithGreedyGraph(
        greedy: greedy,
        encData: encData,
        encFrames: encFrames,
        encDim: encDim,
        encLens: encLens,
        batch: batch,
      );
      account();
      return out;
    }

    // 3. 初始上下文 [blank, blank] 与首个 decoder_out。
    final int blank = _tokens.blankId;
    final int unk = _tokens.unkId;
    final List<List<int>> hyps = List<List<int>>.generate(
      batch,
      (_) => <int>[blank, blank],
    );
    final List<List<int>> frames = List<List<int>>.generate(
      batch,
      (_) => <int>[],
    );
    final Float32List decoderOutAll = await _runDecoder(
      List<int>.generate(batch, (int i) => i),
      hyps,
    );
    final int decDim = decoderOutAll.length ~/ batch;
    final List<Float32List> decoderOut = List<Float32List>.generate(
      batch,
      (int i) =>
          Float32List.sublistView(decoderOutAll, i * decDim, (i + 1) * decDim),
    );

    // 4. 前瞻批量贪心，与逐帧贪心**逐字等价**：两次发射之间 decoder_out 不变，
    //    所以先用当前 decoder_out 对接下来最多 [lookaheadFrames] 帧一次算 joiner，
    //    顺序扫到第一个非 blank 才停下（发射 + 更新 decoder），其余前瞻帧丢弃、
    //    下一轮从发射帧之后重算。ORT 往返从 T 次降到约 tokens + T/lookahead 次
    //    （2026-09-05 真机：逐帧 joiner 往返是 ASR 阶段的大头，encoder 本身在
    //    DirectML 上只占零头）。
    final List<int> pos = List<int>.filled(batch, 0);
    final List<int> active = <int>[];
    final List<int> rowsPer = <int>[];
    final List<int> emitted = <int>[];
    while (true) {
      active.clear();
      rowsPer.clear();
      int totalRows = 0;
      for (int i = 0; i < batch; i++) {
        final int remain = encLens[i] - pos[i];
        if (remain <= 0) continue;
        final int k = remain < lookaheadFrames ? remain : lookaheadFrames;
        active.add(i);
        rowsPer.add(k);
        totalRows += k;
      }
      if (active.isEmpty) break;
      final Float32List encRows = Float32List(totalRows * encDim);
      final Float32List decRows = Float32List(totalRows * decDim);
      int row = 0;
      for (int a = 0; a < active.length; a++) {
        final int i = active[a];
        for (int k = 0; k < rowsPer[a]; k++) {
          final int encBase = (i * encFrames + pos[i] + k) * encDim;
          encRows.setRange(row * encDim, (row + 1) * encDim, encData, encBase);
          decRows.setRange(row * decDim, (row + 1) * decDim, decoderOut[i]);
          row++;
        }
      }
      final Map<String, OnnxTensor> joinOut = await _joiner.run(
        <String, OnnxTensor>{
          AsrModelIo.joinerInputEncoder: OnnxTensor.float32(encRows, <int>[
            totalRows,
            encDim,
          ]),
          AsrModelIo.joinerInputDecoder: OnnxTensor.float32(decRows, <int>[
            totalRows,
            decDim,
          ]),
        },
      );
      final OnnxTensor logit = _require(joinOut, AsrModelIo.joinerOutputLogit);
      if (logit.shape.length != 2 || logit.shape[0] != totalRows) {
        throw StateError('joiner logit 形状异常：${logit.shape}（rows=$totalRows）');
      }
      final int vocab = logit.shape[1];
      final Float32List logitData = _floatData(
        logit,
        AsrModelIo.joinerOutputLogit,
      );

      emitted.clear();
      row = 0;
      for (int a = 0; a < active.length; a++) {
        final int i = active[a];
        bool stopped = false;
        for (int k = 0; k < rowsPer[a]; k++, row++) {
          if (stopped) continue;
          final int y = _argmax(logitData, row * vocab, vocab);
          final int t = pos[i];
          pos[i] = t + 1;
          if (y == blank || y == unk) continue;
          hyps[i].add(y);
          frames[i].add(t);
          emitted.add(i);
          stopped = true;
        }
      }
      if (emitted.isNotEmpty) {
        final Float32List fresh = await _runDecoder(emitted, hyps);
        for (int r = 0; r < emitted.length; r++) {
          decoderOut[emitted[r]] = Float32List.sublistView(
            fresh,
            r * decDim,
            (r + 1) * decDim,
          );
        }
      }
    }

    // 5. 组装结果（去掉前置两个 blank 上下文）。
    account();
    return List<AsrDecodedSegment>.generate(batch, (int i) {
      return AsrDecodedSegment.fromTokenIds(
        table: _tokens,
        ids: hyps[i].sublist(kAsrDecoderContextSize),
        offsetsMs: <int>[for (final int f in frames[i]) f * kAsrEncoderFrameMs],
      );
    });
  }

  /// Loop 图路径：把 encoder 输出原样喂进派生图，读回 `emitted[N,T]`（每帧发射的
  /// token id，-1 = 无），按帧还原 token 与时间。
  Future<List<AsrDecodedSegment>> _decodeWithGreedyGraph({
    required OnnxSession greedy,
    required Float32List encData,
    required int encFrames,
    required int encDim,
    required List<int> encLens,
    required int batch,
  }) async {
    final Int64List lens = Int64List.fromList(encLens);
    final Map<String, OnnxTensor> out = await greedy.run(<String, OnnxTensor>{
      AsrGreedyGraphIo.encoderOut: OnnxTensor.float32(encData, <int>[
        batch,
        encFrames,
        encDim,
      ]),
      AsrGreedyGraphIo.encoderOutLens: OnnxTensor.int64(lens, <int>[batch]),
    });
    final OnnxTensor emitted = _require(out, AsrGreedyGraphIo.emitted);
    if (emitted.shape.length != 2 ||
        emitted.shape[0] != batch ||
        emitted.shape[1] != encFrames) {
      throw StateError(
        'greedy 图 emitted 形状异常：${emitted.shape}（期望 [$batch, $encFrames]）',
      );
    }
    return List<AsrDecodedSegment>.generate(batch, (int i) {
      final List<int> ids = <int>[];
      final List<int> offsets = <int>[];
      for (int t = 0; t < encLens[i]; t++) {
        final int y = _lengthAt(emitted, i * encFrames + t);
        if (y < 0) continue;
        ids.add(y);
        offsets.add(t * kAsrEncoderFrameMs);
      }
      return AsrDecodedSegment.fromTokenIds(
        table: _tokens,
        ids: ids,
        offsetsMs: offsets,
      );
    });
  }

  /// 对 [indices] 里的每条假设取最后 [kAsrDecoderContextSize] 个 token 作为 `y`，
  /// 一次 decoder 前向；返回扁平 `[rows, decoder_dim]`。
  Future<Float32List> _runDecoder(
    List<int> indices,
    List<List<int>> hyps,
  ) async {
    final int rows = indices.length;
    final Int64List y = Int64List(rows * kAsrDecoderContextSize);
    for (int r = 0; r < rows; r++) {
      final List<int> hyp = hyps[indices[r]];
      for (int k = 0; k < kAsrDecoderContextSize; k++) {
        y[r * kAsrDecoderContextSize + k] =
            hyp[hyp.length - kAsrDecoderContextSize + k];
      }
    }
    final Map<String, OnnxTensor> out = await _decoder.run(<String, OnnxTensor>{
      AsrModelIo.decoderInputY: OnnxTensor.int64(y, <int>[
        rows,
        kAsrDecoderContextSize,
      ]),
    });
    final OnnxTensor decoderOut = _require(out, AsrModelIo.decoderOutput);
    if (decoderOut.shape.length != 2 || decoderOut.shape[0] != rows) {
      throw StateError('decoder_out 形状异常：${decoderOut.shape}（rows=$rows）');
    }
    return _floatData(decoderOut, AsrModelIo.decoderOutput);
  }

  static OnnxTensor _require(Map<String, OnnxTensor> outputs, String name) {
    final OnnxTensor? tensor = outputs[name];
    if (tensor == null) {
      throw StateError('模型输出缺少 $name：${outputs.keys.toList()}');
    }
    return tensor;
  }

  static Float32List _floatData(OnnxTensor tensor, String name) {
    final Float32List? data = tensor.floatData;
    if (data == null) {
      throw StateError('$name 不是 float32 张量（${tensor.type}）');
    }
    return data;
  }

  /// int64 输出经 ORT 层落成 float（整数值），`round()` 取回；fake 会话可直接给 int64。
  static int _lengthAt(OnnxTensor lens, int i) {
    switch (lens.type) {
      case OnnxTensorType.int64:
        return lens.intData![i];
      case OnnxTensorType.float32:
        return lens.floatData![i].round();
    }
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
}

/// [AsrTransducerDecoder.computeFeatures] 的产物：一批段的 fbank 特征。
class AsrBatchFeatures {
  const AsrBatchFeatures._({
    required this.segments,
    required this.features,
    required this.frameCounts,
    required this.maxFrames,
    required this.realFrames,
    required this.fbankTime,
  });

  /// 测试用：不算特征的占位（fake 解码器只关心段与身份）。
  @visibleForTesting
  factory AsrBatchFeatures.forTest(List<AsrSpeechSegment> segments) =>
      AsrBatchFeatures._(
        segments: segments,
        features: const <Float32List>[],
        frameCounts: Int64List(0),
        maxFrames: 0,
        realFrames: 0,
        fbankTime: Duration.zero,
      );

  final List<AsrSpeechSegment> segments;
  final List<Float32List> features;
  final Int64List frameCounts;
  final int maxFrames;
  final int realFrames;
  final Duration fbankTime;
}

/// [AsrTransducerDecoder.encode] 的产物：已读回主机的 encoder 输出（只含真实行）。
class AsrEncodedBatch {
  const AsrEncodedBatch._({
    required this.segments,
    required this.encData,
    required this.encFrames,
    required this.encDim,
    required this.encLens,
    required this.realFrames,
    required this.paddedFrames,
    required this.fbankTime,
    required this.encoderTime,
    required this.isStatic,
  });

  /// 测试用：只带段列表的占位。
  @visibleForTesting
  factory AsrEncodedBatch.forTest(List<AsrSpeechSegment> segments) =>
      AsrEncodedBatch._empty(segments, Duration.zero);

  /// 全部段都没有一帧特征（极短静音）：搜索直接返回空结果。
  AsrEncodedBatch._empty(List<AsrSpeechSegment> segments, Duration fbankTime)
    : this._(
        segments: segments,
        encData: Float32List(0),
        encFrames: 0,
        encDim: 0,
        encLens: const <int>[],
        realFrames: 0,
        paddedFrames: 0,
        fbankTime: fbankTime,
        encoderTime: Duration.zero,
        isStatic: false,
      );

  final List<AsrSpeechSegment> segments;
  final Float32List encData;
  final int encFrames;
  final int encDim;
  final List<int> encLens;
  final int realFrames;
  final int paddedFrames;
  final Duration fbankTime;
  final Duration encoderTime;
  final bool isStatic;

  bool get isEmpty => encFrames == 0;
}
