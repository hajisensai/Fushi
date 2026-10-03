/// manga-ocr 的 KV cache 解码：与 [MangaOcrRecognizer] 同一套预处理、分词与 beam
/// search，只把 decoder 换成「每步只喂一个新 token」的导出。
///
/// 模型（导出脚本与契约见 `tool/manga_ocr_kv/`）：
/// - `encoder_model.onnx`：原样沿用经典导出（mayocream/manga-ocr-onnx），
///   `pixel_values` [1,3,224,224] → `last_hidden_state` [1,197,768]。
/// - `cross_kv.onnx`：`encoder_hidden_states` [1,197,768] → `cross_key_values`
///   [4,1,12,197,64]（两层 decoder 的 cross-attention K/V，每个文字块只算一次）。
/// - `decoder_kv.onnx`：`input_ids` [B,1] + `beam_idx` [B] + `past_key_values`
///   [4,Bp,12,P,64] + `cross_key_values` → `logits` [B,6144]（只有最后一个位置）
///   + `present_key_values` [4,B,12,P+1,64]。beam 重排在图内按 `beam_idx` Gather；
///   首步喂全零占位 past [4,1,12,1,64]（图内切掉 slot 0，数学上等价于没有 past）。
///
/// 为什么值得：无 cache 的 decoder 每步把整个序列、连同 197 个 encoder token 的
/// cross K/V 投影全部重算，beam 4 每步约 3.7 GFLOPs；KV 版每步只算一个 token。
/// 2026-09-30 实测（i5-12600KF，ORT 1.22 CPU，2 线程，beam 4）：每块 504–685 ms →
/// 298–344 ms；240 块与 HF `generate`、经典 ONNX **逐 token 240/240 一致**。
/// 句柄后端（[OcrHandleSession]）下每步跨 Dart/原生的数据只有 input_ids、beam_idx
/// 与一行 logits。
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/beam_search.dart';
import 'package:fushi_engine/ocr/manga_ocr_recognizer.dart';
import 'package:fushi_engine/ocr/manga_ocr_tokenizer.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_tensor_handles.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// `past_key_values` / `cross_key_values` 的首维：2 层 decoder × (K, V)。
const int kMangaOcrKvLayerSlots = 4;

/// decoder 注意力头数与每头维度（BERT decoder，隐层 768 = 12 × 64）。
const int kMangaOcrKvHeads = 12;
const int kMangaOcrKvHeadDim = 64;

class MangaOcrKvRecognizer implements ScoredOcrRecognizer {
  MangaOcrKvRecognizer({
    required OcrSession encoderSession,
    required OcrSession crossSession,
    required OcrSession decoderSession,
    required this.tokenizer,
    this.numBeams = 4,
    this.lengthPenalty = 2.0,
    this.noRepeatNgramSize = 3,
    this.maxLength = 300,
    this.earlyStopping = true,
  }) : _sessions = <OcrSession>[encoderSession, crossSession, decoderSession],
       _encoder = asOcrHandleSession(encoderSession),
       _cross = asOcrHandleSession(crossSession),
       _decoder = asOcrHandleSession(decoderSession);

  final List<OcrSession> _sessions;
  final OcrHandleSession _encoder;
  final OcrHandleSession _cross;
  final OcrHandleSession _decoder;
  final MangaOcrTokenizer tokenizer;

  final int numBeams;
  final double lengthPenalty;
  final int noRepeatNgramSize;

  /// 含起始 token 的最大长度；decoder_kv 的位置编码上限是 512。
  final int maxLength;
  final bool earlyStopping;

  /// 首步占位 past（全零 [4,1,12,1,64]），整个识别器生命期复用一份。
  Future<OcrTensorHandle>? _placeholderPast;

  Future<OcrTensorHandle> _placeholder() =>
      _placeholderPast ??= _decoder.upload(
        OcrTensor.float32(
          Float32List(
            kMangaOcrKvLayerSlots * kMangaOcrKvHeads * kMangaOcrKvHeadDim,
          ),
          const <int>[
            kMangaOcrKvLayerSlots,
            1,
            kMangaOcrKvHeads,
            1,
            kMangaOcrKvHeadDim,
          ],
        ),
      );

  @override
  Future<String> recognize(img.Image page, OcrRect box) async =>
      (await recognizeScored(page, box)).text;

  @override
  Future<ScoredOcrText> recognizeScored(img.Image page, OcrRect box) async {
    final Float32List pixels = mangaOcrNormalize(
      cropAndResizeForRecognition(page, box),
    );
    final OcrHandleRunResult encoded = await _encoder.runWithHandles(
      tensors: <String, OcrTensor>{
        'pixel_values': OcrTensor.float32(pixels, const <int>[
          1,
          3,
          kRecInputSize,
          kRecInputSize,
        ]),
      },
      fetch: const <String>{},
    );
    final OcrTensorHandle hidden = await _single(
      encoded.kept,
      'last_hidden_state',
    );
    final OcrTensorHandle cross;
    try {
      cross = await _single(
        (await _cross.runWithHandles(
          handles: <String, OcrTensorHandle>{'encoder_hidden_states': hidden},
          fetch: const <String>{},
        )).kept,
        'cross_key_values',
      );
    } finally {
      await hidden.dispose();
    }
    final OcrTensorHandle placeholder = await _placeholder();
    OcrTensorHandle? past;
    bool firstStep = true;
    try {
      final BeamSearchResult result = await beamSearchDecode(
        config: BeamSearchConfig(
          startTokenId: tokenizer.clsId,
          eosTokenId: tokenizer.sepId,
          numBeams: numBeams,
          lengthPenalty: lengthPenalty,
          noRepeatNgramSize: noRepeatNgramSize,
          maxLength: maxLength,
          earlyStopping: earlyStopping,
        ),
        stepLogitsWithOrigin:
            (List<List<int>> sequences, List<int> sourceBeams) async {
              // 首步所有 beam 都是同一个起始 token，且只有 beam 0 的分数有限
              // （beam search 把其余置 -inf）：只算一条再复制，省 3/4 的首步计算；
              // 第二步 beam_idx 全 0，图内自动把单条 past 扩成 numBeams 条。
              final int beams = firstStep ? 1 : sequences.length;
              final Int64List inputIds = Int64List(beams);
              final Int64List beamIdx = Int64List(beams);
              for (int b = 0; b < beams; b++) {
                inputIds[b] = sequences[b].last;
                beamIdx[b] = firstStep ? 0 : sourceBeams[b];
              }
              final OcrHandleRunResult step = await _decoder.runWithHandles(
                tensors: <String, OcrTensor>{
                  'input_ids': OcrTensor.int64(inputIds, <int>[beams, 1]),
                  'beam_idx': OcrTensor.int64(beamIdx, <int>[beams]),
                },
                handles: <String, OcrTensorHandle>{
                  'past_key_values': past ?? placeholder,
                  'cross_key_values': cross,
                },
                fetch: const <String>{'logits'},
              );
              final OcrTensorHandle present = await _single(
                step.kept,
                'present_key_values',
              );
              await past?.dispose();
              past = present;
              final OcrTensor? logits = step.fetched['logits'];
              if (logits == null) {
                throw StateError(
                  'decoder_kv output logits missing: '
                  '${step.fetched.keys.toList()}',
                );
              }
              final Float32List data = logits.floatData!;
              final int vocabSize = data.length ~/ beams;
              final List<Float32List> rows = <Float32List>[
                for (int b = 0; b < beams; b++)
                  Float32List.sublistView(
                    data,
                    b * vocabSize,
                    (b + 1) * vocabSize,
                  ),
              ];
              if (!firstStep) return rows;
              firstStep = false;
              return List<Float32List>.filled(sequences.length, rows.first);
            },
      );
      return (
        text: tokenizer.decode(result.tokens),
        confidence: beamSearchMeanTokenProbability(result, lengthPenalty),
      );
    } finally {
      await past?.dispose();
      await cross.dispose();
    }
  }

  /// 取出名为 [name] 的输出句柄，其余（本识别器用不到的）输出立即释放。
  static Future<OcrTensorHandle> _single(
    Map<String, OcrTensorHandle> kept,
    String name,
  ) async {
    for (final MapEntry<String, OcrTensorHandle> other in kept.entries) {
      if (other.key != name) await other.value.dispose();
    }
    final OcrTensorHandle? handle = kept[name];
    if (handle == null) {
      throw StateError('ONNX output $name missing: ${kept.keys.toList()}');
    }
    return handle;
  }

  Future<void> close() async {
    final Future<OcrTensorHandle>? placeholder = _placeholderPast;
    _placeholderPast = null;
    if (placeholder != null) await (await placeholder).dispose();
    for (final OcrSession session in _sessions) {
      await session.close();
    }
  }
}
