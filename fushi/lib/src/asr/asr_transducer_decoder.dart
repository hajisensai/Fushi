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

import 'dart:typed_data';

import 'package:fushi/src/asr/asr_fbank.dart';
import 'package:fushi/src/asr/asr_greedy_graph.dart' show AsrGreedyGraphIo;
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart' show AsrBatchDecoder;
import 'package:fushi/src/onnx/onnx_inference.dart';

class AsrTransducerDecoder implements AsrBatchDecoder {
  AsrTransducerDecoder({
    required OnnxSession encoder,
    required OnnxSession decoder,
    required OnnxSession joiner,
    required AsrTokenTable tokens,
    AsrFbank fbank = const AsrFbank(),
    this.lookaheadFrames = kDefaultLookaheadFrames,
    OnnxSession? greedy,
  }) : _encoder = encoder,
       _decoder = decoder,
       _joiner = joiner,
       _greedy = greedy,
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
  final AsrTokenTable _tokens;
  final AsrFbank _fbank;

  /// 当前是否走 Loop 图路径。
  bool get usesGreedyGraph => _greedy != null;

  /// 一次 encoder 前向 + 整批逐帧贪心解码；返回与 [segments] 等长、同序的结果。
  @override
  Future<List<AsrDecodedSegment>> decodeBatch(
    List<AsrSpeechSegment> segments,
  ) async {
    if (segments.isEmpty) return <AsrDecodedSegment>[];
    final int batch = segments.length;

    // 1. fbank + pad。
    final List<Float32List> features = <Float32List>[];
    final Int64List frameCounts = Int64List(batch);
    int maxFrames = 0;
    for (int i = 0; i < batch; i++) {
      final Float32List f = _fbank.compute(segments[i].samples);
      features.add(f);
      final int frames = f.length ~/ kAsrFeatureDim;
      frameCounts[i] = frames;
      if (frames > maxFrames) maxFrames = frames;
    }
    if (maxFrames == 0) {
      return List<AsrDecodedSegment>.filled(batch, AsrDecodedSegment.empty);
    }
    final Float32List x = Float32List(batch * maxFrames * kAsrFeatureDim);
    for (int i = 0; i < batch; i++) {
      final int base = i * maxFrames * kAsrFeatureDim;
      final Float32List f = features[i];
      x.setRange(base, base + f.length, f);
      x.fillRange(
        base + f.length,
        base + maxFrames * kAsrFeatureDim,
        kFeaturePadValue,
      );
    }

    // 2. encoder。
    final Map<String, OnnxTensor> encOut = await _encoder.run(
      <String, OnnxTensor>{
        AsrModelIo.encoderInputX: OnnxTensor.float32(x, <int>[
          batch,
          maxFrames,
          kAsrFeatureDim,
        ]),
        AsrModelIo.encoderInputXLens: OnnxTensor.int64(frameCounts, <int>[
          batch,
        ]),
      },
    );
    final OnnxTensor encoderOut = _require(encOut, AsrModelIo.encoderOutput);
    final OnnxTensor encoderLens = _require(
      encOut,
      AsrModelIo.encoderOutputLens,
    );
    if (encoderOut.shape.length != 3 || encoderOut.shape[0] != batch) {
      throw StateError('encoder_out 形状异常：${encoderOut.shape}（batch=$batch）');
    }
    final int encFrames = encoderOut.shape[1];
    final int encDim = encoderOut.shape[2];
    final Float32List encData = _floatData(
      encoderOut,
      AsrModelIo.encoderOutput,
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

    final OnnxSession? greedy = _greedy;
    if (greedy != null) {
      return _decodeWithGreedyGraph(
        greedy: greedy,
        encoderOut: encoderOut,
        encoderLens: encoderLens,
        encData: encData,
        encFrames: encFrames,
        encLens: encLens,
        batch: batch,
      );
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
    return List<AsrDecodedSegment>.generate(batch, (int i) {
      final List<int> ys = hyps[i].sublist(kAsrDecoderContextSize);
      return AsrDecodedSegment(
        tokens: List<String>.unmodifiable(ys.map(_tokens.tokenAt)),
        tokenOffsetsMs: List<int>.unmodifiable(
          frames[i].map((int f) => f * kAsrEncoderFrameMs),
        ),
      );
    });
  }

  /// Loop 图路径：把 encoder 输出原样喂进派生图，读回 `emitted[N,T]`（每帧发射的
  /// token id，-1 = 无），按帧还原 token 与时间。
  Future<List<AsrDecodedSegment>> _decodeWithGreedyGraph({
    required OnnxSession greedy,
    required OnnxTensor encoderOut,
    required OnnxTensor encoderLens,
    required Float32List encData,
    required int encFrames,
    required List<int> encLens,
    required int batch,
  }) async {
    final Int64List lens = Int64List.fromList(encLens);
    final Map<String, OnnxTensor> out = await greedy.run(<String, OnnxTensor>{
      AsrGreedyGraphIo.encoderOut: OnnxTensor.float32(
        encData,
        List<int>.from(encoderOut.shape),
      ),
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
      final List<String> tokens = <String>[];
      final List<int> offsets = <int>[];
      for (int t = 0; t < encLens[i]; t++) {
        final int y = _lengthAt(emitted, i * encFrames + t);
        if (y < 0) continue;
        tokens.add(_tokens.tokenAt(y));
        offsets.add(t * kAsrEncoderFrameMs);
      }
      return AsrDecodedSegment(
        tokens: List<String>.unmodifiable(tokens),
        tokenOffsetsMs: List<int>.unmodifiable(offsets),
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
